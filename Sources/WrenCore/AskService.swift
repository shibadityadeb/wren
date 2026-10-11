import Foundation

/// Result of asking ChatGPT from the capture panel. Only `.answered` means a real, complete answer.
public enum AskOutcome: Equatable, Sendable {
    case answered(text: String, source: String, recordID: UUID)
    /// The answer stopped early; the partial text is kept.
    case partial(text: String, source: String, recordID: UUID, message: String)
    case notConnected
    case reconnect(String)
    case needsPermission(String)
    case usageLimit(String)
    case needsReview(String)
    case failed(String, retryable: Bool)
}

/// The capture panel's state for "Ask ChatGPT" (or a general question).
public struct AskCard: Equatable, Sendable {
    public enum Destination: Equatable, Sendable { case chatgpt, local, choose }
    public enum Phase: Equatable, Sendable {
        case ready
        case sending
        case answered(text: String, source: String, recordID: UUID)
        case partial(text: String, source: String, recordID: UUID, message: String)
        case notConnected
        case connecting
        case reconnect(String)
        case needsPermission(String)
        case usageLimit(String)
        case needsReview(String)
        case failed(String, retryable: Bool)
    }
    public var request: AIRequest
    public var destination: Destination
    public var phase: Phase = .ready
    /// A local model is set up (for general questions, Return asks it first).
    public var localAvailable = false
    public var streamed = ""
    /// Shown above the actions, e.g. "Connected. Press Return to ask."
    public var note: String?

    public init(request: AIRequest, destination: Destination) { self.request = request; self.destination = destination }

    /// What Return does now. nil while sending or after an answer, so Return can't send twice.
    public var primary: AskAction? {
        switch phase {
        case .ready: return destination == .choose ? .run(localAvailable ? .local : .chatgpt) : .run(destination)
        case .sending, .answered, .partial, .connecting: return nil
        case .notConnected: return .connect
        case .reconnect: return .connect
        case .needsPermission: return .allowPlan
        case .usageLimit: return .run(.chatgpt)
        case .needsReview: return .openDelegate
        case let .failed(_, retryable): return retryable ? .run(destination == .choose ? .chatgpt : destination) : nil
        }
    }
}

public enum AskAction: Equatable, Sendable {
    case run(AskCard.Destination), connect, allowPlan, manageUsage, openDelegate, openAnswer, copyAnswer, saveAsNote
    public func title(_ card: AskCard) -> String {
        switch self {
        case .run(.chatgpt): if case .ready = card.phase { return "Ask ChatGPT" } else { return "Try again" }
        case .run(.local): return "Ask local AI"
        case .run(.choose): return "Ask"
        case .connect: return "Connect ChatGPT"
        case .allowPlan: return "Allow plan usage"
        case .manageUsage: return "Manage usage"
        case .openDelegate: return "Review in Delegate"
        case .openAnswer: return "Open in Wren"
        case .copyAnswer: return "Copy answer"
        case .saveAsNote: return "Save as a note instead"
        }
    }
}


/// Runs "ask ChatGPT" requests from the capture panel (typed or spoken) through the real connector,
/// the permission system and the activity log. One request per text at a time.
@MainActor
public final class AskService {
    let store: WrenStore
    let broker: ActionBroker
    let chatgpt: ChatGPTConnector
    let clock: WrenClock
    /// Prompts being sent right now; a second identical request while one runs is refused.
    public private(set) var inFlight: Set<String> = []

    public init(store: WrenStore, broker: ActionBroker, chatgpt: ChatGPTConnector, clock: WrenClock) {
        self.store = store; self.broker = broker; self.chatgpt = chatgpt; self.clock = clock
    }

