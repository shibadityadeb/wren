import AppKit
import SwiftUI
import WrenCore
import Carbon.HIToolbox
import os
import UserNotifications

private let appLog = Logger(subsystem: "com.shibadityadeb.wren", category: "app")

/// One regular Mac app: a Dock icon and main window, exactly one menu-bar item with a popover,
/// a global shortcut, the capture panel, reminders and the voice service, all in this process.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem?
    /// Exclusive lock on the data folder, held for the life of the process.
    private var dataLock: DataDirectoryLock?
    private let popover = NSPopover()
    private var panel: CapturePanel!
    private let captureState = CaptureState()
    private var hotKeys: HotKeyService!
    private var voiceKeys: HotKeyService!
    private var voice: VoiceSession!
    private var voiceTimer: Timer?
    private var autoClose: DispatchWorkItem?
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
        // Whatever the bundle identifier or install location, only one process may use the data.
        var waitedForLock: TimeInterval = 0
        while dataLock == nil {
            do { dataLock = try DataDirectoryLock.acquire(directory: WrenStore.defaultDirectory) } catch {
                if isRelaunch, waitedForLock < 10 { Thread.sleep(forTimeInterval: 0.25); waitedForLock += 0.25; continue }
                appLog.notice("data folder in use by another Wren: \(error.localizedDescription, privacy: .public); exiting")
                if case let DataDirectoryLock.Failure.heldByAnotherProcess(pid?) = error {
                    NSRunningApplication(processIdentifier: pid)?.activate()
                }
                NSApp.terminate(nil)
                return
            }
        }
        AppMenu.install(target: self)
        model = AppModel()
        mainWindow = MainWindowController(model: model)

        // Exactly one status item per process, created once here and removed on quit.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = WrenMark.menuBarImage()
        item.button?.action = #selector(statusItemClicked)
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.setAccessibilityLabel("Wren")
        statusItem = item

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
                        toggleVoice: { [weak self] in self?.toggleVoice() },
                        retryVoice: { [weak self] in self?.retryVoice() },
                        askAction: { [weak self] a in self?.askAction(a) },
                        editedWhileListening: { [weak self] in self?.editedWhileListening() })
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
        // One voice service: holding the push-to-talk shortcut and every Voice button feed the same
        // capture and the same command router as typed text.
        let stream = LiveSpeechStream()
        stream.onLevel = { [weak self] l in
            guard let self, self.captureState.recording else { return }
            self.captureState.voiceLevel = l
        }
        voice = VoiceSession(stream: stream, permissions: model.hub.voicePermissions)
        observeScreenLock()
        // Nothing here touches the microphone: it opens only while the user holds the push-to-talk
        // shortcut (or after clicking Voice), and closes before transcription.
        voice.onPhase = { [weak self] p in self?.voicePhaseChanged(p) }
        voice.onLiveText = { [weak self] t in
            guard let self else { return }
            self.captureState.lastVoiceText = t
            self.captureState.text = t
        }
        voice.onTranscript = { [weak self] t, assessment in self?.transcriptReady(t, assessment) }
        voiceKeys = HotKeyService(id: 2, onPress: { [weak self] in self?.pushToTalkDown() },
                                  onRelease: { [weak self] in self?.pushToTalkUp() })
        model.applyVoiceHotKey = { [weak self] in self?.applyVoiceHotKey() }
        model.startVoice = { [weak self] in self?.popover.performClose(nil); self?.startOrStopVoice(.button) }
        model.prefillCapture = { [weak self] t in self?.captureState.text = t }
        // A delegation whose result is on screen in the panel doesn't also get a notification.
        model.isShowingDelegation = { [weak self] id in
            guard let self, self.panel.isVisible, self.panel.isKeyWindow else { return false }
            return self.captureState.ask?.recordID == id
        }
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

    // MARK: Voice: push-to-talk and the Voice buttons

    private func applyVoiceHotKey() {
        captureState.voiceEnabled = true
        captureState.voiceShortcut = model.settings.voiceEnabled ? model.settings.voiceHotKey.display : nil
        guard model.settings.voiceEnabled else { voiceKeys.unregister(); model.voiceHotKeyError = nil; return }
        model.voiceHotKeyError = voiceKeys.register(model.settings.voiceHotKey)
        if let e = model.voiceHotKeyError {
            appLog.error("push-to-talk \(self.model.settings.voiceHotKey.display, privacy: .public) not registered: \(e, privacy: .public)")
        } else {
            appLog.notice("push-to-talk \(self.model.settings.voiceHotKey.display, privacy: .public) registered")
        }
        // The capture shortcut gives way if it clashed (the setting resolves it); re-register it.
        if model.hotKeyEnabled { applyHotKey() }
        model.hotKeyDisplay = model.settings.hotKey.display
    }

    /// Key-down of the push-to-talk shortcut. Key repeat while held does nothing (the session ignores it).
    /// When the current push-to-talk press began.
    private var pttPressedAt: Date?
    /// Whether the push-to-talk key's physical state can be read (it read as down at key-down).
    /// When it can't, Wren relies on the modifier state and the timing below.
    private var pttKeyStateReadable = false
    /// A press shorter than this is a tap: Wren keeps listening hands-free instead of stopping.
    static let tapThreshold: TimeInterval = 0.6

    private func pttKeyIsDown() -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(model.settings.voiceHotKey.keyCode))
    }
    private var pttModifiersHeld: Bool { NSEvent.modifierFlags.isSuperset(of: heldModifiers) }

    private func pushToTalkDown() {
        guard model.settings.voiceEnabled else { return }
        // Pressed again during a hands-free recording: that's "stop".
        if voice.phase == .listening(.button) { appLog.notice("push-to-talk pressed again: stop"); voice.release(); return }
        if voice.isCapturing { return }   // key repeat while held
        pttPressedAt = Date()
        pttKeyStateReadable = pttKeyIsDown()
        appLog.notice("push-to-talk down (key state readable: \(self.pttKeyStateReadable, privacy: .public))")
        startOrStopVoice(.hold)
    }

    /// macOS reported the push-to-talk key going up. On some setups that report arrives while the
    /// keys are still held (seen live: 80–330 ms after key-down, as the panel takes focus), so it's
    /// checked rather than trusted.
    private func pushToTalkUp() {
        switch voice.phase {
        case .requestingPermission: voice.release()
        case .listening(.hold): holdMayHaveEnded("key-up event")
        default: break
        }
    }

    /// The keys look released. Still physically down: ignore. A tap: keep listening hands-free.
    /// Otherwise: the user let go, so stop and transcribe.
    private func holdMayHaveEnded(_ why: String) {
        guard case .listening(.hold) = voice.phase else { return }
        if pttKeyStateReadable, pttModifiersHeld, pttKeyIsDown() {
            appLog.notice("push-to-talk: ignored \(why, privacy: .public); keys still held")
            return
        }
        let held = Date().timeIntervalSince(pttPressedAt ?? .distantPast)
        if held < Self.tapThreshold {
            appLog.notice("push-to-talk: short press (\(Int(held * 1000), privacy: .public) ms, \(why, privacy: .public)); listening hands-free until a pause")
            voice.continueHandsFree()
            return
        }
        appLog.notice("push-to-talk up (\(why, privacy: .public), held \(Int(held * 1000), privacy: .public) ms)")
        voice.release()
    }

    /// The shortcut, the Voice buttons and the menu all go through here.
    private func startOrStopVoice(_ trigger: VoiceSession.Trigger) {
        // A command is still being recorded, transcribed or run: a repeated press does nothing.
        if voice.phase.isBusy && !(trigger == .button && voice.phase == .listening(.button)) { return }
        if !voice.isCapturing {
            autoClose?.cancel()
            showCapture()
            captureState.reply = nil; captureState.ask = nil; captureState.reviewingVoice = false
            captureState.text = ""; captureState.lastVoiceText = ""
        }
        Task { await voice.press(trigger) }
    }

    private func toggleVoice() { startOrStopVoice(.button) }

    /// "Record again" after a wrong transcription: the old text is discarded and a new command recorded.
    private func retryVoice() {
        captureState.text = ""; captureState.lastVoiceText = ""
        captureState.reviewingVoice = false
        voice.reset()
        startOrStopVoice(.button)
    }

    /// Modifiers a push-to-talk shortcut needs held, as AppKit reports them.
    private var heldModifiers: NSEvent.ModifierFlags {
        let c = model.settings.voiceHotKey.carbonModifiers
        var f: NSEvent.ModifierFlags = []
        if c & UInt32(optionKey) != 0 { f.insert(.option) }
        if c & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if c & UInt32(controlKey) != 0 { f.insert(.control) }
        if c & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    private func voicePhaseChanged(_ p: VoiceSession.Phase) {
        model.voicePhase = p
        model.hub.voice.phase = p
        captureState.voicePhase = p
        statusItem?.button?.image = WrenMark.menuBarImage(listening: voice.isCapturing)
        voiceTimer?.invalidate(); voiceTimer = nil
        captureState.recording = p.isCapturingPhase
        switch p {
        case let .listening(trigger):
            if !panel.isVisible { showCapture() }
            captureState.voiceLevel = 0
            captureState.voiceStatus = nil
            // Push-to-talk ends when *either* key is let go. Carbon reports the Space key coming up;
            // the modifier is checked here (reading the current modifier state needs no permission).
            let needed = heldModifiers
            voiceTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if trigger == .hold {
                        // Letting go of either key ends a hold (checked here, not only on macOS's key-up event).
                        if !NSEvent.modifierFlags.isSuperset(of: needed) { self.holdMayHaveEnded("modifier released"); return }
                        if self.pttKeyStateReadable, !self.pttKeyIsDown() { self.holdMayHaveEnded("key released"); return }
                    }
                    self.voice.tick()
                }
            }
        case let .cancelled(reason):
            captureState.voiceStatus = reason.message
            if reason != .byUser { closeAfter(4) }
        case let .failed(e):
            captureState.voiceStatus = e.localizedDescription
            appLog.notice("voice failed: \(String(describing: e).prefix(40), privacy: .public)")
        default:
            captureState.voiceStatus = nil
        }
        model.connectorVersion += 1
    }

    /// The final transcript, once per utterance. A clear one runs at once, through exactly the same
    /// router as typed text; an unclear one, or any when "check before running" is on, waits for Return.
    private func transcriptReady(_ text: String, _ assessment: TranscriptAssessment) {
        appLog.notice("voice transcript ready (\(text.count, privacy: .public) characters, \(String(describing: assessment).prefix(7), privacy: .public))")
        if !panel.isVisible { showCapture() }
        captureState.lastVoiceText = text
        captureState.text = text
        if case let .confirm(why) = assessment {
            reviewTranscript(why)
        } else if model.settings.voiceReviewFirst {
            reviewTranscript("Transcribed on this Mac. Fix any wrong words, then press Return.")
        } else {
            // Long enough to read what was heard, short enough not to feel like waiting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.voice.phase == .transcriptReady(text) else { return }
                    self.execute(text, channel: .voice)
                }
            }
        }
    }

    private func reviewTranscript(_ note: String) {
        captureState.reviewingVoice = true
        captureState.voiceStatus = note
        captureState.presentations += 1
        panel.makeKey()
    }

    /// Runs one command (typed, reviewed or spoken) and shows its real outcome. For voice the
    /// session moves processing → completed / needs clarification / failed from the actual reply.
    private func execute(_ text: String, channel: UserChannel) {
        guard !captureState.busy else { return }
        let spoken = channel == .voice
        if spoken { voice.beginProcessing(text) }
        captureState.reviewingVoice = false
        captureState.busy = true
        Task {
            let reply = await model.submitFromCapture(text, channel: channel)
            captureState.busy = false
            appLog.notice("command result: \(Self.describe(reply), privacy: .public)")
            var outcome: VoiceSession.Outcome
            switch reply {
            case .saved:
                outcome = .completed("Saved")
                if spoken { captureState.voiceStatus = "Saved “\(text)”."; closeAfterVoice(4) } else { closeCapture() }
            case let .resolution(r):
                captureState.reply = r
                outcome = Self.outcome(of: r)
                if case .answer = r, spoken { closeAfterVoice(12) }
            case let .failed(m):
                captureState.status = m
                outcome = .failed(m)
            case let .ask(r):
                showAsk(r, channel: channel)
                outcome = askOutcome()
            }
            if spoken {
                // A follow-up question is answered in the field: clear the old sentence for the answer.
                if case .needsClarification = outcome, !isProposalReply { captureState.text = ""; captureState.lastVoiceText = "" }
                voice.finishProcessing(outcome)
            }
        }
    }

    private var isProposalReply: Bool { if case .proposal? = captureState.reply { true } else { false } }

    static func outcome(of r: ContextResolution) -> VoiceSession.Outcome {
        switch r {
        case let .answer(a): .completed(a.title)
        case let .proposal(p): .needsClarification("Confirm this change: \(p.preview)")
        case let .clarify(q, _, _): .needsClarification(q)
        case let .needsDate(q): .needsClarification(q)
        case let .notFound(m): .failed(m)
        case .notACommand: .completed("Saved")
        }
    }

    /// What the Ask card shows right after a spoken GPT request was handed over.
    private func askOutcome() -> VoiceSession.Outcome {
        guard let card = captureState.ask else { return .failed("The request couldn't be started.") }
        switch card.phase {
        case .sending: return card.destination == .chatgptWeb ? .completed("Opening ChatGPT…") : (card.destination == .local ? .completed("Asking local AI…") : .completed("GPT request submitted"))
        case .answered, .partial: return card.destination == .local ? .completed("Local AI answered") : .completed("GPT request submitted")
        case let .handedOff(state, _): return state == .failedToOpen ? .failed(WebHandoffState.failedToOpen.detail) : .completed("Opened in ChatGPT: \(state.label.lowercased())")
        case .ready: return card.destination == .choose ? .needsClarification("Local AI isn't set up. Who should answer this?") : .completed("Request ready")
        case .notConnected: return .failed("ChatGPT isn't connected. Connect it below; your request is kept.")
        case let .reconnect(m), let .needsPermission(m), let .usageLimit(m), let .needsReview(m), let .unsupported(m): return .failed(m)
        case let .failed(m, _): return .failed(m)
        case .connecting: return .completed("Connecting to ChatGPT…")
        }
    }

    /// Kind of result only (never the words), for diagnostics.
    static func describe(_ r: CaptureReply) -> String {
        switch r {
        // Messages can quote the user's words ("When should I remind you to call Sam?"), so only kinds are logged.
        case .saved: return "saved as a new item"
        case .failed: return "failed"
        case let .ask(r): return r.target == .chatgpt ? "ask ChatGPT" : "general question (choose who answers)"
        case let .resolution(res):
            switch res {
            case let .answer(a): return "answer: \(a.title.hasPrefix("Reminder created") ? "reminder created" : "\(a.lines.count) lines")"
            case .proposal: return "proposal awaiting confirmation"
            case .clarify: return "asked which item"
            case .needsDate: return "asked a follow-up question"
            case .notFound: return "not found"
            case .notACommand: return "not a command"
            }
        }
    }

    /// Closes the panel after a spoken command's result has been visible for a while,
    /// unless the user started typing or another command began.
    private func closeAfter(_ seconds: TimeInterval) {
        autoClose?.cancel()
        let snapshot = captureState.text
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.captureState.text == snapshot, !self.voice.phase.isBusy, self.captureState.ask == nil || self.captureState.ask?.phase.isSending == false else { return }
                self.closeCapture()
            }
        }
        autoClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func closeAfterVoice(_ seconds: TimeInterval) { closeAfter(seconds) }

    // MARK: Capture panel

    func showCapture() {
        if panel.isVisible { panel.makeKey(); return }
        captureState.text = model.settings.captureDraft
        captureState.status = ""
        captureState.aiAvailable = model.ai.usableModel != nil
        captureState.voiceEnabled = true
        captureState.presentations += 1
        panel.present()
    }

    private func submitCapture(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !captureState.busy else { return }
        // A reviewed spoken command runs as voice (same pipeline, same audit channel).
        let channel: UserChannel = captureState.reviewingVoice ? .voice : .hotkey
        appLog.notice("panel submit (reviewing voice: \(self.captureState.reviewingVoice, privacy: .public), phase: \(String(describing: self.voice.phase).prefix(20), privacy: .public))")
        if voice.isCapturing { voice.cancel() }
        captureState.recording = false
        execute(text, channel: channel)
    }

    /// Typing while Wren is recording: stop recording and keep what's in the field for editing.
    private func editedWhileListening() {
        guard captureState.recording else { return }
        voice.cancel()
        captureState.recording = false
        captureState.reviewingVoice = true
        captureState.voiceStatus = "Recording stopped because you typed. Edit the text, then press Return."
    }

    /// Locking the screen or sleeping drops a command being recorded. Nothing restarts afterwards.
    private func observeScreenLock() {
        let stop: @MainActor () -> Void = { [weak self] in
            guard let self, let v = self.voice, v.phase.isBusy else { return }
            v.cancel(.screenLocked)
            appLog.notice("voice capture cancelled: screen locked or sleep")
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { stop() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { stop() } }
        }
    }

    // MARK: Ask ChatGPT / local AI from the panel

    private var askChannel: UserChannel = .hotkey

    /// Shows the Ask card and runs it. Naming GPT/ChatGPT goes to ChatGPT, in the mode the user chose
    /// (the website by default, or connected ChatGPT in Wren); it never asks "local or ChatGPT?" and
    /// never falls back to the local model. A question naming no assistant goes to the local AI; only
    /// when none is set up does the card offer the choices.
    private func showAsk(_ r: AIRequest, channel: UserChannel) {
        askChannel = channel
        captureState.reply = nil
        let local = model.ai.usableModel != nil
        let destination: AskCard.Destination
        if r.target == .chatgpt { destination = (r.mode ?? model.settings.chatgptMode) == .web ? .chatgptWeb : .chatgpt }
        else { destination = local ? .local : .choose }
        var card = AskCard(request: r, destination: destination)
        card.localAvailable = local
        card.chatgptReady = model.hub.chatgpt.account.canSend
        if destination == .choose { card.note = "Local AI isn't set up, so nothing answered yet. Set it up, ask ChatGPT, or keep it as a note." }
        captureState.ask = card
        if destination != .choose { askAction(.run(destination)) }
    }

    /// The ChatGPT website: opens it with the request and shows what Wren really knows about it.
    private func runWeb(_ card: AskCard) {
        var card = card
        card.destination = .chatgptWeb
        card.phase = .sending(recordID: nil)
        card.note = nil
        captureState.ask = card
        let request = card.request, channel = askChannel
        Task {
            let (rec, error) = await model.startWebHandoff(request, channel: channel)
            guard captureState.ask?.request == request else { return }
            captureState.ask?.recordID = rec?.id
            if let error {
                captureState.ask?.phase = .failed(error, retryable: rec != nil)
            } else if let rec {
                captureState.ask?.phase = .handedOff(rec.webState ?? .awaitingSubmission, recordID: rec.id)
            }
        }
    }

    private func askAction(_ a: AskAction) {
        guard var card = captureState.ask else { return }
        switch a {
        case .run(.chatgptWeb):
            guard !card.phase.isSending else { return }
            runWeb(card)
        case .openInChatGPT:
            guard let id = card.recordID else { runWeb(card); return }
            Task {
                if let e = await model.reopenInChatGPT(id) { captureState.ask?.note = e }
                else if let r = model.asks?.record(id) { captureState.ask?.phase = .handedOff(r.webState ?? .awaitingSubmission, recordID: id) }
            }
        case .markSent:
            guard let id = card.recordID else { return }
            model.markWebSubmitted(id)
            card.phase = .handedOff(.submittedUnverified, recordID: id)
            card.note = "Noted. The answer is in your ChatGPT conversation; link it so Open in ChatGPT goes straight there."
            captureState.ask = card
        case .linkConversation:
            guard let id = card.recordID else { return }
            if let e = model.linkConversationFromClipboard(id) { card.note = e }
            else { card.phase = .handedOff(.conversationLinked, recordID: id); card.note = "Linked. Open in ChatGPT now goes to that conversation." }
            captureState.ask = card
        case .runInWren:
            // The user explicitly chose the in-Wren mode for this request.
            card.destination = .chatgpt; card.phase = .ready; card.recordID = nil
            card.request.mode = .inWren
            captureState.ask = card
            askAction(.run(.chatgpt))
        case let .run(dest):
            // One request at a time: a second Return, click or voice event while sending does nothing.
            guard !card.phase.isSending else { return }
            let target: AskCard.Destination = dest == .choose ? .chatgpt : dest
            if card.destination != target { card.destination = target }
            card.streamed = ""; card.note = nil
            let request = card.request, channel = askChannel
            if target == .local {
                card.phase = .sending(recordID: nil)
                captureState.ask = card
                captureState.busy = true
                Task {
                    let outcome = await model.askLocalModel(request) ?? .failed("Local AI isn't set up. Set it up in Wren › Local AI, or ask ChatGPT.", retryable: false)
                    captureState.busy = false
                    guard captureState.ask?.request == request else { return }
                    captureState.ask?.phase = Self.phase(for: outcome)
                }
                return
            }
            // ChatGPT runs as a tracked delegation: persisted first, independent of this panel, and
            // announced when it finishes. A failed earlier attempt is retried on the same record.
            let start: AskStart
            if let id = card.recordID, model.asks?.record(id)?.canRetry == true { start = model.retryDelegation(id) }
            else {
                start = model.startDelegation(request, channel: channel) { [weak self] d in
                    guard let self, self.captureState.ask?.request == request, self.captureState.ask?.phase.isSending == true else { return }
                    self.captureState.ask?.streamed += d
                }
            }
            switch start {
            case let .notRun(o):
                card.phase = Self.phase(for: o)
                captureState.ask = card
            case let .started(id), let .duplicate(id):
                card.recordID = id
                if case .duplicate = start, let r = model.asks?.record(id), r.status != .running, let o = model.asks?.outcome(of: r) {
                    card.phase = Self.phase(for: o)
                    card.note = "Already sent a moment ago; nothing new was sent."
                    captureState.ask = card
                    return
                }
                card.phase = .sending(recordID: id)
                card.note = "Sent to ChatGPT. You can close this; Wren will tell you when it's finished."
                captureState.ask = card
                appLog.notice("delegation \(id.uuidString.prefix(8), privacy: .public) \(String(describing: start).prefix(9), privacy: .public)")
                Task {
                    guard let outcome = await model.asks?.outcome(id) else { return }
                    guard captureState.ask?.request == request else { return }
                    captureState.ask?.phase = Self.phase(for: outcome)
                    captureState.ask?.note = nil
                }
            }
        case .connect:
            card.phase = .connecting; captureState.ask = card
            model.connectChatGPT { [weak self] in
                guard let self, self.captureState.ask?.request == card.request else { return }
                self.showCapture()
                if self.model.hub.chatgpt.account.canSend {
                    self.captureState.ask?.phase = .ready
                    self.captureState.ask?.destination = .chatgpt
                    self.captureState.ask?.note = "Connected. Press Return to ask."
                } else {
                    self.captureState.ask?.phase = Self.phase(for: .notConnected)
                    self.captureState.ask?.note = self.model.hub.chatgpt.account.reason ?? "ChatGPT isn't connected yet."
                }
            }
        case .allowPlan:
            card.phase = .connecting; captureState.ask = card
            model.connectChatGPT(reconsent: true) { [weak self] in
                guard let self, self.captureState.ask?.request == card.request else { return }
                self.showCapture()
                self.captureState.ask?.phase = self.model.hub.chatgpt.account.canSend ? .ready : .needsPermission(self.model.hub.chatgpt.account.reason ?? "Plan usage is still not allowed.")
            }
        case .manageUsage:
            NSWorkspace.shared.open(SIWC.manageUsageURL)
        case .runStandard:
            guard let id = card.recordID, case .started = model.retryDelegation(id, standardSettings: true) else { return }
            card.phase = .sending(recordID: id)
            card.note = "Running again without web search or a reasoning override."
            captureState.ask = card
            let request = card.request
            Task {
                guard let outcome = await model.asks?.outcome(id), captureState.ask?.request == request else { return }
                captureState.ask?.phase = Self.phase(for: outcome); captureState.ask?.note = nil
            }
        case .openDelegate:
            model.delegationDraft = (card.request.prompt, card.request.depth)
            model.route = .delegate
            closeCapture()
            model.openMainWindow()
        case .openAnswer:
            closeCapture()
            if let id = card.recordID { model.openDelegation(id) } else { model.route = .delegate; model.openMainWindow() }
        case .copyAnswer:
            switch card.phase {
            case let .answered(t, _, _), let .partial(t, _, _, _):
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
                captureState.status = "Copied"
            default: break
            }
        case .saveAsNote:
            // Explicit capture: keep exactly what was typed, without running it.
            if model.capture(card.request.original, source: askChannel == .voice ? .voice : .hotkey) {
                captureState.ask = nil
                closeCapture()
            }
        }
    }

    static func phase(for o: AskOutcome) -> AskCard.Phase {
        switch o {
        case let .answered(t, s, id): .answered(text: t, source: s, recordID: id)
        case let .partial(t, s, id, m): .partial(text: t, source: s, recordID: id, message: m)
        case .notConnected: .notConnected
        case let .reconnect(m): .reconnect(m)
        case let .needsPermission(m): .needsPermission(m)
        case let .usageLimit(m): .usageLimit(m)
        case let .needsReview(m): .needsReview(m)
        case let .unsupported(m): .unsupported(m)
        case let .failed(m, r): .failed(m, retryable: r)
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
        autoClose?.cancel()
        voice?.reset()
        captureState.voiceStatus = nil
        captureState.reviewingVoice = false
        captureState.text = ""
        captureState.reply = nil
        captureState.ask = nil
        captureState.status = ""
        model.settings.captureDraft = ""
        panel.orderOut(nil)
    }

    private func cancelCapture() {
        voice?.cancel()
        autoClose?.cancel()
        if case let .proposal(p)? = captureState.reply { model.cancelProposal(p) }
        closeCapture()
    }

    // MARK: Popover

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : openPopover()
    }

    /// Left click: the popover. Right click or Control-click: a menu with Open, Capture, Settings and Quit.
    @objc private func statusItemClicked() {
        let ev = NSApp.currentEvent
        if ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            let menu = statusMenu()
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            togglePopover()
        }
    }

    private func statusMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "Open Wren", action: #selector(openMainWindowAction), keyEquivalent: "").target = self
        m.addItem(withTitle: "New Capture", action: #selector(newCaptureAction), keyEquivalent: "").target = self
        m.addItem(withTitle: voice.isCapturing ? "Stop Voice Command" : "Voice Command", action: #selector(voiceAction), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Wren", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return m
    }

    @objc func openMainWindowAction() { popover.performClose(nil); mainWindow.show() }
    @objc func newCaptureAction() { popover.performClose(nil); showCapture() }
    @objc func voiceAction() { popover.performClose(nil); startOrStopVoice(.button) }
    @objc func openSettingsAction() { popover.performClose(nil); model.route = .settings; mainWindow.show() }
    @objc func showAboutAction() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: NSAttributedString(string: "Local-first personal assistant. Your data stays on this Mac.")])
    }

    @objc func openHelpAction() {
        NSWorkspace.shared.open(URL(string: "https://github.com/shibadityadeb/wren#readme")!)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quit means quit: microphone off, mail checks and running work stop. Scheduled reminders stay with macOS.
        voice?.shutdown()
        voiceTimer?.invalidate()
        hotKeys?.unregister()
        voiceKeys?.unregister()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        dataLock?.release()
        appLog.notice("quit: status item removed, shortcuts released, data unlocked")
    }

    func openPopover() {
        guard let button = statusItem?.button else { return }
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
        for url in urls where AppIdentity.urlSchemes.contains(url.scheme ?? "") {
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
                    case let .ask(r):
                        appLog.notice("debug command ask: target=\(r.target?.rawValue ?? "choose", privacy: .public) prompt=\(r.prompt, privacy: .public)")
                        showCapture(); captureState.text = text
                        showAsk(r, channel: .hotkey)
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
                appLog.notice("debug speech auth=\(self.model.hub.voicePermissions.speech.rawValue, privacy: .public) mic=\(self.model.hub.voicePermissions.microphone.rawValue, privacy: .public) onDevice=\(LiveSpeechStream.availability() ?? "available", privacy: .public) voice=\(String(describing: self.model.voicePhase), privacy: .public)")
            }
        case "/handoff":
            // Debug only: same path as pressing "Copy and open ChatGPT" on the preview.
            let task = q.first(where: { $0.name == "task" })?.value ?? "Brainstorm ten names for a personal assistant app"
            model.hub.chatgpt.handoffEnabled = true
            Task {
                let draft = HandoffDraft(task: task, depth: .deep)
                guard let r = model.newDelegation(task, destination: .chatgptHandoff, depth: .deep) else { return }
                let err = await model.handOff(draft, record: r)
                appLog.notice("debug handoff error=\(err ?? "none", privacy: .public) status=\(r.status.rawValue, privacy: .public) promptChars=\(r.prompt?.count ?? 0, privacy: .public)")
            }
        case "/chatgpt-off":
            model.hub.chatgpt.handoffEnabled = false
            try? model.policyStore?.setGrant(.chatgptHandoff, granted: false)
            model.connectorsChanged()
            appLog.notice("debug chatgpt handoff off: \(self.model.hub.chatgpt.state.label, privacy: .public)")
        case "/chatgpt-connect":
            // Debug only: same as pressing "Continue with ChatGPT". The user still signs in in the browser.
            model.connectChatGPT(reconsent: q.contains { $0.name == "reconsent" })
            appLog.notice("debug chatgpt sign-in started")
        case "/chatgpt-status":
            Task {
                await model.hub.chatgpt.refresh()
                let c = model.hub.chatgpt
                appLog.notice("debug chatgpt account=\(c.account.title, privacy: .public) models=\(c.models.map(\.slug).joined(separator: ","), privacy: .public) selected=\(c.selectedModel ?? "-", privacy: .public) grantAI=\(self.model.policy.grants.contains(.externalAI), privacy: .public)")
            }
        case "/chatgpt-ask":
            // Debug only: same path as pressing "Send with ChatGPT" on the preview (that press is the confirmation).
            let task = q.first(where: { $0.name == "task" })?.value ?? "Reply with the single word: ready"
            Task {
                let start = model.sendToChatGPT(HandoffDraft(task: task, depth: .normal)) { _ in }
                guard case let .started(id) = start, let asks = model.asks else { appLog.notice("debug chatgpt ask not started: \(String(describing: start), privacy: .public)"); return }
                _ = await asks.outcome(id)
                let r = asks.record(id)
                appLog.notice("debug chatgpt ask id=\(id.uuidString.prefix(8), privacy: .public) status=\(r?.status.rawValue ?? "-", privacy: .public) chars=\(r?.response?.count ?? 0, privacy: .public) requested=\(r?.requestedModel ?? "-", privacy: .public) reported=\(r?.reportedModel ?? "-", privacy: .public) error=\(r?.error ?? "none", privacy: .public) notified=\(r?.notifiedAt != nil, privacy: .public)")
            }
        case "/voice-command":
            // Debug only: the step after transcription, with this text as if it had been spoken.
            // The step after transcription, with this text as the final transcript: routed and run
            // exactly as a spoken command (processing → result), without a microphone.
            if let text = q.first(where: { $0.name == "text" })?.value {
                showCapture(); captureState.text = text; captureState.lastVoiceText = text
                execute(text, channel: .voice)
            }
        case "/voice":
            // Debug only: same as pressing the voice shortcut (the microphone really starts).
            startOrStopVoice(.hold)
        case "/voice-release":
            // Debug only: same as letting go of the push-to-talk shortcut.
            pushToTalkUp()
        case "/voice-state":
            appLog.notice("debug voice phase=\(String(describing: self.voice.phase), privacy: .public) microphoneOpen=\(self.voice.isMicrophoneOpen, privacy: .public) pushToTalk=\(self.model.settings.voiceHotKey.display, privacy: .public) registered=\(self.voiceKeys.isRegistered, privacy: .public) capture=\(self.model.settings.hotKey.display, privacy: .public)")
        case "/reminders":
            Task {
                let r = await model.reconcileReminders()
                appLog.notice("debug reminders authorized=\(r.authorized, privacy: .public) scheduled=\(r.scheduled, privacy: .public) cancelled=\(r.cancelled, privacy: .public) unchanged=\(r.unchanged, privacy: .public) failed=\(r.failed.count, privacy: .public)")
                for (id, next) in await model.notifications.pendingReminderSummary() {
                    appLog.notice("debug pending \(id, privacy: .public) next=\(next?.description ?? "-", privacy: .public)")
                }
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
        // A regular app: Dock icon, app menu, Cmd+Q. The menu-bar item is part of the same process.
        app.setActivationPolicy(.regular)
        app.run()
    }
}
