import Foundation
import WrenCore

/// `wren-tools live-check chatgpt "<prompt>"`: runs one real delegation through the same AskService,
/// broker and ChatGPT connector the app uses, against the signed-in account in Wren's data folder.
/// Prints status, models and the answer length only (never tokens). Rotated tokens are saved to the
/// same private file, so the app stays signed in. Uses the user's ChatGPT plan allowance.
@MainActor
enum LiveCheck {
    static func chatgpt(prompt: String, dataFolder: URL) async -> Int32 {
        let creds = FileCredentialStore(directory: dataFolder.appendingPathComponent("Credentials", isDirectory: true))
        let c = ChatGPTConnector(store: creds, statusStore: MemoryStatusStore(), handoffEnabled: false, selectedModel: nil, destination: { nil })
        guard c.connection != nil else { print("chatgpt: not signed in (no connection in \(dataFolder.path))"); return 3 }
        await c.refresh()
        print("chatgpt account state: \(c.account.title); models listed: \(c.models.count); selected: \(c.selectedModel ?? "-")")
        for m in c.models { print("model \(m.slug): reasoning levels \(m.reasoningEfforts.map { $0.isEmpty ? "none listed" : $0.joined(separator: ",") } ?? "not in the model list")") }
        guard let store = try? WrenStore(url: nil), let policy = try? SwiftDataPolicyStore(context: store.context, clock: SystemClock()) else { return 4 }
        try? policy.setGrant(.externalAI, granted: c.account.canSend)
        let broker = ActionBroker(context: store.context, policyStore: policy, clock: SystemClock())
        let asks = AskService(store: store, broker: broker, chatgpt: c, clock: SystemClock())
        var announced = 0
        asks.onFinished = { _ in announced += 1 }
        guard case let .delegateToChatGPT(req) = ExecutionRouter.operation(for: prompt, now: Date()) else { print("routing: not a GPT delegation"); return 5 }
        print("routed as DelegateToChatGPT (\(req.kind.rawValue)); high effort=\(req.wantsHighEffort) web search=\(req.wantsWebSearch); prompt chars: \(req.prompt.count)")
        let started = Date()
        switch asks.start(req, channel: .hotkey) {
        case let .notRun(o): print("not sent: \(o)"); return 6
        case let .duplicate(id): print("duplicate of \(id)"); return 7
        case let .started(id):
            print("persisted as: \(asks.record(id)?.status.rawValue ?? "?") before the provider answered")
            let dup = asks.start(req, channel: .voice)
            print("second identical submit while running: \(dup == .duplicate(id) ? "deduplicated" : "\(dup)")")
            let o = await asks.outcome(id)
            let r = asks.record(id)
            print(String(format: "outcome after %.1fs: %@", Date().timeIntervalSince(started), String(describing: o).prefix(14) as CVarArg))
            print("record: status=\(r?.status.rawValue ?? "-") requested=\(r?.requestedModel ?? "-") reported=\(r?.reportedModel ?? "-") answerChars=\(r?.response?.count ?? 0) completedAt=\(r?.completedAt != nil) providerURL=\(r?.providerURL ?? "none") announced=\(announced)")
            let audit = broker.recentAudit(limit: 5).first { $0.action == BuiltInAction.delegateToExternalAI.rawValue }
            print("evidence: effort requested=\(r?.requestedEffort ?? "default") reported=\(r?.reportedEffort ?? "not reported") webSearch requested=\(r?.webSearchRequested ?? false) calls=\(r?.webSearchCalls ?? 0) sources=\(r?.sources.count ?? 0) display=\(r?.displayStatus ?? "-")")
            if let e = r?.error { print("error: \(e)") }
            print("audit: \(audit?.status.rawValue ?? "-") · \(audit?.detail ?? "-")")
            return r?.status == .completed ? 0 : 1
        }
    }
}

extension LiveCheck {
    /// `wren-tools live-check gmail`: read-only. Signs in with the Google token in Wren's data folder,
    /// runs one full sync and then one incremental sync into a throwaway mailbox, and prints counts
    /// only (no addresses, subjects or bodies). Changes nothing in Gmail and sends no notifications.
    /// The OAuth client comes from WREN_GOOGLE_CLIENT_ID / WREN_GOOGLE_CLIENT_SECRET.
    static func gmail(dataFolder: URL) async -> Int32 {
        let env = ProcessInfo.processInfo.environment
        guard let id = env["WREN_GOOGLE_CLIENT_ID"], !id.isEmpty else { print("gmail: set WREN_GOOGLE_CLIENT_ID (and the secret) from config/providers.env"); return 3 }
        let creds = FileCredentialStore(directory: dataFolder.appendingPathComponent("Credentials", isDirectory: true))
        let account = GoogleAccount(config: GoogleOAuthConfig(clientID: id, clientSecret: env["WREN_GOOGLE_CLIENT_SECRET"]), store: creds)
        guard account.isSignedIn else { print("gmail: no Google sign-in in \(dataFolder.path)"); return 3 }
        print("granted: read=\(account.canReadMail) markRead=\(account.canMarkRead)")
        let cal = Calendar.current
        var state = MailboxState()
        do {
            let first = try await MailSync.sync(&state, api: account.gmail, settings: MailTriageSettings(), now: Date(), calendar: cal)
            let items = Array(state.items.values)
            let excluded = items.filter { $0.message.labels.contains("SPAM") || $0.message.labels.contains("TRASH") }.count
            var byCategory: [String: Int] = [:]
            for i in items { byCategory[i.classification.category.rawValue, default: 0] += 1 }
            print("sync 1: mode=\(first.mode.rawValue) messages=\(items.count) spamOrTrash=\(excluded) unread=\(items.filter(\.message.unread).count) historyCursor=\(state.historyID != nil)")
            print("categories: " + byCategory.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            let second = try await MailSync.sync(&state, api: account.gmail, settings: MailTriageSettings(), now: Date(), calendar: cal)
            print("sync 2: mode=\(second.mode.rawValue) new=\(second.newMessageIDs.count) (an incremental sync with nothing new should report 0)")
            let d = MailAlertPolicy.decide(&state, candidates: Array(state.items.keys), level: .important, quiet: QuietHours(enabled: false), now: Date(), calendar: cal)
            let again = MailAlertPolicy.decide(&state, candidates: Array(state.items.keys), level: .important, quiet: QuietHours(enabled: false), now: Date(), calendar: cal)
            print("alert policy (dry run, nothing delivered): would alert \(d.individual.count) + \(d.summarized.count) summarized; repeated check would alert \(again.individual.count + again.summarized.count)")
            return 0
        } catch {
            print("gmail failed: \((error as? LocalizedError)?.errorDescription ?? "\(type(of: error))")")
            return 1
        }
    }
}
