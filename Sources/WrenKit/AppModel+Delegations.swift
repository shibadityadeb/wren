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

    /// Opens ChatGPT in the browser with this request: persisted as prepared first, through the broker
    /// (permission, audit), and marked opened only after the copy and the open succeeded. Wren doesn't
    /// send anything to ChatGPT here and never records the request as submitted or completed.
    /// A follow-up to a request whose conversation is linked opens *that* conversation.
    func startWebHandoff(_ r: AIRequest, channel: UserChannel) async -> (DelegationRecord?, String?) {
        guard let store else { return (nil, "Wren's database isn't available.") }
        guard hub.chatgpt.handoffAvailable else {
            return (nil, "Opening ChatGPT in your browser is turned off. Turn it on in Connectors › ChatGPT, or run it in Wren with connected ChatGPT.")
        }
        // The same request opened a moment ago (a repeated Return or voice event): not again.
        let key = AskService.key(r.prompt)
        if let recent = delegations.prefix(20).first(where: {
            $0.destination == .chatgptHandoff && AskService.key($0.prompt ?? "") == key && clock.now.timeIntervalSince($0.createdAt) < 15
        }) { return (recent, nil) }
        let parent = r.followUpOf.flatMap { id in asks?.record(id) }
        let rec = DelegationRecord(task: r.prompt, destination: .chatgptHandoff, depth: r.depth, now: clock.now)
        rec.prompt = r.prompt; rec.original = r.original; rec.channelRaw = channel.rawValue; rec.kind = r.kind
        rec.parentID = parent?.id; rec.webState = .prepared
        store.context.insert(rec); try? store.context.save()
        let linked = parent?.conversationURL
        let launch = linked.map { ($0, WebLaunchMethod.clipboard) } ?? ChatGPTWeb.launch(r.prompt, prefill: settings.chatgptPrefill && settings.chatgptDestination != "app")
        if let e = await openInChatGPT(prompt: r.prompt, url: launch.0, record: rec, channel: channel) { return (rec, e) }
        rec.webMethod = launch.1
        rec.webState = launch.1 == .prefillLink ? .openedInChatGPT : .awaitingSubmission
        if let linked { rec.providerURL = linked.absoluteString }
        saveDelegation(rec)
        delegationVersion += 1
        return (rec, nil)
    }

    /// Copies the prompt (always, so it's there even if a link doesn't fill it in) and opens the page.
    /// Returns an error message when it couldn't, and records the failure.
    func openInChatGPT(prompt: String, url: URL, record: DelegationRecord, channel: UserChannel) async -> String? {
        guard let broker else { return "No database." }
        let req = ActionRequest(action: BuiltInAction.chatgptHandoff, target: TargetRef(kind: "prompt", id: record.id.uuidString, label: String(record.task.prefix(80))),
                                parameters: ["prompt": .string(prompt)], origin: .user(channel), createdAt: clock.now,
                                containsPrivateContent: record.includesPrivate)
        let useApp = settings.chatgptDestination == "app" && url == ChatGPTWeb.home
        do {
            try await broker.performExternal(req, confirmation: broker.confirm(req, includingPrivate: record.includesPrivate),
                                             detail: { _ in "copied \(prompt.count) characters; opened ChatGPT (not sent by Wren)" }) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prompt, forType: .string)
                guard NSPasteboard.general.string(forType: .string) == prompt else { throw ConnectorError.badResponse("couldn't copy the request") }
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
        guard let r = asks?.record(id), r.destination == .chatgptHandoff, r.webState != .conversationLinked else { return }
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
        return await openInChatGPT(prompt: r.prompt ?? r.task, url: ChatGPTWeb.home, record: r, channel: .popover)
    }

    /// The earlier request a follow-up refers to: the one on screen, or the most recent assistant request.
    var followUpTarget: DelegationRecord? {
        if case let .delegation(id) = route, let r = asks?.record(id) { return r }
        return delegations.first { [.chatgptPlan, .chatgptHandoff, .localModel].contains($0.destination) }
    }
}
