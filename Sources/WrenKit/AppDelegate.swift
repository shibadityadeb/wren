import AppKit
import SwiftUI
import WrenCore
import os
import UserNotifications

private let appLog = Logger(subsystem: "com.shibadityadeb.wren", category: "app")

/// Menu-bar agent: a status item with a popover, a global shortcut, and the capture panel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var panel: CapturePanel!
    private let captureState = CaptureState()
    private var hotKeys: HotKeyService!
    private var voiceKeys: HotKeyService!
    private var voice: VoiceCapture!
    private var voiceTimer: Timer?
    #if DEBUG
    private var debugProposal: ContextProposal?
    #endif

    private var mainWindow: MainWindowController!

    /// Launched by macOS as a login item (then Wren starts quietly in the menu bar).
    private var launchedAsLoginItem: Bool {
        guard let ev = NSAppleEventManager.shared().currentAppleEvent, ev.eventID == AEEventID(kAEOpenApplication) else { return false }
        return ev.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // One Wren at a time: a login launch plus a manual open must not run two schedulers.
        // A relaunch (to finish a restore) waits for the previous copy to quit first.
        let isRelaunch = CommandLine.arguments.contains("--relaunch")
        if let id = Bundle.main.bundleIdentifier {
            var waited: TimeInterval = 0
            while true {
                let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.processIdentifier != getpid() }
                switch InstanceGuard.decide(othersRunning: others, isRelaunch: isRelaunch, waited: waited) {
                case .proceed: break
                case .waitForPrevious:
                    Thread.sleep(forTimeInterval: 0.25); waited += 0.25; continue
                case .exit:
                    appLog.notice("another Wren instance is running; exiting")
                    // Bring the running copy's window forward instead of doing nothing.
                    NSRunningApplication.runningApplications(withBundleIdentifier: id).first { $0.processIdentifier != getpid() }?.activate()
                    NSApp.terminate(nil)
                    return
                }
                break
            }
        }
        model = AppModel()
        mainWindow = MainWindowController(model: model)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = WrenMark.menuBarImage()
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        statusItem.button?.setAccessibilityLabel("Wren")

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))

        panel = CapturePanel {
            CaptureView(state: captureState, submit: { [weak self] in self?.submitCapture($0) },
                        cancel: { [weak self] in self?.cancelCapture() },
                        confirm: { [weak self] in self?.confirmProposal($0) },
                        choose: { [weak self] c, p in self?.chooseCandidate(c, p) },
                        saveAsNew: { [weak self] in self?.saveAsNew($0) },
                        openAISetup: { [weak self] in self?.openAISetup() },
                        toggleVoice: { [weak self] in self?.toggleVoice() })
        }
        panel.onCancel = { [weak self] in self?.cancelCapture() }
        panel.onResign = { [weak self] in
            guard let self else { return }
            self.model.settings.captureDraft = self.captureState.text
        }

        hotKeys = HotKeyService { [weak self] in self?.showCapture() }
        model.openCapturePanel = { [weak self] in self?.popover.performClose(nil); self?.showCapture() }
        model.showPopover = { [weak self] in self?.openPopover() }
        model.applyHotKey = { [weak self] in self?.applyHotKey() }
        model.openMainWindow = { [weak self] in self?.popover.performClose(nil); self?.mainWindow.show() }
        voice = VoiceCapture(permissions: model.hub.voicePermissions, recorder: SystemRecorder(), transcriber: OnDeviceTranscriber())
        voice.onChange = { [weak self] st in self?.voiceChanged(st) }
        voiceKeys = HotKeyService(id: 2, onPress: { [weak self] in self?.voiceDown() }, onRelease: { [weak self] in self?.voiceUp() })
        model.applyVoiceHotKey = { [weak self] in self?.applyVoiceHotKey() }
        model.prefillCapture = { [weak self] t in self?.captureState.text = t }
        applyVoiceHotKey()
        applyHotKey()
        model.start()
        if !launchedAsLoginItem {
            mainWindow.show()
            appLog.notice("main window shown at launch")
        } else {
            appLog.notice("launched as login item; staying in the menu bar")
        }
    }

    // MARK: Hotkey

    private func applyHotKey() {
        guard model.settings.hotKeyEnabled else { hotKeys.unregister(); model.hotKeyError = nil; return }
        model.hotKeyError = hotKeys.register(model.settings.hotKey)
        if let e = model.hotKeyError {
            appLog.error("hotkey \(self.model.settings.hotKey.display, privacy: .public) not registered: \(e, privacy: .public)")
        } else {
            appLog.notice("hotkey \(self.model.settings.hotKey.display, privacy: .public) registered")
        }
    }

    // MARK: Push-to-talk

    private func applyVoiceHotKey() {
        captureState.voiceEnabled = model.settings.voiceEnabled
        guard model.settings.voiceEnabled else { voiceKeys.unregister(); return }
        if let e = voiceKeys.register(model.settings.voiceHotKey) { model.banner = "Push-to-talk: " + e }
    }

    private func voiceDown() {
        guard model.settings.voiceEnabled else { return }
        showCapture()
        Task { await voice.begin() }
    }

    private func voiceUp() { Task { await voice.end() } }

    private func toggleVoice() {
        if case .recording = voice.state { voiceUp() } else { Task { await voice.begin() } }
    }

    private func voiceChanged(_ st: VoiceCapture.State) {
        voiceTimer?.invalidate()
        switch st {
        case .idle: captureState.recording = false; captureState.voiceStatus = nil
        case .recording:
            captureState.recording = true
            captureState.voiceStatus = "Recording… release the shortcut (or Stop) when done"
            voiceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.voice.overLimit { self.voiceUp(); self.captureState.voiceStatus = "Stopped at the 60-second limit." }
                }
            }
        case .transcribing: captureState.recording = false; captureState.voiceStatus = "Transcribing on this Mac…"
        case let .review(t):
            captureState.recording = false
            captureState.text = t.text
            let low = (t.confidence ?? 1) < 0.5
            captureState.voiceStatus = low ? "Transcribed on this Mac, but it wasn't sure. Check the text, then press Return." : "Transcribed on this Mac. Check it, then press Return."
            _ = voice.accept()
        case let .failed(e):
            captureState.recording = false
            captureState.voiceStatus = e.localizedDescription
        }
    }

    // MARK: Capture panel

    func showCapture() {
        if panel.isVisible { panel.makeKey(); return }
        captureState.text = model.settings.captureDraft
        captureState.status = ""
        captureState.aiAvailable = model.ai.usableModel != nil
        captureState.voiceEnabled = model.settings.voiceEnabled
        captureState.presentations += 1
        panel.present()
    }

    private func submitCapture(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !captureState.busy else { return }
        captureState.busy = true
        Task {
            let reply = await model.submitFromCapture(text)
            captureState.busy = false
            switch reply {
            case .saved: closeCapture()
            case let .resolution(r): captureState.reply = r
            case let .failed(msg): captureState.status = msg
            }
        }
    }

    private func confirmProposal(_ p: ContextProposal) {
        Task {
            let r = await model.confirmProposal(p)
            if r?.status == .succeeded || r?.status == .unverified { closeCapture() }
            else { captureState.reply = .notFound(r?.message ?? "That didn't work."); captureState.status = r?.message ?? "" }
        }
    }

    private func openAISetup() {
        closeCapture()
        model.route = .aiSetup
        openPopover()
    }

    private func chooseCandidate(_ c: Candidate, _ p: PendingCommand) { captureState.reply = model.choose(c, for: p) }

    private func saveAsNew(_ text: String) {
        if model.capture(text, source: .hotkey) { closeCapture() }
    }

    private func closeCapture() {
        captureState.text = ""
        captureState.reply = nil
        captureState.status = ""
        model.settings.captureDraft = ""
        panel.orderOut(nil)
    }

    private func cancelCapture() {
        voice?.cancel()
        if case let .proposal(p)? = captureState.reply { model.cancelProposal(p) }
        closeCapture()
    }

    // MARK: Popover

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : openPopover()
    }

    func openPopover() {
        guard let button = statusItem.button else { return }
        model.reload()
        Task { await model.refreshAI(); model.notificationStatus = await model.notifications.refreshStatus() }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        if model.route == .settings { model.route = .list }
    }

    /// Opening Wren again from Finder, Spotlight or the Dock area shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow?.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: URL scheme fallback: `open wren://capture`

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "wren" {
            switch url.host {
            case "capture": showCapture()
            case "open": mainWindow.show()
            #if DEBUG
            case "debug": debugURL(url)
            #endif
            default: openPopover()
            }
        }
    }

    #if DEBUG
    /// Debug builds only: lets automated checks capture text without a keyboard.
    /// Compiled out of release builds so nothing outside Wren can inject captures.
    private func debugURL(_ url: URL) {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.path {
        case "/capture":
            if let text = q.first(where: { $0.name == "text" })?.value {
                let ok = model.capture(text, source: .urlScheme)
                appLog.notice("debug capture saved=\(ok, privacy: .public)")
            }
        case "/state":
            model.reload()
            for c in model.pending + model.closed {
                appLog.notice("debug item kind=\(c.kind.rawValue, privacy: .public) status=\(c.status.rawValue, privacy: .public) processing=\(c.processing.rawValue, privacy: .public) deadline=\(c.deadline?.description ?? "nil", privacy: .public) next=\(c.nextReminderAt?.description ?? "nil", privacy: .public) last=\(c.lastReminderAt?.description ?? "nil", privacy: .public)")
            }
            appLog.notice("debug pause=\(self.model.pauseLabel ?? "none", privacy: .public) backups=\(self.model.backups.list().count, privacy: .public)")
            appLog.notice("debug notifications=\(self.model.notificationStatus.rawValue, privacy: .public) ai=\(self.model.ai.title, privacy: .public) briefing=\(self.model.todayRun.briefing.rawValue, privacy: .public) checkIn=\(self.model.todayRun.checkIn.rawValue, privacy: .public) login=\(self.model.loginStatus.label, privacy: .public)")
            let rules = self.model.policy.rules.map(\.rawValue).sorted().joined(separator: ",")
            let grants = self.model.policy.grants.map(\.rawValue).sorted().joined(separator: ",")
            appLog.notice("debug policy rules=\(rules, privacy: .public) grants=\(grants, privacy: .public)")
            for a in self.model.audit.prefix(8) {
                appLog.notice("debug audit \(a.action, privacy: .public) \(a.status.rawValue, privacy: .public) by=\(a.origin, privacy: .public) auth=\(a.authorization ?? "-", privacy: .public)")
            }
        case "/delivered":
            Task {
                let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
                let ids = delivered.map(\.request.identifier).joined(separator: ",")
                appLog.notice("debug delivered count=\(delivered.count, privacy: .public) ids=\(ids, privacy: .public)")
            }
        case "/checkin":
            // Force-evaluate today's check-in with the time moved to now (debug only).
            let minutes = Calendar.current.component(.hour, from: .now) * 60 + Calendar.current.component(.minute, from: .now)
            if minutes >= 15 * 60 && minutes < 23 * 60 { model.updateDaily { $0.checkInMinutes = minutes } }
            model.scheduleTick()
        case "/login":
            let on = q.first(where: { $0.name == "on" })?.value == "1"
            model.setLaunchAtLogin(on)
            appLog.notice("debug login on=\(on, privacy: .public) status=\(self.model.loginStatus.label, privacy: .public)")
        case "/command":
            // Debug only: run a contextual command as if typed in the capture panel.
            if let text = q.first(where: { $0.name == "text" })?.value {
                Task {
                    let reply = await model.submitFromCapture(text)
                    switch reply {
                    case .saved: appLog.notice("debug command saved as new capture")
                    case let .failed(m): appLog.notice("debug command failed: \(m, privacy: .public)")
                    case let .resolution(r):
                        switch r {
                        case let .proposal(p):
                            debugProposal = p
                            appLog.notice("debug command proposal: \(p.preview, privacy: .public) origin=\(p.request.origin.label, privacy: .public)")
                        case let .clarify(q, c, _): appLog.notice("debug command clarify: \(q, privacy: .public) candidates=\(c.count, privacy: .public)")
                        case let .answer(a): appLog.notice("debug command answer: \(a.title, privacy: .public) lines=\(a.lines.count, privacy: .public)")
                        case let .notFound(m), let .needsDate(m): appLog.notice("debug command: \(m, privacy: .public)")
                        case .notACommand: break
                        }
                    }
                }
            }
        case "/submit-unconfirmed":
            // Debug only: submit the last proposal WITHOUT confirming, to show the broker refuses.
            if let p = debugProposal {
                Task {
                    let r = await model.broker?.submit(p.request)
                    appLog.notice("debug unconfirmed submit status=\(r?.status.rawValue ?? "-", privacy: .public)")
                }
            }
        case "/confirm":
            if let p = debugProposal {
                Task {
                    let r = await model.confirmProposal(p)
                    appLog.notice("debug confirmed status=\(r?.status.rawValue ?? "-", privacy: .public) auth=\(r?.authorization?.label ?? "-", privacy: .public)")
                }
            }
        case "/ai-test":
            Task {
                await model.refreshAI()
                await model.testAI()
                for st in model.aiReport?.steps ?? [] { appLog.notice("debug ai step \(st.name, privacy: .public): \(st.outcome.rawValue, privacy: .public) \(st.detail, privacy: .public)") }
                appLog.notice("debug ai state: \(self.model.ai.title, privacy: .public)")
            }
        case "/ai-download":
            // Debug only: the same code path as the Download button.
            let name = q.first(where: { $0.name == "model" })?.value ?? "qwen2.5:3b"
            model.startDownload(name)
        case "/ai-download-cancel":
            model.cancelDownload()
        case "/ai-state":
            appLog.notice("debug ai state: \(self.model.ai.title, privacy: .public) download=\(String(describing: self.model.download), privacy: .public)")
        case "/pause":
            let o = NotificationPause.Option(rawValue: q.first(where: { $0.name == "o" })?.value ?? "oneHour") ?? .oneHour
            model.pauseNotifications(o)
            appLog.notice("debug paused: \(self.model.pauseLabel ?? "-", privacy: .public)")
        case "/resume":
            model.resumeNotifications()
        case "/backup":
            model.backupNow()
            appLog.notice("debug backups=\(self.model.backupList.count, privacy: .public) newest=\(self.model.backupList.first?.id ?? "-", privacy: .public)")
        case "/restore-latest":
            // Debug only: restore the newest manual backup as if the user confirmed it.
            guard let e = model.backups.list().first(where: { $0.manifest?.reason == .manual }), let broker = model.broker else { break }
            let req = ActionRequest(action: BuiltInAction.restoreBackup, target: e.targetRef, origin: .user(.settings), createdAt: Date())
            Task {
                let first = await broker.submit(req)
                appLog.notice("debug restore unconfirmed=\(first.status.rawValue, privacy: .public)")
                let r = await broker.submit(req, confirmation: broker.confirm(req))
                appLog.notice("debug restore confirmed=\(r.status.rawValue, privacy: .public) \(r.message ?? "", privacy: .public)")
                if r.status == .succeeded { model.relaunch() }
            }
        case "/connectors":
            Task {
                await model.hub.registry.refreshAll()
                for d in ConnectorCatalog.all { appLog.notice("debug connector \(d.id.rawValue, privacy: .public): \(self.model.hub.registry.state(d.id).label, privacy: .public) \(self.model.hub.registry.state(d.id).detail ?? "", privacy: .public)") }
                appLog.notice("debug speech auth=\(self.model.hub.voicePermissions.speech.rawValue, privacy: .public) mic=\(self.model.hub.voicePermissions.microphone.rawValue, privacy: .public) onDevice=\(OnDeviceTranscriber.availability() ?? "available", privacy: .public)")
            }
        case "/handoff":
            // Debug only: same path as pressing "Copy and open ChatGPT" on the preview.
            let task = q.first(where: { $0.name == "task" })?.value ?? "Brainstorm ten names for a personal assistant app"
            model.hub.chatgpt.enabled = true
            Task {
                let draft = HandoffDraft(task: task, depth: .deep)
                guard let r = model.newDelegation(task, destination: .chatgptHandoff, depth: .deep) else { return }
                let err = await model.handOff(draft, record: r)
                appLog.notice("debug handoff error=\(err ?? "none", privacy: .public) status=\(r.status.rawValue, privacy: .public) promptChars=\(r.prompt?.count ?? 0, privacy: .public)")
            }
        case "/chatgpt-off":
            model.hub.chatgpt.enabled = false
            try? model.policyStore?.setGrant(.chatgptHandoff, granted: false)
            model.connectorsChanged()
            appLog.notice("debug chatgpt handoff off: \(self.model.hub.chatgpt.state.label, privacy: .public)")
        case "/transcribe":
            // Debug only: on-device transcription of a given audio file (only if already authorized).
            guard let path = q.first(where: { $0.name == "file" })?.value else { break }
            guard model.hub.voicePermissions.speech == .granted else { appLog.notice("debug transcribe skipped: speech auth=\(self.model.hub.voicePermissions.speech.rawValue, privacy: .public)"); break }
            Task {
                do { let t = try await OnDeviceTranscriber().transcribe(URL(fileURLWithPath: path)); appLog.notice("debug transcript onDevice=\(t.onDevice, privacy: .public): \(t.text, privacy: .public)") }
                catch { appLog.notice("debug transcribe failed: \(error.localizedDescription, privacy: .public)") }
            }
        case "/window-state":
            appLog.notice("debug window visible=\(self.mainWindow.isVisible, privacy: .public) active=\(NSApp.isActive, privacy: .public) route=\(String(describing: self.model.route), privacy: .public)")
        case "/insights":
            model.reload()
            for i in model.insights { appLog.notice("debug insight \(i.kind.rawValue, privacy: .public): \(i.message, privacy: .public)") }
            appLog.notice("debug goals=\(self.model.goals.count, privacy: .public) insights=\(self.model.insights.count, privacy: .public)")
        case "/delete-first":
            if let c = model.pending.last { model.delete(c) }
            appLog.notice("debug delete requested; confirmation pending=\(self.model.confirmation != nil, privacy: .public)")
        default: break
        }
    }
    #endif
}

