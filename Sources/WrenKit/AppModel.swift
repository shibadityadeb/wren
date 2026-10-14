import AppKit
import Observation
import UserNotifications
import WrenCore
import os

/// A model download the user started from the Local AI pane.
enum ModelDownload: Equatable {
    case idle
    case running(model: String, update: PullUpdate?)
    case failed(model: String, reason: String)
    case cancelled(model: String)
    case finished(model: String)
}

enum Route: Equatable { case overview, list, detail(UUID), settings, briefing, checkIn, activity, goals, goal(UUID), review, aiSetup,
                         connectors, connector(ConnectorID), delegate, delegation(UUID), inbox, mailMessage(String) }

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
    @ObservationIgnored let log = Logger(subsystem: "com.shibadityadeb.wren", category: "app")
    @ObservationIgnored private var schedulerTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Keeps macOS's scheduled reminder notifications in line with the store.
    @ObservationIgnored var reminders: ReminderScheduler?
    /// "Ask ChatGPT" from the capture panel.
    @ObservationIgnored var asks: AskService?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    /// Result of the last reconcile, for Settings and confirmations.
    var reminderSync = ReconcileReport()
    /// After Wren asked "When should I remind you…?", the start of the request the answer completes.
    var reminderFollowUp: String?
    /// A ChatGPT website request's state changed (detected in the browser); the panel refreshes its card.
    @ObservationIgnored var webHandoffChanged: (UUID) -> Void = { _ in }
    /// A message about a ChatGPT website request for the panel (e.g. detection not allowed).
    @ObservationIgnored var webHandoffNote: (UUID, String) -> Void = { _, _ in }
    /// The pending question is "What should I remind you about?" (the time is already known).
    var reminderFollowUpNeedsSubject = false
    /// What the last command did (operation, success, entity, error). Never holds the user's words.
    var lastExecution: ExecutionResult?
    @ObservationIgnored var submissions = SubmissionGuard()
    @ObservationIgnored let loginItems: LoginItemController

    let store: WrenStore?
    let storeError: String?
    @ObservationIgnored let broker: ActionBroker?
    @ObservationIgnored let policyStore: SwiftDataPolicyStore?
    @ObservationIgnored let engine: WrenEngine?
    @ObservationIgnored let backups = BackupManager(dataDirectory: WrenStore.defaultDirectory)
    @ObservationIgnored var startupRestore: WrenStore.StartupRestore = .none
    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

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
    /// Truthful local-AI state. `.ready` only after a real request succeeded.
    var ai: AIReadiness = .checking
    var aiReport: DiagnosticReport?
    var aiTesting = false
    var download: ModelDownload = .idle
    @ObservationIgnored var downloadTask: Task<Void, Never>?
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
    var pause: NotificationPause?
    /// Shown after a pause ends: how many reminders were folded into one summary.
    var resumeNote: String?
    var backupList: [BackupEntry] = []
    var backupPreview: BackupPreview?

    @ObservationIgnored var openCapturePanel: () -> Void = {}
    @ObservationIgnored var showPopover: () -> Void = {}
    @ObservationIgnored var applyHotKey: () -> Void = {}
    @ObservationIgnored var openMainWindow: () -> Void = {}
    @ObservationIgnored var applyVoiceHotKey: () -> Void = {}
    /// Starts (or stops) one voice command, exactly like the voice shortcut (set by the app delegate).
    @ObservationIgnored var startVoice: () -> Void = {}
    /// The voice service's phase, for Settings and the menu.
    var voicePhase: VoiceSession.Phase = .idle
    var voiceHotKeyError: String?
    /// Why the last "Connect Google" didn't finish (cancelled, denied, timed out…).
    var googleError: String?
    /// Waiting for the user on Google's page.
    var googleConnecting = false
    /// Puts text in the capture panel for the user to review (never saves by itself).
    @ObservationIgnored var prefillCapture: ((String) -> Void)?
    @ObservationIgnored var hub: ConnectorHub!
    /// Bumped when connector state changes, so views re-read it.
    var connectorVersion = 0
    var delegationDraft: (task: String, depth: HandoffDepth)?
    // Gmail inbox intelligence (AppModel+Mail).
    var mailbox = MailboxState()
    var mailPrefs: MailPreferences
    var mailSyncing = false
    var mailStatus: String?
    var nextMailCheck: Date?
    var mailVersion = 0
    @ObservationIgnored var mailTimer: Timer?
    @ObservationIgnored var mailBackoff: Double = 1
    /// Design snapshots only (`wren-tools snapshot`): render the inbox as if Gmail were connected.
    @ObservationIgnored var previewGmail: Bool?
    /// Bumped when a delegation starts, finishes or is opened.
    var delegationVersion = 0
    /// True while the capture panel is showing this delegation's live result (set by the app delegate).
    @ObservationIgnored var isShowingDelegation: (UUID) -> Bool = { _ in false }

    init(store injected: WrenStore? = nil, loginService: LoginItemService? = nil) {
        loginItems = LoginItemController(service: loginService ?? SystemLoginItemService())
        let s: WrenStore?
        var err: String?
        var restoreOutcome = WrenStore.StartupRestore.none
        if let injected { s = injected } else {
            do { (s, restoreOutcome) = try WrenStore.openDefault(appVersion: Self.appVersion) } catch {
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
            BuiltInAction.registerData(on: b, store: s, backups: BackupManager(dataDirectory: WrenStore.defaultDirectory),
                                       appVersion: Self.appVersion, clock: clock)
            let e = WrenEngine(store: s, broker: b, clock: clock, notifier: notifications, settings: { settingsRef.daily },
                               insightSettings: { settingsRef.insights })
            e.pause = { settingsRef.pause }
            engine = e
            let scheduler = ReminderScheduler(store: s, center: notifications, clock: clock, pause: { settingsRef.pause })
            e.scheduledByMacOS = { scheduler.isScheduledByMacOS($0) }
            reminders = scheduler
            BuiltInAction.defaultReminderHour = { settingsRef.dateOnlyReminderHour }
        } else {
            policyStore = nil; broker = nil; engine = nil
            if s != nil { err = "Couldn't load permissions." }
        }
        storeError = err
        startupRestore = restoreOutcome
        hotKeyDisplay = settings.hotKey.display
        hotKeyEnabled = settings.hotKeyEnabled
        selectedModel = settings.modelName
        daily = settings.daily
        insightSettings = settings.insights
        pause = settings.pause
        mailPrefs = settings.mail
        hub = ConnectorHub(settings: settings, policy: policyStore)
        if let s, let b = broker { asks = AskService(store: s, broker: b, chatgpt: hub.chatgpt, clock: clock) }
        wireDelegations()
        engine?.externalBriefing = { [weak self] in await self?.externalBriefing() }
        reload()
        notifications.onResponse = { [weak self] r in self?.handle(r) }
        // Any change to stored items (from any path) re-syncs scheduled notifications shortly after.
        store?.onChange = { [weak self] in self?.scheduleReconcile() }
        engine?.clearPause = { [weak self] in self?.settings.pause = nil; self?.pause = nil }
        registerAppActions()
        switch restoreOutcome {
        case .restored:
            banner = "Backup restored. Your previous data was backed up first."
            broker?.recordEvent(action: BuiltInAction.restoreBackup, target: BuiltInAction.allDataTarget, origin: .system("startup"),
                                detail: "Backup restored at startup; the replaced data is in Restore/ and a pre-restore backup was made")
        case let .failedAndRolledBack(r): banner = "The backup couldn't be opened, so your previous data was kept. (\(r))"
        case .none: break
        }
    }

    var reminderHour: Int { settings.dateOnlyReminderHour }

    // MARK: Lifecycle

    func start() {
        settings.removeRetiredPreferences()
        notifications.soundsEnabled = { [weak self] in self?.settings.notificationSounds ?? true }
        notifications.activate()
        loginStatus = loginItems.reconcileOnLaunch(userWantsEnabled: settings.launchAtLogin)
        Task {
            notificationStatus = await notifications.refreshStatus()
            await hub.registry.refreshAll()
            connectorVersion += 1
            startMail()
            await refreshAI()
            processAwaiting()
            await tick()
        }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleTick()
                // After sleep: catch up on mail (and a digest that came due) shortly after the network is back.
                self?.scheduleMailCheck(after: 20)
            }
        })
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clockOrZoneChanged() }
            })
        }
        // Notification permission can change in System Settings while Wren runs.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReconcile() }
        })
    }

    /// Repeating reminders keep their wall-clock time in the new zone; then everything re-syncs.
    func clockOrZoneChanged() {
        var cal = Calendar.current; cal.timeZone = TimeZone.current
        _ = try? store?.refreshRecurrences(calendar: cal, now: clock.now)
        scheduleReconcile()
        scheduleTick()
    }

    func scheduleReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.reconcileReminders()
        }
    }

    @discardableResult
    func reconcileReminders() async -> ReconcileReport {
        guard let reminders else { return ReconcileReport() }
        let r = await reminders.reconcile()
        reminderSync = r
        notificationStatus = notifications.status
        if !r.failed.isEmpty { log.error("reminder scheduling failed for \(r.failed.count, privacy: .public) request(s)") }
        return r
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
        await reconcileReminders()
        let report = await engine.tick()
        notificationStatus = notifications.status
        if report.summarizedAfterPause > 0 { resumeNote = "\(report.summarizedAfterPause) reminder\(report.summarizedAfterPause == 1 ? "" : "s") came due while notifications were paused." }
        pause = settings.pause
        automaticBackupIfDue()
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
            guard r?.status == .succeeded else { return }
            switch p.request.action {
            case BuiltInAction.delete: route = .list
            case BuiltInAction.restoreBackup: relaunch()
            case BuiltInAction.eraseAllData:
                route = .overview; refreshBackups()
                await removeConnectorData()
                banner = "All Wren data was removed, including connector sign-ins and cached mail. Backups were kept."
            case BuiltInAction.resetPreferences: reloadPreferences(); banner = "Preferences were reset. Your items are unchanged."
            case BuiltInAction.deleteBackup: refreshBackups()
            default: break
            }
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
    /// `repeat`: nil leaves repeating as it is; `.some(nil)` stops it; `.some(rule)` sets it.
    func save(_ c: Commitment, _ edit: WrenStore.Edit, repeat newRule: RecurrenceRule?? = nil) {
        if edit.nextReminderAt != nil || newRule != nil { ensureNotificationPermission() }
        Task {
            let r = await run(request(BuiltInAction.edit, c, .popover, edit.parameters))
            guard r?.status == .succeeded else { return }
            if let newRule {
                let r2 = await run(request(BuiltInAction.setRepeat, c, .popover, BuiltInAction.setRepeatParameters(newRule)))
                guard r2?.status == .succeeded else { return }
            }
            route = .list
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
        let model = settings.useModel ? ai.usableModel : nil
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

            if model != nil {
                let started = Date()
                switch await processor.interpret(text, now: created) {
                case let .interpreted(i, name):
                    noteModelSuccess(since: started)
                    _ = await broker.submit(ActionRequest(
                        action: BuiltInAction.applyInterpretation, target: target,
                        parameters: i.parameters(model: name, state: .processed, dateOnlyReminderHour: hour, scheduleReminders: autoRemind),
                        origin: .model(name ?? "local model"), createdAt: clock.now))
                    if item(id)?.nextReminderAt != nil { ensureNotificationPermission() }
                case let .unavailable(reason):
                    noteModelFailure(reason)
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
        for c in pending where c.processing == .awaiting && c.modelName == nil && ai.usableModel != nil && settings.useModel {
            interpret(c)
        }
    }

    func retryInterpretation(_ c: Commitment) {
        guard c.processing != .manual else { return }
        Task { await refreshAI(); interpret(c) }
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
        // A notification action delivered twice (a repeated click, or the same reminder shown twice)
        // changes the item once.
        let actionKey: String? = switch r {
        case let .done(id): "done|\(id)"
        case let .snoozeHour(id): "snooze|\(id)"
        case let .tomorrow(id): "tomorrow|\(id)"
        case let .later(id, t): "later|\(id)|\(t)"
        case let .mail(.markRead(id)): "markRead|\(id)"
        case let .mail(.snooze(id)): "mailSnooze|\(id)"
        default: nil
        }
        if let actionKey {
            guard submissions.begin(actionKey, now: clock.now) else { log.notice("duplicate notification action ignored"); return }
            submissions.end(actionKey, now: clock.now)
        }
        func pendingItem(_ id: UUID) -> Commitment? { item(id).flatMap { $0.status == .pending ? $0 : nil } }
        switch r {
        case let .done(id):
            noteRecent(id)
            guard let c = pendingItem(id) else { return }
            // "Done" on a repeating reminder finishes this time; the series continues.
            if c.recurrence != nil { Task { await run(request(BuiltInAction.completeOccurrence, c, .notificationAction)) } }
            else { complete(c, via: .notificationAction) }
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
        case let .openDelegation(id): openDelegation(id)
        case let .mail(r): handleMail(r)
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

    // MARK: Local AI

    var aiDiagnostics: AIDiagnostics? { (try? OllamaClient()).map { AIDiagnostics(client: $0) } }

    /// Cheap status check (no model loaded). Keeps a verified "ready" for the same model.
    func refreshAI() async {
        guard let d = aiDiagnostics else { ai = .notRunning; return }
        let previous = ai
        let next = await d.readiness(enabled: settings.useModel, selected: selectedModel)
        if case let .ready(m, _, at, ms) = previous, case let .configured(m2, models) = next, m == m2 {
            ai = .ready(model: m, models: models, verifiedAt: at, latencyMs: ms)
        } else {
            ai = next
        }
        // Select the only model automatically; with several, the user chooses.
        if case let .selectModel(models) = ai, models.count == 1, selectedModel == nil {
            selectedModel = models[0]; settings.modelName = models[0]
            ai = await d.readiness(enabled: settings.useModel, selected: selectedModel)
        }
    }

    /// The "Test local AI" button: real request, real parse, result shown step by step.
    func testAI() async {
        guard let d = aiDiagnostics else { return }
        aiTesting = true
        let report = await d.fullTest(enabled: settings.useModel, selected: selectedModel)
        aiReport = report
        ai = report.readiness
        aiTesting = false
        if ai.isReady { processAwaiting() }
        log.notice("AI test: \(self.ai.title, privacy: .public)")
    }

    func noteModelSuccess(since: Date) {
        if case let .configured(m, models) = ai {
            ai = .ready(model: m, models: models, verifiedAt: Date(), latencyMs: Int(Date().timeIntervalSince(since) * 1000))
        }
    }

    func noteModelFailure(_ reason: String) {
        if let m = ai.usableModel { ai = .unavailable(model: m, models: ai.installedModels, reason: reason) }
    }

    func selectModel(_ name: String) {
        selectedModel = name; settings.modelName = name
        Task { await refreshAI(); await testAI() }
    }

    func setUseModel(_ on: Bool) {
        settings.useModel = on
        Task { await refreshAI(); processAwaiting() }
    }

    /// Asks macOS to open the Ollama app the user installed. Nothing is executed by Wren itself.
    func startOllama() {
        guard let url = FileSystemOllamaProbe().appURL() else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            Task { @MainActor in
                for _ in 0..<15 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await self.refreshAI()
                    if self.ai != .notRunning { break }
                }
            }
        }
    }

    /// Only ever started by the user pressing Download, for the exact model shown.
    func startDownload(_ name: String) {
        guard OllamaClient.isValidModelName(name), let client = try? OllamaClient() else {
            download = .failed(model: name, reason: "“\(name)” isn't a valid model name."); return
        }
        if case .running = download { return }
        download = .running(model: name, update: nil)
        log.notice("model download started: \(name, privacy: .public)")
        downloadTask = Task {
            do {
                _ = try await client.pullToCompletion(model: name) { u in
                    await MainActor.run { self.download = .running(model: name, update: u) }
                }
                download = .finished(model: name)
                selectedModel = name; settings.modelName = name
                await refreshAI()
                await testAI()  // verify it actually answers
            } catch is CancellationError {
                download = .cancelled(model: name)
            } catch {
                download = .failed(model: name, reason: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
            log.notice("model download ended: \(String(describing: self.download), privacy: .public)")
        }
    }

    func cancelDownload() { downloadTask?.cancel() }

    // MARK: Shortcut

    func setHotKeyEnabled(_ on: Bool) { settings.hotKeyEnabled = on; hotKeyEnabled = on; applyHotKey() }
    func setHotKey(_ spec: HotKeySpec) {
        if settings.voiceEnabled, spec == settings.voiceHotKey { hotKeyError = "\(spec.display) is already Wren's voice shortcut. Choose another."; return }
        settings.hotKey = spec; hotKeyDisplay = spec.display; applyHotKey()
    }
    func setVoiceHotKey(_ spec: HotKeySpec) {
        if hotKeyEnabled, spec == settings.hotKey { voiceHotKeyError = "\(spec.display) is already Wren's capture shortcut. Choose another."; return }
        settings.voiceHotKey = spec; voiceHotKeyError = nil; applyVoiceHotKey(); connectorsChanged()
    }

}
