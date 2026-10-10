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

enum Route: Equatable { case list, detail(UUID), settings, briefing, checkIn, activity, goals, goal(UUID), review }

/// A request waiting for the user to approve or cancel, shown as a native alert.
struct PendingConfirmation: Identifiable {
    let request: ActionRequest
    let prompt: String
    var id: UUID { request.id }
}

/// UI state and wiring. All state changes go through the ActionBroker; scheduling
/// goes through WrenEngine. Neither depends on Ollama.
@MainActor
@Observable
final class AppModel {
    @ObservationIgnored let settings = WrenSettings()
    @ObservationIgnored let notifications = NotificationService()
    @ObservationIgnored let clock: WrenClock = SystemClock()
    @ObservationIgnored private let log = Logger(subsystem: "com.shibadityadeb.wren", category: "app")
    @ObservationIgnored private var schedulerTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored let loginItems: LoginItemController

    let store: WrenStore?
    let storeError: String?
    @ObservationIgnored let broker: ActionBroker?
    @ObservationIgnored let policyStore: SwiftDataPolicyStore?
    @ObservationIgnored let engine: WrenEngine?

    var pending: [Commitment] = []
    var closed: [Commitment] = []
    var route: Route = .list {
        didSet { if case let .detail(id) = route { noteRecent(id) } }
    }
    var goals: [Goal] = []
    var insights: [Insight] = []
    var insightSettings: InsightSettings
    /// Recently touched items, most recent first (for "that", "it").
    @ObservationIgnored var recentIDs: [UUID] = []
    var modelStatus: ModelStatus = .checking
    var selectedModel: String?
    var notificationStatus: UNAuthorizationStatus = .notDetermined
    var hotKeyError: String?
    var hotKeyDisplay: String
    var hotKeyEnabled: Bool
    var banner: String?
    var processing: Set<UUID> = []
    var confirmation: PendingConfirmation?
    var policy: PolicySnapshot = .default
    var loginStatus: LoginItemStatus = .disabled
    var daily: DailySettings
    var todayRun: (briefing: DailyEventState, checkIn: DailyEventState) = (.pending, .pending)

    @ObservationIgnored var openCapturePanel: () -> Void = {}
    @ObservationIgnored var showPopover: () -> Void = {}
    @ObservationIgnored var applyHotKey: () -> Void = {}