/// Entry point used by the `Wren` executable.
public enum WrenMain {
    /// Starts the core (store, policy, broker, engine, resolver, insights) in memory and checks
    /// the result. Prints one line and returns success. No UI, no user data, no network.
    @MainActor public static func smokeTest() -> Bool {
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        do {
            let clock = SystemClock()
            let store = try WrenStore(url: nil)
            let policy = try SwiftDataPolicyStore(context: store.context, clock: clock)
            let broker = ActionBroker(context: store.context, policyStore: policy, clock: clock)
            BuiltInAction.registerLocal(on: broker, store: store, notifier: nil, clock: clock)
            let c = try store.capture("Smoke test tomorrow at 9am", source: .manual)
            let rules = IntentProcessor(client: nil, model: nil).rulesOnly(c.originalText, now: clock.now)
            guard rules.deadline != nil, rules.kind == .commitment else { print("smoke-test FAILED: date rules"); return false }
            guard case .proposal = ContextResolver().resolve("mark the smoke test as done", items: try store.all(), goals: [], context: .init(), now: clock.now)
            else { print("smoke-test FAILED: resolver"); return false }
            _ = InsightEngine.compute(items: try store.all(), goals: [], now: clock.now, calendar: clock.calendar)
            _ = WrenMark.menuBarImage()
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            print("smoke-test ok arch=\(arch) version=\(version) actions=\(broker.allDescriptors.count)")
            return true
        } catch {
            print("smoke-test FAILED: \(error)")
            return false
        }
    }

    @MainActor private static var delegate: AppDelegate?

    @MainActor public static func run() {
        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