    /// Sends one request to ChatGPT with the user's plan. The user's explicit request (Return or the
    /// Ask button on exactly this text) is the confirmation; nothing else is attached. Never reports
    /// success without a complete answer, never uses any other billing, and records requests that
    /// weren't sent as not sent.
    public func askChatGPT(_ r: AIRequest, channel: UserChannel, onDelta: @escaping @MainActor (String) -> Void = { _ in }) async -> AskOutcome {
        let c = chatgpt
        let draft = HandoffDraft(task: r.prompt, depth: r.depth)
        let target = TargetRef(kind: "prompt", id: UUID().uuidString, label: String(r.prompt.prefix(80)))
        func makeRequest(_ model: String?) -> ActionRequest {
            var p: [String: JSONValue] = ["prompt": .string(draft.prompt), "allowance": .string("ChatGPT plan")]
            if let model { p["model"] = .string(model) }
            return ActionRequest(action: BuiltInAction.delegateToExternalAI, target: target, parameters: p, origin: .user(channel), createdAt: clock.now)
        }
        func notRun(_ o: AskOutcome, _ why: String) -> AskOutcome { broker.recordNotRun(makeRequest(nil), reason: why); return o }
        guard !inFlight.contains(draft.prompt) else { return .failed("That request is already being sent.", retryable: false) }
        guard draft.findings.isEmpty else {
            return notRun(.needsReview("This looks like it contains \(draft.findings.map(\.label).joined(separator: ", ")). Review it in Delegate before anything is sent."), "needs review (possible secret)")
        }
        switch c.account {
        case .notConnected, .connecting: return notRun(.notConnected, "ChatGPT isn't connected")
        case let .reauthorizationRequired(m): return notRun(.reconnect(m), "ChatGPT needs to be reconnected")
        case let .accountOnly(m): return notRun(.needsPermission(m), "plan usage not authorized")
        case .planEnabled, .usageLimitReached, .temporarilyUnavailable: break
        }
        inFlight.insert(draft.prompt)
        defer { inFlight.remove(draft.prompt) }
        if c.models.isEmpty || c.selectedModel == nil { await c.refresh() }
        guard let model = c.selectedModel else {
            if case let .temporarilyUnavailable(m) = c.account { return notRun(.failed(m, retryable: true), "ChatGPT unavailable") }
            if case .usageLimitReached = c.account { return notRun(.usageLimit(c.account.reason ?? ""), "usage limit") }
            return notRun(.failed("ChatGPT didn't list any models for your account. Try again, or check Connectors › ChatGPT.", retryable: true), "no model available")
        }
        let request = makeRequest(model)
        let record = DelegationRecord(task: r.prompt, destination: .chatgptPlan, depth: r.depth, now: clock.now)
        record.prompt = draft.prompt
        store.context.insert(record); try? store.context.save()
        func save() { record.updatedAt = clock.now; try? store.context.save() }
        do {
            let reply = try await broker.performExternal(request, confirmation: broker.confirm(request),
                                                         detail: { "ChatGPT plan · requested \($0.requestedModel) · reported \($0.reportedModel ?? "not reported")" }) {
                try await c.respond(model: model, input: draft.prompt, origin: .user(channel)) { d in Task { @MainActor in onDelta(d) } }
            }
            let source = "ChatGPT plan\(c.email.map { " (\($0))" } ?? "") · \(reply.reportedModel ?? model)"
            record.response = reply.text; record.responseSource = source; record.status = .responseImported
            save()
            return .answered(text: reply.text, source: source, recordID: record.id)
        } catch let e as ChatGPTError {
            switch e {
            case let .incomplete(partial), let .interrupted(partial) where !partial.isEmpty:
                record.response = partial; record.responseSource = "ChatGPT plan · incomplete (\(model))"; record.status = .responseImported
                record.error = e.errorDescription; save()
                return .partial(text: partial, source: "ChatGPT plan · \(model)", recordID: record.id, message: e.errorDescription ?? "")
            default:
                record.status = .failed; record.error = e.errorDescription; save()
                switch e {
                case .usageLimitReached: return .usageLimit(e.errorDescription ?? "")
                case .planNotAuthorized, .notEligible: return .needsPermission(e.errorDescription ?? "")
                case .reauthorizationRequired, .identityNotVerified, .accountMismatch, .clientRejected: return .reconnect(e.errorDescription ?? "")
                case .temporarilyUnavailable, .incomplete, .interrupted: return .failed(e.errorDescription ?? "ChatGPT didn't answer.", retryable: true)
                default: return .failed(e.errorDescription ?? "ChatGPT didn't answer.", retryable: false)
                }
            }
        } catch {
            let m = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            record.status = .failed; record.error = m; save()
            return .failed(m, retryable: !(error is ActionBroker.ExternalOutcome))
        }
    }
}
