import AppKit
import WrenCore

/// GPT delegations: started from the capture panel (typed or spoken) or the Delegate pane, tracked
/// in the store, announced once when they finish, and reopened from a persistent result view.
@MainActor
extension AppModel {
    func wireDelegations() {
        guard let asks else { return }
        // A request still "running" from a Wren that quit never finished here: say so, offer retry.
        let interrupted = asks.recoverInterrupted()
        if interrupted > 0 { log.notice("marked \(interrupted, privacy: .public) interrupted delegation(s) at launch") }
        asks.onFinished = { [weak self] r in self?.delegationFinished(r) }
    }

    func startDelegation(_ r: AIRequest, channel: UserChannel, reviewed: HandoffDraft? = nil,
                         onDelta: @escaping @MainActor (String) -> Void = { _ in }) -> AskStart {
        guard let asks else { return .notRun(.failed("Wren's database isn't available.", retryable: false)) }
        let s = asks.start(r, channel: channel, reviewed: reviewed, onDelta: onDelta)
        delegationVersion += 1
        if case .started = s { ensureNotificationPermission() }
        return s
    }

    func retryDelegation(_ id: UUID, standardSettings: Bool = false) -> AskStart {
        guard let asks else { return .notRun(.failed("Wren's database isn't available.", retryable: false)) }
        let s = standardSettings ? asks.retryWithStandardSettings(id) : asks.retry(id)
        delegationVersion += 1
        return s
    }

    func cancelDelegation(_ id: UUID) { asks?.cancel(id) }

    /// Running and recent finished delegations for the compact overview list.
    var recentDelegations: [DelegationRecord] {
        let _ = delegationVersion
        return Array(delegations.filter { $0.destination == .chatgptPlan || $0.destination == .chatgptHandoff }.prefix(5))
    }

    var unseenDelegations: Int {
        let _ = delegationVersion
        return delegations.filter { $0.status.isFinal && $0.seenAt == nil && $0.notifiedAt != nil }.count
    }

    /// Opens the saved request and its real result in the main window.
    func openDelegation(_ id: UUID) {
        if let r = asks?.record(id), r.seenAt == nil, r.status.isFinal { r.seenAt = clock.now; try? store?.context.save() }
        delegationVersion += 1
        route = .delegation(id)
        openMainWindow()
    }

    /// Exactly one announcement per finished request: the in-app entry always, and a macOS
    /// notification unless the user is already looking at that result.
    func delegationFinished(_ r: DelegationRecord) {
        delegationVersion += 1
        connectorVersion += 1
        guard r.notifiedAt == nil else { return }
        r.notifiedAt = clock.now
        try? store?.context.save()
        if isShowingDelegation(r.id) { return }
        Task { _ = await notifications.deliverDelegation(r) }
    }

    // MARK: ChatGPT website (handoff)

    enum WebStart { case started(DelegationRecord), review(String), failed(DelegationRecord?, String) }

    /// "Ask in ChatGPT": opens the ChatGPT website in the user's browser (their own signed-in account)
    /// with the question in the message box. ChatGPT doesn't let other apps send it, so the user
    /// presses Enter there; with detection on, Wren watches that tab's address and records the
    /// question as submitted, with the real conversation link, only when ChatGPT creates the
    /// conversation. Persisted as preparing first; through the broker (permission, audit).
    func startWebHandoff(_ r: AIRequest, channel: UserChannel) async -> WebStart {
        guard let store else { return .failed(nil, "Wren's database isn't available.") }
        guard hub.chatgpt.handoffAvailable else {
            return .failed(nil, "Opening ChatGPT in your browser is turned off. Turn it on in Connectors › ChatGPT, or run it with ChatGPT inside Wren.")
        }
        // The question goes into a web address: anything that looks like a secret stops it for review.
        let findings = SensitiveScanner.scan(r.prompt)
        if !findings.isEmpty {
            return .review("This looks like it contains \(findings.map(\.label).joined(separator: ", ")). Check and edit it in Delegate before it goes to ChatGPT.")
        }
        // The same question opened a moment ago (a repeated Return or voice event): not again.
        let key = AskService.key(r.prompt)
        if let recent = delegations.prefix(20).first(where: {
            $0.destination == .chatgptHandoff && AskService.key($0.prompt ?? "") == key && clock.now.timeIntervalSince($0.createdAt) < 15
        }) { return .started(recent) }
        let parent = r.followUpOf.flatMap { id in asks?.record(id) }
        let rec = DelegationRecord(task: r.prompt, destination: .chatgptHandoff, depth: r.depth, now: clock.now)
        rec.prompt = r.prompt; rec.original = r.original; rec.channelRaw = channel.rawValue; rec.kind = r.kind
        rec.parentID = parent?.id; rec.webState = .preparing
        store.context.insert(rec); try? store.context.save()

        // A follow-up in a known conversation: open it; the new instruction goes on the clipboard
        // (a link can't put text into an existing conversation).
        if let linked = parent?.conversationURL {
            rec.webState = .opening; saveDelegation(rec)
            if let e = await openInChatGPT(prompt: r.prompt, url: linked, record: rec, channel: channel, copy: true) { return .failed(rec, e) }
            rec.webMethod = .clipboard; rec.webState = .awaitingSubmission; rec.providerURL = linked.absoluteString
            saveDelegation(rec)
            return .started(rec)
        }
        let launch = ChatGPTWeb.launch(r.prompt, prefill: settings.chatgptPrefill && settings.chatgptDestination != "app")
        // Detection: note the ChatGPT tabs already open, so Wren's own new tab can be told apart.
        var watch: (bundleID: String, before: [BrowserTab])?
        if launch.method == .prefillLink, settings.chatgptDetectConversation, let b = BrowserTabs.defaultBrowser,
           case let .success(before) = await BrowserTabs.chatGPTTabs(bundleID: b.bundleID) {
            watch = (b.bundleID, before)
        }
        rec.webState = .opening; saveDelegation(rec)
        if let e = await openInChatGPT(prompt: r.prompt, url: launch.url, record: rec, channel: channel, copy: launch.method == .clipboard) { return .failed(rec, e) }
        rec.webMethod = launch.method
        rec.webState = launch.method == .prefillLink ? .promptLoaded : .awaitingSubmission
        saveDelegation(rec)
        delegationVersion += 1
        if let watch { watchConversation(rec.id, bundleID: watch.bundleID, before: watch.before) }
        return .started(rec)
    }

