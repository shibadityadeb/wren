import AppKit
import Observation
import UserNotifications
import WrenCore
import os

enum ModelStatus: Equatable {
    case checking
    case off
    case unreachable(String)
    case noChatModel
    case ready([String])

    var summary: String {
        switch self {
        case .checking: "Checking local model…"
        case .off: "Language model off"
        case .unreachable: "Ollama not running"
        case .noChatModel: "No chat model installed"
        case .ready: "Local model ready"
        }
    }
    var isReady: Bool { if case .ready = self { true } else { false } }
}

enum Route: Equatable { case list, detail(UUID), settings }

/// App state and the only place UI actions reach the store. Every state change
/// goes through WrenStore, which is the source of truth.
@MainActor
@Observable
final class AppModel {
    @ObservationIgnored let settings = WrenSettings()
    @ObservationIgnored let notifications = NotificationService()
    @ObservationIgnored private let log = Logger(subsystem: "com.shibadityadeb.wren", category: "app")
    @ObservationIgnored private var schedulerTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Items currently being handed to macOS, so overlapping ticks can't double-send.
    @ObservationIgnored private var delivering: Set<UUID> = []

    let store: WrenStore?
    let storeError: String?

    var pending: [Commitment] = []
    var closed: [Commitment] = []
    var route: Route = .list
    var modelStatus: ModelStatus = .checking
    var selectedModel: String?
    var notificationStatus: UNAuthorizationStatus = .notDetermined
    var hotKeyError: String?
    var hotKeyDisplay: String
    var hotKeyEnabled: Bool
    var banner: String?
    var processing: Set<UUID> = []

    /// Hooks set by the AppDelegate.
    @ObservationIgnored var openCapturePanel: () -> Void = {}
    @ObservationIgnored var showPopover: () -> Void = {}
    @ObservationIgnored var applyHotKey: () -> Void = {}