    init(store injected: WrenStore? = nil, loginService: LoginItemService? = nil) {
        loginItems = LoginItemController(service: loginService ?? SystemLoginItemService())
        let s: WrenStore?
        var err: String?
        if let injected { s = injected } else {
            do { s = try WrenStore.openDefault() } catch {
                s = nil
                err = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
        store = s
        if let s, let ps = try? SwiftDataPolicyStore(context: s.context, clock: clock, defaults: .standard) {
            policyStore = ps
            let b = ActionBroker(context: s.context, policyStore: ps, clock: clock)
            BuiltInAction.registerLocal(on: b, store: s, notifier: notifications, clock: clock)
            broker = b
            let settingsRef = settings
            engine = WrenEngine(store: s, broker: b, clock: clock, notifier: notifications, settings: { settingsRef.daily },
                                insightSettings: { settingsRef.insights })
        } else {
            policyStore = nil; broker = nil; engine = nil
            if s != nil { err = "Couldn't load permissions." }
        }
        storeError = err
        hotKeyDisplay = settings.hotKey.display
        hotKeyEnabled = settings.hotKeyEnabled
        selectedModel = settings.modelName
        daily = settings.daily
        insightSettings = settings.insights
        reload()
        notifications.onResponse = { [weak self] r in self?.handle(r) }
    }

    var reminderHour: Int { settings.dateOnlyReminderHour }

    // MARK: Lifecycle

    func start() {
        notifications.activate()
        loginStatus = loginItems.reconcileOnLaunch(userWantsEnabled: settings.launchAtLogin)
        Task {
            notificationStatus = await notifications.refreshStatus()
            await refreshModels()
            processAwaiting()
            await tick()
        }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleTick() }
        })
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleTick() }
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
        if let p = try? policyStore?.load() { policy = p }
        goals = (try? store.goals()) ?? []
        insights = engine?.openInsights() ?? []
        if let run = engine?.todayRun() { todayRun = (run.briefing, run.checkIn) }
    }

    func item(_ id: UUID) -> Commitment? { try? store?.item(id: id) }

    // MARK: Scheduler

    func scheduleTick() { Task { await tick() } }

    func tick() async {
        schedulerTimer?.invalidate()
        guard let engine else { return }
        let report = await engine.tick()
        notificationStatus = notifications.status
        if report.remindersDelivered > 0 || report.briefing != nil { reload() }
        let wake = engine.nextWake()
        schedulerTimer = Timer.scheduledTimer(withTimeInterval: max(1, wake.timeIntervalSinceNow + 0.5), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleTick() }
        }
        schedulerTimer?.tolerance = 1
    }

    var dueUndelivered: [Commitment] { pending.filter { ReminderPolicy.isDue($0, now: clock.now) } }

    /// On-demand views show every open observation (the notification only raised new ones).
    var briefing: Briefing { Briefing.build(from: pending + closed, now: clock.now, calendar: clock.calendar, insights: insights) }
    var checkIn: CheckIn { CheckIn.build(from: pending + closed, now: clock.now, calendar: clock.calendar, insights: insights) }

    // MARK: Actions (all through the broker)

    /// Submits a request; shows a confirmation if the policy asks for one.
    @discardableResult
    func run(_ r: ActionRequest, confirmation c: Confirmation? = nil) async -> ActionResult? {
        guard let broker else { banner = storeError ?? "Wren's database isn't available."; return nil }
        let result = await broker.submit(r, confirmation: c)
        switch result.status {
        case .succeeded, .unverified, .dryRun: banner = nil
        case .awaitingConfirmation: confirmation = PendingConfirmation(request: r, prompt: result.message ?? "Confirm?")
        case .denied, .failed: banner = result.message
        case .proposed, .executing: break
        }
        reload()
        await tick()
        return result
    }

    func approvePendingConfirmation() {
        guard let p = confirmation, let broker else { return }
        confirmation = nil
        let token = broker.confirm(p.request)
        Task {
            let r = await run(p.request, confirmation: token)
            if r?.status == .succeeded, p.request.action == BuiltInAction.delete { route = .list }
        }
    }

    func cancelPendingConfirmation() {
        guard let p = confirmation else { return }
        confirmation = nil
        broker?.decline(p.request, reason: "Cancelled")
        reload()
    }

    func request(_ a: ActionID, _ c: Commitment, _ channel: UserChannel, _ params: [String: JSONValue] = [:]) -> ActionRequest {
        ActionRequest(action: a, target: c.targetRef, parameters: params, origin: .user(channel), createdAt: clock.now)
    }
    func time(_ d: Date) -> JSONValue { .number(d.timeIntervalSince1970) }

    func complete(_ c: Commitment, via ch: UserChannel = .popover) { Task { await run(request(BuiltInAction.complete, c, ch)) } }
    func drop(_ c: Commitment, via ch: UserChannel = .popover) { Task { await run(request(BuiltInAction.drop, c, ch)) } }
    func reopen(_ c: Commitment) { Task { await run(request(BuiltInAction.reopen, c, .popover)) } }
    func delete(_ c: Commitment) { Task { await run(request(BuiltInAction.delete, c, .popover)) } }
    func snooze(_ c: Commitment, until: Date, via ch: UserChannel = .popover) {
        ensureNotificationPermission()
        Task { await run(request(BuiltInAction.snooze, c, ch, ["until": time(until)])) }
    }
    func remind(_ c: Commitment, at date: Date) {
        ensureNotificationPermission()
        Task { await run(request(BuiltInAction.scheduleReminder, c, .popover, ["at": time(date)])) }
    }
    func save(_ c: Commitment, _ edit: WrenStore.Edit) {
        if edit.nextReminderAt != nil { ensureNotificationPermission() }
        Task {
            let r = await run(request(BuiltInAction.edit, c, .popover, edit.parameters))
            if r?.status == .succeeded { route = .list }
        }
    }
    /// "Leave for tomorrow": a reminder at tomorrow's briefing time. Doesn't touch the deadline.
    func leaveForTomorrow(_ c: Commitment, via ch: UserChannel = .checkIn) {
        snooze(c, until: tomorrowAtBriefing, via: ch)
    }
    var tomorrowAtBriefing: Date {
        let cal = clock.calendar
        let tomorrow = cal.date(byAdding: .day, value: 1, to: clock.now)!
        return cal.time(minutesAfterMidnight: daily.briefingEnabled ? daily.briefingMinutes : 9 * 60, on: tomorrow)
    }

    // MARK: Capture and interpretation

    /// Saves first, interprets second. A failure in interpretation can't lose the text.
    @discardableResult
    func capture(_ text: String, source: CaptureSource) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let store else {
            let ok = Self.emergencySave(trimmed)
            if ok { banner = "Database unavailable. Saved to emergency-captures.txt." }
            return ok
        }
        do {
            let c = try store.capture(trimmed, source: source, now: clock.now)
            noteRecent(c.id)
            reload()
            interpret(c)
            return true
        } catch {
            banner = "Couldn't save: \(error.localizedDescription)"
            return Self.emergencySave(trimmed)
        }
    }

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

    /// Rules first (no model), then the model if available. Both are applied through the
    /// broker under the "apply interpretations" standing rule; revoking it stops both.
    func interpret(_ c: Commitment) {
        guard c.processing != .manual, c.status == .pending, let broker else { return }
        let id = c.id, text = c.originalText, created = c.createdAt, target = c.targetRef
        let model = settings.useModel ? selectedModel : nil
        let processor = IntentProcessor(client: try? OllamaClient(), model: model, calendar: clock.calendar)
        let autoRemind = policy.rules.contains(.autoRemindDeadlines)
        let hour = reminderHour
        processing.insert(id)

        Task {
            let rules = processor.rulesOnly(text, now: created)
            let first = await broker.submit(ActionRequest(
                action: BuiltInAction.applyInterpretation, target: target,
                parameters: rules.parameters(model: nil, state: .awaiting, dateOnlyReminderHour: hour, scheduleReminders: autoRemind),
                origin: .system("date rules"), createdAt: clock.now))
            if first.status != .succeeded { log.notice("rules interpretation: \(first.status.rawValue, privacy: .public)") }
            if item(id)?.nextReminderAt != nil { ensureNotificationPermission() }
            reload()

            if model != nil, modelStatus.isReady {
                switch await processor.interpret(text, now: created) {
                case let .interpreted(i, name):
                    _ = await broker.submit(ActionRequest(
                        action: BuiltInAction.applyInterpretation, target: target,
                        parameters: i.parameters(model: name, state: .processed, dateOnlyReminderHour: hour, scheduleReminders: autoRemind),
                        origin: .model(name ?? "local model"), createdAt: clock.now))
                    if item(id)?.nextReminderAt != nil { ensureNotificationPermission() }
                case let .unavailable(reason):
                    if let c = item(id) { c.processingNote = "Read with simple rules. \(reason)"; try? store?.context.save() }
                case let .invalid(reason):
                    if let c = item(id) { try? store?.markInterpretationFailed(c, reason: reason, now: clock.now) }
                }
            }
            processing.remove(id)
            reload()
            await tick()
        }
    }

    func processAwaiting() {
        for c in pending where c.processing == .awaiting && c.modelName == nil && modelStatus.isReady && settings.useModel {
            interpret(c)
        }
    }

    func retryInterpretation(_ c: Commitment) {
        guard c.processing != .manual else { return }
        Task { await refreshModels(); interpret(c) }
    }

    // MARK: Check-in

    func finishCheckIn() { engine?.closeCheckIn(.completed); reload(); route = .list }
    func dismissCheckIn() { engine?.closeCheckIn(.dismissed); reload() }

    // MARK: Notifications

    func ensureNotificationPermission() {
        guard notificationStatus == .notDetermined else { return }
        Task { _ = await notifications.requestPermission(); notificationStatus = notifications.status; await tick() }
    }

    func requestNotificationPermission() {
        Task { _ = await notifications.requestPermission(); notificationStatus = notifications.status; await tick() }
    }

    private func handle(_ r: NotificationService.Response) {
        reload()
        func pendingItem(_ id: UUID) -> Commitment? { item(id).flatMap { $0.status == .pending ? $0 : nil } }
        switch r {
        case let .done(id): noteRecent(id); if let c = pendingItem(id) { complete(c, via: .notificationAction) }
        case let .snoozeHour(id): if let c = pendingItem(id) { snooze(c, until: clock.now.addingTimeInterval(3600), via: .notificationAction) }
        case let .tomorrow(id): if let c = pendingItem(id) { leaveForTomorrow(c, via: .notificationAction) }
        case let .later(id, text):
            guard let c = pendingItem(id) else { return }
            if let p = DateParser(calendar: clock.calendar).parse(text, now: clock.now) {
                let when = p.hasTime ? p.date : clock.calendar.time(minutesAfterMidnight: reminderHour * 60, on: p.date)
                if when > clock.now { snooze(c, until: when, via: .notificationAction); return }
            }
            snooze(c, until: clock.now.addingTimeInterval(3600), via: .notificationAction)
            Task { await notifications.deliverInfo("Snoozed for 1 hour", "Wren couldn't read “\(text)” as a time. You can change it from the menu bar.") }
        case let .open(id): route = .detail(id); showPopover()
        case .openBriefing: route = .briefing; showPopover()
        case .reviewCheckIn: route = .checkIn; showPopover()
        case .dismissCheckIn: dismissCheckIn()
        }
    }

    // MARK: Settings: daily, login, permissions

    func updateDaily(_ f: (inout DailySettings) -> Void) {
        var d = daily; f(&d)
        daily = d.normalized()
        settings.daily = daily
        scheduleTick()
    }

    func setLaunchAtLogin(_ on: Bool) {
        settings.launchAtLogin = on
        loginStatus = loginItems.set(enabled: on)
        if case .unavailable = loginStatus { settings.launchAtLogin = false }
        log.notice("login item set \(on, privacy: .public): \(self.loginStatus.label, privacy: .public)")
    }

    func refreshLoginStatus() { loginStatus = loginItems.service.status }

    func setRule(_ k: StandingRuleKind, _ on: Bool) {
        do { try policyStore?.setRule(k, enabled: on) } catch { banner = error.localizedDescription }
        reload()
    }

    func setGrant(_ p: Permission, _ on: Bool) {
        do { try policyStore?.setGrant(p, granted: on) } catch { banner = error.localizedDescription }
        reload()
    }

    func liftDenial(_ key: String) { try? policyStore?.liftDenial(key: key); reload() }
    var denials: [DenialRecord] { (try? policyStore?.denials()) ?? [] }
    var audit: [AuditRecord] { broker?.recentAudit(limit: 100) ?? [] }

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

    func selectModel(_ name: String) { selectedModel = name; settings.modelName = name; processAwaiting() }

    func setUseModel(_ on: Bool) {
        settings.useModel = on
        Task { await refreshModels(); processAwaiting() }
    }

    // MARK: Shortcut

    func setHotKeyEnabled(_ on: Bool) { settings.hotKeyEnabled = on; hotKeyEnabled = on; applyHotKey() }
    func setHotKey(_ spec: HotKeySpec) { settings.hotKey = spec; hotKeyDisplay = spec.display; applyHotKey() }
}