    /// Follows the tab Wren opened (address only) for up to 20 minutes: sign-in page → "Sign-in
    /// required"; `chatgpt.com/c/<id>` → really submitted, with the real link. Never guesses: with
    /// several new ChatGPT tabs, or the tab closed, it stops and the state stays as it was.
    func watchConversation(_ id: UUID, bundleID: String, before: [BrowserTab]) {
        Task { @MainActor [weak self] in
            var watcher = ChatGPTTabWatcher(before: before)
            let started = Date()
            while Date().timeIntervalSince(started) < 20 * 60 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !self.stopping, let r = self.asks?.record(id), r.webState?.hasConversation != true else { return }
                switch await BrowserTabs.chatGPTTabs(bundleID: bundleID) {
                case .failure(.notPermitted):
                    self.log.notice("conversation detection: browser control not allowed")
                    self.webHandoffNote(id, "Wren isn't allowed to read your browser's ChatGPT tab, so it can't see when you send it. Allow Wren in System Settings › Privacy & Security › Automation, or link the conversation yourself.")
                    return
                case .failure: continue
                case let .success(tabs):
                    switch watcher.observe(tabs) {
                    case let .conversation(url):
                        r.providerURL = url.absoluteString
                        r.webState = .submittedVerified
                        self.saveDelegation(r); self.delegationVersion += 1
                        self.log.notice("conversation detection: ChatGPT conversation created for request \(id.uuidString.prefix(8), privacy: .public)")
                        self.webHandoffChanged(id)
                        return
                    case .signInRequired where r.webState != .signInRequired:
                        r.webState = .signInRequired; self.saveDelegation(r); self.webHandoffChanged(id)
                    case .closed:
                        self.log.notice("conversation detection: tab closed before sending")
                        return
                    case .waiting where Date().timeIntervalSince(started) > 30:
                        self.log.notice("conversation detection: couldn't tell which tab is Wren's; stopped")
                        return
                    default: break
                    }
                }
            }
        }
    }

    /// Turns detection on from Settings: one harmless read so macOS asks for permission now.
    func detectConversationPermission() async -> String? {
        guard let b = BrowserTabs.defaultBrowser else { return "Your default browser isn't one Wren can follow." }
        switch await BrowserTabs.chatGPTTabs(bundleID: b.bundleID) {
        case .success: settings.chatgptDetectConversation = true; return nil
        case .failure(.notPermitted):
            settings.chatgptDetectConversation = false
            return "Wren wasn't allowed to read \(b.name)'s ChatGPT tabs. Allow it in System Settings › Privacy & Security › Automation › Wren, then turn this on again."
        case let .failure(.unavailable(m)):
            settings.chatgptDetectConversation = false
            return "Couldn't reach \(b.name) (\(m)). Open it and try again."
        }
    }

    /// Turns detection on for a question already opened in ChatGPT: the tab still on ChatGPT's
    /// start page is taken as Wren's only if it's the only one.
    func detectConversation(for id: UUID) async -> String? {
        guard let b = BrowserTabs.defaultBrowser else {
            return "Wren can follow ChatGPT tabs in Chrome, Brave, Edge, Chromium and Vivaldi. \(BrowserTabs.defaultBrowserName) isn't one of them, so link the conversation yourself."
        }
        settings.chatgptDetectConversation = true
        switch await BrowserTabs.chatGPTTabs(bundleID: b.bundleID) {
        case .failure(.notPermitted):
            settings.chatgptDetectConversation = false
            return "Wren wasn't allowed to read \(b.name)'s ChatGPT tabs. You can allow it in System Settings › Privacy & Security › Automation › Wren."
        case let .failure(.unavailable(m)): return "Couldn't read \(b.name)'s tabs (\(m))."
        case let .success(tabs):
            // Everything except tabs on ChatGPT's start page counts as "already there".
            let before = tabs.filter { ChatGPTWeb.conversationURL($0.url) != nil || !($0.url.hasPrefix("https://chatgpt.com/") && URLComponents(string: $0.url)?.path.count ?? 0 <= 1) }
            watchConversation(id, bundleID: b.bundleID, before: before)
            return nil
        }
    }

    /// Copies the prompt (only when asked: a clipboard handoff, or a follow-up in a linked conversation)
    /// and opens the page. Returns an error message when it couldn't, and records the failure.
    func openInChatGPT(prompt: String, url: URL, record: DelegationRecord, channel: UserChannel, copy: Bool = true) async -> String? {
        guard let broker else { return "No database." }
        let req = ActionRequest(action: BuiltInAction.chatgptHandoff, target: TargetRef(kind: "prompt", id: record.id.uuidString, label: String(record.task.prefix(80))),
                                parameters: ["prompt": .string(prompt)], origin: .user(channel), createdAt: clock.now,
                                containsPrivateContent: record.includesPrivate)
        let useApp = settings.chatgptDestination == "app" && url == ChatGPTWeb.home
        do {
            try await broker.performExternal(req, confirmation: broker.confirm(req, includingPrivate: record.includesPrivate),
                                             detail: { _ in copy ? "copied \(prompt.count) characters; opened ChatGPT (not sent by Wren)" : "opened ChatGPT with the question (\(prompt.count) characters; not sent by Wren)" }) {
                if copy {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                    guard NSPasteboard.general.string(forType: .string) == prompt else { throw ConnectorError.badResponse("couldn't copy the request") }
                }
                if useApp, let app = ConnectorHub.chatGPTAppURL {
                    NSWorkspace.shared.openApplication(at: app, configuration: .init())
                } else {
                    guard NSWorkspace.shared.open(url) else { throw ConnectorError.badResponse("macOS couldn't open the browser") }
                }
            }
            record.prompt = prompt
            record.status = .handedOff
            record.error = nil
            saveDelegation(record)
            return nil
        } catch {
            record.status = .failed; record.webState = .failedToOpen; record.error = errorText(error); saveDelegation(record)
            return errorText(error)
        }
    }

    /// "I sent it": the user's word, recorded as such. The answer stays in ChatGPT, unseen by Wren.
    func markWebSubmitted(_ id: UUID) {
        guard let r = asks?.record(id), r.destination == .chatgptHandoff, r.webState?.hasConversation != true else { return }
        r.webState = .submittedUnverified
        saveDelegation(r); delegationVersion += 1
    }

    /// Links the real conversation the user copied from ChatGPT. Only a genuine conversation link is accepted.
    @discardableResult
    func linkConversation(_ id: UUID, _ raw: String) -> String? {
        guard let r = asks?.record(id) else { return "That request no longer exists." }
        guard let url = ChatGPTWeb.conversationURL(raw) else {
            return "That isn't a ChatGPT conversation link. In ChatGPT, open the conversation and copy the address, which looks like https://chatgpt.com/c/…"
        }
        r.providerURL = url.absoluteString
        if r.destination == .chatgptHandoff { r.webState = .conversationLinked }
        saveDelegation(r); delegationVersion += 1
        return nil
    }

    /// Reads a link from the clipboard only when the user presses the button.
    @discardableResult
    func linkConversationFromClipboard(_ id: UUID) -> String? {
        guard let s = NSPasteboard.general.string(forType: .string) else { return "The clipboard has no text. Copy the conversation's address in ChatGPT first." }
        return linkConversation(id, s)
    }

    /// Open in ChatGPT: the exact linked conversation, or the ChatGPT website (with the request copied
    /// again) when no conversation is linked.
    func reopenInChatGPT(_ id: UUID) async -> String? {
        guard let r = asks?.record(id) else { return "That request no longer exists." }
        if let url = r.conversationURL { NSWorkspace.shared.open(url); return nil }
        // Not sent yet: open ChatGPT with the question again (same record, no new request).
        let launch = ChatGPTWeb.launch(r.prompt ?? r.task, prefill: settings.chatgptPrefill && settings.chatgptDestination != "app" && r.webState?.awaitsSending != false)
        return await openInChatGPT(prompt: r.prompt ?? r.task, url: launch.url, record: r, channel: .popover, copy: launch.method == .clipboard)
    }

    /// The earlier request a follow-up refers to: the one on screen, or the most recent assistant request.
    var followUpTarget: DelegationRecord? {
        if case let .delegation(id) = route, let r = asks?.record(id) { return r }
        return delegations.first { [.chatgptPlan, .chatgptHandoff, .localModel].contains($0.destination) }
    }
}
