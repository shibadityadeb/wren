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
        guard let store = try? WrenStore(url: nil), let policy = try? SwiftDataPolicyStore(context: store.context, clock: SystemClock()) else { return 4 }
        try? policy.setGrant(.externalAI, granted: c.account.canSend)
        let broker = ActionBroker(context: store.context, policyStore: policy, clock: SystemClock())
        let asks = AskService(store: store, broker: broker, chatgpt: c, clock: SystemClock())
        var announced = 0
        asks.onFinished = { _ in announced += 1 }
        guard case let .askAI(req) = IntentRouter.route(prompt, now: Date()) else { print("routing: not a GPT delegation"); return 5 }
        print("routed as GPT delegation; prompt chars: \(req.prompt.count)")
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
            print("audit: \(audit?.status.rawValue ?? "-") · \(audit?.detail ?? "-")")
            return r?.status == .completed ? 0 : 1
        }
    }
}