    init(store: WrenStore? = nil) {
        if let store {
            self.store = store; storeError = nil
        } else {
            do { self.store = try WrenStore.openDefault(); storeError = nil } catch {
                self.store = nil
                storeError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
        hotKeyDisplay = settings.hotKey.display
        hotKeyEnabled = settings.hotKeyEnabled
        selectedModel = settings.modelName
        reload()
        notifications.onResponse = { [weak self] r in self?.handle(r) }
    }

    var policy: ReminderPolicy { ReminderPolicy(dateOnlyReminderHour: settings.dateOnlyReminderHour) }

    // MARK: Lifecycle

    func start() {
        notifications.activate()
        Task {
            notificationStatus = await notifications.refreshStatus()
            await refreshModels()
            processAwaiting()
            tick()
        }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        })
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            })
        }
    }

    func reload() {
        guard let store else { return }
        do {
            pending = try store.pending()
            closed = try store.closed(limit: 20)
        } catch {
            banner = "Couldn't read your items: \(error.localizedDescription)"
        }
    }

    func item(_ id: UUID) -> Commitment? { try? store?.item(id: id) }

    // MARK: Capture

    /// Saves first, interprets second. A failure in interpretation can't lose the text.
    @discardableResult
    func capture(_ text: String, source: CaptureSource) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let store else {
            return Self.emergencySave(trimmed) ? { banner = "Database unavailable. Saved to emergency-captures.txt."; return true }() : false
        }
        do {
            let c = try store.capture(trimmed, source: source)
            reload()
            interpret(c)
            return true
        } catch {
            banner = "Couldn't save: \(error.localizedDescription)"
            return Self.emergencySave(trimmed)
        }
    }

    /// Last-resort append-only file so a capture is never lost when the database can't open.
    static func emergencySave(_ text: String) -> Bool {
        let url = WrenStore.defaultDirectory.appendingPathComponent("emergency-captures.txt")
        let line = "\(ISO8601DateFormatter().string(from: .now))\t\(text.replacingOccurrences(of: "\n", with: " "))\n"
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                try h.seekToEnd(); try h.write(contentsOf: Data(line.utf8))
            } else {
                try Data(line.utf8).write(to: url)
            }
            return true
        } catch { return false }
    }

    func interpret(_ c: Commitment) {
        guard let store, c.processing != .manual, c.status == .pending else { return }
        let id = c.id, text = c.originalText, created = c.createdAt
        let model = settings.useModel ? selectedModel : nil
        let client = try? OllamaClient()
        let processor = IntentProcessor(client: client, model: model)
        processing.insert(id)

        // Rules first, so a literal date like "at 9pm" works even with no model.
        let rules = processor.rulesOnly(text, now: created)
        do { try store.applyInterpretation(rules, to: c, model: nil, reminderPolicy: policy, state: .awaiting) } catch {
            log.error("rules apply failed")
        }
        // First time a capture produces a reminder is the natural moment to ask.
        if c.nextReminderAt != nil { ensureNotificationPermission() }
        reload()
        guard model != nil, modelStatus.isReady else {
            processing.remove(id); tick(); return
        }
        Task {
            let outcome = await processor.interpret(text, now: created)
            defer { processing.remove(id); reload(); tick() }
            guard let c = item(id) else { return }
            switch outcome {
            case let .interpreted(i, model):
                try? store.applyInterpretation(i, to: c, model: model, reminderPolicy: policy, now: .now)
                if c.nextReminderAt != nil { ensureNotificationPermission() }
            case let .unavailable(reason):
                c.processingNote = "Read with simple rules. \(reason)"
                try? store.context.save()
            case let .invalid(reason):
                try? store.markInterpretationFailed(c, reason: reason)
            }
        }
    }

    func processAwaiting() {
        for c in pending where c.processing == .awaiting && c.modelName == nil && modelStatus.isReady && settings.useModel {
            interpret(c)
        }
    }

    // MARK: Item actions

    private func perform(_ c: Commitment, _ body: (WrenStore) throws -> Void) {
        guard let store else { return }
        do { try body(store); banner = nil } catch {
            banner = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        reload()
        tick()
    }

    func complete(_ c: Commitment) { perform(c) { try $0.complete(c) }; notifications.withdraw(id: c.id) }
    func drop(_ c: Commitment) { perform(c) { try $0.drop(c) }; notifications.withdraw(id: c.id) }
    func reopen(_ c: Commitment) { perform(c) { try $0.reopen(c) } }
    func delete(_ c: Commitment) {
        notifications.withdraw(id: c.id)
        perform(c) { try $0.delete(c) }
        route = .list
    }
    func snooze(_ c: Commitment, until: Date) {
        ensureNotificationPermission()
        perform(c) { try $0.snooze(c, until: until) }
        notifications.withdraw(id: c.id)
    }
    func remind(_ c: Commitment, at date: Date) {
        ensureNotificationPermission()
        perform(c) { try $0.scheduleReminder(c, at: date) }
    }
    func save(_ c: Commitment, _ edit: WrenStore.Edit) {
        if edit.nextReminderAt != nil { ensureNotificationPermission() }
        perform(c) { try $0.edit(c, edit) }
    }
    func retryInterpretation(_ c: Commitment) {
        guard c.processing != .manual else { return }
        Task { await refreshModels(); interpret(c) }
    }

    // MARK: Scheduler

    /// Delivers due reminders, then sleeps until the next one (at most 60 s).
    /// Reminders that couldn't be delivered stay due and show in the popover.
    func tick() {
        schedulerTimer?.invalidate()
        guard let store else { return }
        let now = Date()
        let due = ReminderPolicy.due(pending, now: now)
        if !due.isEmpty {
            Task {
                notificationStatus = await notifications.refreshStatus()
                guard notifications.canDeliver else { return }
                for c in due where ReminderPolicy.isDue(c, now: .now) && !delivering.contains(c.id) {
                    delivering.insert(c.id)
                    defer { delivering.remove(c.id) }
                    let late = (c.nextReminderAt.map { Date().timeIntervalSince($0) } ?? 0) > 5 * 60
                    let ok = await notifications.deliverReminder(id: c.id, title: c.title, body: Self.reminderBody(c), late: late)
                    if ok { try? store.markReminderSent(c) }
                }
                reload()
            }
        }
        let wake = ReminderPolicy.nextWake(pending, now: now)
        schedulerTimer = Timer.scheduledTimer(withTimeInterval: max(1, wake.timeIntervalSinceNow + 0.5), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        schedulerTimer?.tolerance = 1
    }

    var dueUndelivered: [Commitment] { pending.filter { ReminderPolicy.isDue($0, now: .now) } }

    static func reminderBody(_ c: Commitment) -> String {
        if let d = c.deadline {
            return "Due \(DueText.describe(d, hasTime: c.deadlineHasTime))."
        }
        return "You asked Wren to remind you."
    }

    // MARK: Notifications

    func ensureNotificationPermission() {
        guard notificationStatus == .notDetermined else { return }
        Task { _ = await notifications.requestPermission(); notificationStatus = notifications.status; tick() }
    }

    func requestNotificationPermission() {
        Task {
            _ = await notifications.requestPermission()
            notificationStatus = notifications.status
            tick()
        }
    }

    private func handle(_ r: NotificationService.Response) {
        reload()
        switch r {
        case let .done(id):
            guard let c = item(id), c.status == .pending else { return }
            complete(c)
        case let .snoozeHour(id):
            guard let c = item(id), c.status == .pending else { return }
            snooze(c, until: .now.addingTimeInterval(3600))
        case let .later(id, text):
            guard let c = item(id), c.status == .pending else { return }
            if let p = DateParser().parse(text, now: .now), p.date > .now {
                let when = p.hasTime ? p.date : Calendar.current.date(bySettingHour: settings.dateOnlyReminderHour, minute: 0, second: 0, of: p.date) ?? p.date
                if when > .now { snooze(c, until: when); return }
            }
            snooze(c, until: .now.addingTimeInterval(3600))
            Task { await notifications.deliverInfo("Snoozed for 1 hour", "Wren couldn't read “\(text)” as a time. You can change it from the menu bar.") }
        case let .open(id):
            route = .detail(id)
            showPopover()
        }
    }

    // MARK: Local model

    func refreshModels() async {
        guard settings.useModel else { modelStatus = .off; return }
        modelStatus = .checking
        do {
            let client = try OllamaClient()
            let chat = try await client.models().filter(\.canChat).map(\.name)
            if chat.isEmpty { modelStatus = .noChatModel; return }
            modelStatus = .ready(chat)
            if selectedModel == nil || !chat.contains(selectedModel!) {
                selectedModel = chat.first
                settings.modelName = selectedModel
            }
        } catch {
            modelStatus = .unreachable((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    func selectModel(_ name: String) {
        selectedModel = name
        settings.modelName = name
        processAwaiting()
    }

    func setUseModel(_ on: Bool) {
        settings.useModel = on
        Task { await refreshModels(); processAwaiting() }
    }

    // MARK: Shortcut

    func setHotKeyEnabled(_ on: Bool) {
        settings.hotKeyEnabled = on
        hotKeyEnabled = on
        applyHotKey()
    }

    func setHotKey(_ spec: HotKeySpec) {
        settings.hotKey = spec
        hotKeyDisplay = spec.display
        applyHotKey()
    }
}

enum DueText {
    static func describe(_ d: Date, hasTime: Bool, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = d.formatted(date: .omitted, time: .shortened)
        let day: String
        if calendar.isDateInToday(d) { day = "today" }
        else if calendar.isDateInTomorrow(d) { day = "tomorrow" }
        else if calendar.isDateInYesterday(d) { day = "yesterday" }
        else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: d)).day, (2...6).contains(days) {
            day = d.formatted(.dateTime.weekday(.wide))
        } else {
            day = d.formatted(.dateTime.day().month(.abbreviated))
        }
        return hasTime ? "\(day) at \(time)" : day
    }
}
