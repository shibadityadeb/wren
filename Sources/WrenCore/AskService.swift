import Foundation
import SwiftData

/// Result of asking ChatGPT. Only `.answered` means a real, complete answer.
public enum AskOutcome: Equatable, Sendable {
    case answered(text: String, source: String, recordID: UUID)
    /// The answer stopped early; the partial text is kept.
    case partial(text: String, source: String, recordID: UUID, message: String)
    case notConnected
    case reconnect(String)
    case needsPermission(String)
    case usageLimit(String)
    case needsReview(String)
    /// ChatGPT refused web search or the reasoning setting; the user may run it with standard settings.
    case unsupported(String)
    case failed(String, retryable: Bool)
}

/// The capture panel's state for "Ask ChatGPT" (or a general question).
public struct AskCard: Equatable, Sendable {
    /// `chatgptWeb`: the ChatGPT website (handoff). `chatgpt`: run with connected ChatGPT in Wren.
    public enum Destination: Equatable, Sendable { case chatgptWeb, chatgpt, local, choose }
    public enum Phase: Equatable, Sendable {
        case ready
        /// Sent; the request runs in the background and Wren announces when it finishes.
        case sending(recordID: UUID?)
        case answered(text: String, source: String, recordID: UUID)
        case partial(text: String, source: String, recordID: UUID, message: String)
        case notConnected
        case connecting
        case reconnect(String)
        case needsPermission(String)
        case usageLimit(String)
        case needsReview(String)
        case unsupported(String)
        /// Handed to the ChatGPT website: what Wren knows about it, never "done".
        case handedOff(WebHandoffState, recordID: UUID)
        case failed(String, retryable: Bool)
        public var isSending: Bool { if case .sending = self { true } else { false } }
    }
    public var request: AIRequest
    public var destination: Destination
    public var phase: Phase = .ready
    /// A local model is set up (for general questions, Return asks it first).
    public var localAvailable = false
    /// ChatGPT is connected with plan usage allowed (then it answers general questions by default).
    public var chatgptReady = false
    public var streamed = ""
    /// The delegation record this card is tracking (set once sent).
    public var recordID: UUID?
    /// Shown above the actions, e.g. "Connected. Press Return to ask."
    public var note: String?
    /// The browser's ChatGPT tab can be followed, and the user hasn't turned that on yet.
    public var canOfferDetection = false

    public init(request: AIRequest, destination: Destination) { self.request = request; self.destination = destination }

    /// What Return does now. nil while sending or after an answer, so Return can't send twice.
    public var primary: AskAction? {
        switch phase {
        case .ready:
            // A question that names no assistant is the local model's; without one the user picks.
            guard destination == .choose else { return .run(destination) }
            return localAvailable ? .run(.local) : nil
        case .handedOff: return nil
        case .sending, .answered, .partial, .connecting: return nil
        case .notConnected: return .connect
        case .reconnect: return .connect
        case .needsPermission: return .allowPlan
        case .usageLimit: return .run(.chatgpt)
        case .needsReview: return .openDelegate
        case .unsupported: return .runStandard
        case let .failed(_, retryable): return retryable ? .run(destination == .choose ? .chatgpt : destination) : nil
        }
    }
}

public enum AskAction: Equatable, Sendable {
    case run(AskCard.Destination), connect, allowPlan, manageUsage, openDelegate, openAnswer, copyAnswer, saveAsNote
    /// Run again without web search or the reasoning setting ChatGPT refused.
    case runStandard
    /// The ChatGPT website: the linked conversation, or the site with the request copied again.
    case openInChatGPT
    /// "I sent it" (the user's word; recorded as unverified).
    case markSent
    /// Link the conversation whose address the user copied in ChatGPT.
    case linkConversation
    /// The user explicitly chooses to run this request in Wren with connected ChatGPT instead.
    case runInWren
    /// Let Wren watch the ChatGPT tab it opened (address only) to see when the question is sent.
    case detectConversation
    public func title(_ card: AskCard) -> String {
        switch self {
        case .run(.chatgpt): if case .ready = card.phase { return "Ask ChatGPT" } else { return "Try again" }
        case .run(.local): return "Ask local AI"
        case .run(.choose): return "Ask"
        case .connect: return "Connect ChatGPT"
        case .allowPlan: return "Allow plan usage"
        case .manageUsage: return "Manage usage"
        case .openDelegate: return "Review in Delegate"
        case .openAnswer: return "Open result"
        case .copyAnswer: return "Copy answer"
        case .saveAsNote: return "Save as a note instead"
        case .runStandard: return "Run with standard settings"
        case .run(.chatgptWeb): return "Ask in ChatGPT"
        case .openInChatGPT: return "Open in ChatGPT"
        case .detectConversation: return "Detect conversation automatically"
        case .markSent: return "I sent it"
        case .linkConversation: return "Link conversation"
        case .runInWren: return "Run with ChatGPT inside Wren"
        }
    }
}

/// What `start` did with a request.
public enum AskStart: Equatable, Sendable {
    /// Persisted as running and sent; the outcome arrives through `onFinished` and `outcome(_:)`.
    case started(UUID)
    /// The same request is already running, or just finished: nothing new was sent.
    case duplicate(UUID)
    /// Not sent (not connected, needs permission, needs review…). Nothing left the Mac.
    case notRun(AskOutcome)
}

/// Delegations to ChatGPT (the user's plan): typed, spoken or from the main window. Every request
/// is persisted as `running` before anything leaves the Mac, runs independently of the panel that
/// started it, is audited through the broker, and ends `completed`, `partial`, `failed` or
/// `cancelled` with the real provider outcome. Wren announces completion once (`onFinished`).
@MainActor
public final class AskService {
    let store: WrenStore
    let broker: ActionBroker
    let chatgpt: ChatGPTConnector
    let clock: WrenClock
    /// Records being sent right now, by normalized prompt; a second identical request joins the first.
    public private(set) var inFlight: [String: UUID] = [:]
    private var tasks: [UUID: Task<AskOutcome, Never>] = [:]
    /// Text as it streams in, per record (for an open panel or detail view).
    public var onDelta: (UUID, String) -> Void = { _, _ in }
    /// Called once when a record reaches a final state (completed, partial, failed, cancelled).
    public var onFinished: (DelegationRecord) -> Void = { _ in }
    /// The same prompt submitted again within this window after finishing counts as a repeat
    /// (a second Return, a repeated voice event), not a new request.
    public var repeatWindow: TimeInterval = 15

    public init(store: WrenStore, broker: ActionBroker, chatgpt: ChatGPTConnector, clock: WrenClock) {
        self.store = store; self.broker = broker; self.chatgpt = chatgpt; self.clock = clock
    }

    public static func key(_ prompt: String) -> String {
        prompt.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    public func record(_ id: UUID) -> DelegationRecord? {
        var d = FetchDescriptor<DelegationRecord>(predicate: #Predicate { $0.id == id }); d.fetchLimit = 1
        return try? store.context.fetch(d).first
    }

    public func history(limit: Int = 100) -> [DelegationRecord] {
        var d = FetchDescriptor<DelegationRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]); d.fetchLimit = limit
        return (try? store.context.fetch(d)) ?? []
    }

    /// Sends one request and waits for its final outcome (used by tests and simple callers).
    public func askChatGPT(_ r: AIRequest, channel: UserChannel, onDelta: @escaping @MainActor (String) -> Void = { _ in }) async -> AskOutcome {
        switch start(r, channel: channel, onDelta: onDelta) {
        case let .notRun(o): return o
        case let .started(id): return await outcome(id)
        case let .duplicate(id):
            if tasks[id] != nil { return .failed("That request is already being sent.", retryable: false) }
            return outcome(of: record(id)) ?? .failed("That request was just sent.", retryable: false)
        }
    }

    /// The final outcome of a running (or finished) record.
    public func outcome(_ id: UUID) async -> AskOutcome {
        if let t = tasks[id] { return await t.value }
        return outcome(of: record(id)) ?? .failed("No such request.", retryable: false)
    }

    /// Starts one request on the user's plan. The user's explicit request (Return, the Ask button
    /// or a spoken command on exactly this text) is the confirmation; nothing else is attached.
    /// Never reports success without a complete answer and never uses any other billing.
    @discardableResult
    /// - Parameter reviewed: a prompt the user built and reviewed in Delegate (context they chose,
    ///   private items they ticked). Without it, only the request text is sent and anything that looks
    ///   like a secret stops the request for review.
    public func start(_ r: AIRequest, channel: UserChannel, reviewed: HandoffDraft? = nil,
                      onDelta perRequest: @escaping @MainActor (String) -> Void = { _ in }) -> AskStart {
        let draft = reviewed ?? HandoffDraft(task: r.prompt, depth: r.depth)
        let k = Self.key(draft.prompt)
        guard !k.isEmpty else { return .notRun(.failed("There's nothing to send.", retryable: false)) }
        if let id = inFlight[k] { return .duplicate(id) }
        if let recent = history(limit: 20).first(where: {
            $0.destination == .chatgptPlan && Self.key($0.prompt ?? "") == k && ($0.status == .completed || $0.status == .running)
                && clock.now.timeIntervalSince($0.createdAt) < repeatWindow
        }) { return .duplicate(recent.id) }
        let target = TargetRef(kind: "prompt", id: UUID().uuidString, label: String(r.prompt.prefix(80)))
        func notRun(_ o: AskOutcome, _ why: String) -> AskStart {
            broker.recordNotRun(Self.request(draft, model: nil, target: target, channel: channel, at: clock.now), reason: why); return .notRun(o)
        }
        guard reviewed != nil || draft.findings.isEmpty else {
            return notRun(.needsReview("This looks like it contains \(draft.findings.map(\.label).joined(separator: ", ")). Review it in Delegate before anything is sent."), "needs review (possible secret)")
        }
        switch chatgpt.account {
        case .notConnected, .connecting: return notRun(.notConnected, "ChatGPT isn't connected")
        case let .reauthorizationRequired(m): return notRun(.reconnect(m), "ChatGPT needs to be reconnected")
        case let .accountOnly(m): return notRun(.needsPermission(m), "plan usage not authorized")
        case .planEnabled, .usageLimitReached, .temporarilyUnavailable: break
        }
        let rec = DelegationRecord(task: r.prompt, destination: .chatgptPlan, depth: r.depth, now: clock.now)
        rec.kind = r.kind
        rec.parentID = r.followUpOf
        rec.webSearchRequested = r.wantsWebSearch
        rec.prompt = draft.prompt
        rec.original = r.original
        rec.channelRaw = channel.rawValue
        rec.includesPrivate = draft.containsPrivate
        rec.status = .running
        store.context.insert(rec)
        try? store.context.save()
        let options = ResponseOptions(reasoningEffort: r.wantsHighEffort || draft.depth == .deep ? "high" : nil, webSearch: r.wantsWebSearch)
        launch(rec, draft: draft, options: options, target: target, channel: channel, perRequest: perRequest)
        return .started(rec.id)
    }

    /// Runs a retryable failure again on the same record (no second record, never after success).
    @discardableResult
    public func retry(_ id: UUID) -> AskStart { rerun(id, standardSettings: false) }

    /// After ChatGPT refused web search or the reasoning setting: runs the same text again without
    /// them, on the same record. Only when the user chooses it; the record then says what ran.
    @discardableResult
    public func retryWithStandardSettings(_ id: UUID) -> AskStart { rerun(id, standardSettings: true) }

    func rerun(_ id: UUID, standardSettings: Bool) -> AskStart {
        guard let rec = record(id), let prompt = rec.prompt else { return .notRun(.failed("No such request.", retryable: false)) }
        guard tasks[id] == nil else { return .duplicate(id) }
        let allowed = standardSettings ? (rec.status == .failed && rec.failure == .unsupportedCapability) : rec.canRetry
        guard allowed else { return .notRun(.failed("This request can't be retried.", retryable: false)) }
        switch chatgpt.account {
        case .notConnected, .connecting: return .notRun(.notConnected)
        case let .reauthorizationRequired(m): return .notRun(.reconnect(m))
        case let .accountOnly(m): return .notRun(.needsPermission(m))
        default: break
        }
        let channel = rec.channel ?? .popover
        let options: ResponseOptions
        if standardSettings {
            options = .standard
            rec.webSearchRequested = false; rec.requestedEffort = nil
        } else {
            options = ResponseOptions(reasoningEffort: rec.requestedEffort ?? (rec.depth == .deep ? "high" : nil), webSearch: rec.webSearchRequested)
        }
        rec.status = .running; rec.error = nil; rec.failure = nil; rec.response = nil; rec.notifiedAt = nil; rec.completedAt = nil
        rec.reportedEffort = nil; rec.webSearchCalls = 0; rec.sources = []; rec.startedAt = nil
        rec.updatedAt = clock.now
        try? store.context.save()
        let target = TargetRef(kind: "prompt", id: UUID().uuidString, label: String(rec.task.prefix(80)))
        // The exact text that was sent before (and reviewed then) is sent again, nothing added.
        launch(rec, draft: .exact(prompt, depth: rec.depth, containsPrivate: rec.includesPrivate), options: options, target: target, channel: channel, perRequest: { _ in })
        return .started(id)
    }

    /// Stops a running request. The record says cancelled; ChatGPT may already have used the request.
    public func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    /// At launch: a request still `running` belonged to a Wren that quit (or crashed) before the
    /// answer arrived. It's reported honestly, never as completed, and offered for retry.
    @discardableResult
    public func recoverInterrupted() -> Int {
        // Before schema v6 a complete ChatGPT-plan answer was stored as "imported"; it was received from
        // the provider, not pasted, so it's shown as completed (and never re-announced).
        let imported = DelegationStatus.responseImported.rawValue, plan = DelegationDestination.chatgptPlan.rawValue
        let legacy = (try? store.context.fetch(FetchDescriptor<DelegationRecord>(predicate: #Predicate { $0.statusRaw == imported && $0.destinationRaw == plan }))) ?? []
        for r in legacy {
            r.status = r.error == nil ? .completed : .partial
            r.completedAt = r.completedAt ?? r.updatedAt
            r.notifiedAt = r.notifiedAt ?? r.updatedAt
            r.seenAt = r.seenAt ?? r.updatedAt
        }
        if !legacy.isEmpty { try? store.context.save() }
        let running = DelegationStatus.running.rawValue
        let stuck = (try? store.context.fetch(FetchDescriptor<DelegationRecord>(predicate: #Predicate { $0.statusRaw == running }))) ?? []
        for r in stuck where tasks[r.id] == nil {
            r.status = .failed; r.failure = .interrupted
            r.error = "Wren was closed before ChatGPT finished, so no answer was received. ChatGPT may still have counted the request. You can retry it."
            r.updatedAt = clock.now
        }
        if !stuck.isEmpty { try? store.context.save() }
        return stuck.count
    }

    static func request(_ draft: HandoffDraft, model: String?, options: ResponseOptions = .standard, target: TargetRef, channel: UserChannel, at: Date) -> ActionRequest {
        var p: [String: JSONValue] = ["prompt": .string(draft.prompt), "allowance": .string("ChatGPT plan")]
        if let model { p["model"] = .string(model) }
        if let e = options.reasoningEffort { p["reasoningEffort"] = .string(e) }
        if options.webSearch { p["webSearch"] = .bool(true) }
        return ActionRequest(action: BuiltInAction.delegateToExternalAI, target: target, parameters: p, origin: .user(channel), createdAt: at,
                             containsPrivateContent: draft.containsPrivate)
    }

    private func launch(_ rec: DelegationRecord, draft: HandoffDraft, options: ResponseOptions, target: TargetRef, channel: UserChannel, perRequest: @escaping @MainActor (String) -> Void) {
        let id = rec.id, k = Self.key(draft.prompt)
        inFlight[k] = id
        rec.attempts += 1
        tasks[id] = Task { [weak self] in
            guard let self else { return .failed("Cancelled.", retryable: true) }
            let o = await self.run(rec, draft: draft, options: options, target: target, channel: channel, perRequest: perRequest)
            self.inFlight[k] = nil
            self.tasks[id] = nil
            if rec.status.isFinal { self.onFinished(rec) }
            return o
        }
    }

    private func run(_ rec: DelegationRecord, draft: HandoffDraft, options wanted: ResponseOptions, target: TargetRef, channel: UserChannel,
                     perRequest: @escaping @MainActor (String) -> Void) async -> AskOutcome {
        let c = chatgpt
        func save() { rec.updatedAt = clock.now; try? store.context.save() }
        func fail(_ kind: DelegationFailure, _ message: String, _ o: AskOutcome) -> AskOutcome {
            rec.status = .failed; rec.failure = kind; rec.error = message; rec.completedAt = clock.now; save(); return o
        }
        if c.models.isEmpty || c.selectedModel == nil { await c.refresh() }
        guard let model = c.selectedModel else {
            broker.recordNotRun(Self.request(draft, model: nil, target: target, channel: channel, at: clock.now), reason: "no model available")
            if case let .temporarilyUnavailable(m) = c.account { return fail(.unavailable, m, .failed(m, retryable: true)) }
            if case .usageLimitReached = c.account { return fail(.usageLimit, c.account.reason ?? "", .usageLimit(c.account.reason ?? "")) }
            let m = "ChatGPT didn't list any models for your account. Try again, or check Connectors › ChatGPT."
            return fail(.unavailable, m, .failed(m, retryable: true))
        }
        // A model that lists its reasoning levels gets the strongest it allows; one that lists none
        // takes no reasoning setting. When the list says nothing, the response reports what ran.
        var options = wanted
        if wanted.reasoningEffort != nil { options.reasoningEffort = c.models.first { $0.slug == model }?.effort(forDeepThinking: wanted.reasoningEffort!) ?? wanted.reasoningEffort }
        rec.requestedModel = model
        rec.requestedEffort = options.reasoningEffort
        rec.webSearchRequested = options.webSearch
        rec.startedAt = clock.now
        save()
        let request = Self.request(draft, model: model, options: options, target: target, channel: channel, at: clock.now)
        let id = rec.id
        let delta: @Sendable (String) -> Void = { [weak self] d in
            Task { @MainActor in perRequest(d); self?.onDelta(id, d) }
        }
        do {
            let reply = try await broker.performExternal(request, confirmation: broker.confirm(request, includingPrivate: draft.containsPrivate),
                                                         detail: { "ChatGPT plan · requested \($0.requestedModel) · reported \($0.reportedModel ?? "not reported")" }) {
                try await c.respond(model: model, input: draft.prompt, options: options, origin: .user(channel), onDelta: delta)
            }
            try Task.checkCancellation()
            let source = "ChatGPT plan\(c.email.map { " (\($0))" } ?? "") · \(reply.reportedModel ?? model)"
            rec.response = reply.text; rec.responseSource = source; rec.reportedModel = reply.reportedModel
            rec.reportedEffort = reply.reportedEffort; rec.webSearchCalls = reply.webSearchCalls; rec.sources = reply.sources
            rec.status = .completed; rec.completedAt = clock.now; rec.failure = nil; rec.error = nil
            save()
            return .answered(text: reply.text, source: source, recordID: rec.id)
        } catch is CancellationError {
            rec.status = .cancelled; rec.error = "Cancelled by you. ChatGPT may already have received the request."; rec.completedAt = clock.now; save()
            return .failed("Cancelled.", retryable: true)
        } catch let e as ChatGPTError {
            if Task.isCancelled {
                rec.status = .cancelled; rec.error = "Cancelled by you. ChatGPT may already have received the request."; rec.completedAt = clock.now; save()
                return .failed("Cancelled.", retryable: true)
            }
            let m = e.errorDescription ?? "ChatGPT didn't answer."
            switch e {
            case let .incomplete(partial), let .interrupted(partial) where !partial.isEmpty:
                rec.response = partial; rec.responseSource = "ChatGPT plan · incomplete (\(model))"; rec.status = .partial
                rec.error = m; rec.failure = .unavailable; rec.completedAt = clock.now; save()
                return .partial(text: partial, source: "ChatGPT plan · \(model)", recordID: rec.id, message: m)
            case .usageLimitReached: return fail(.usageLimit, m, .usageLimit(m))
            case .unsupportedCapability: return fail(.unsupportedCapability, m, .unsupported(m))
            case .planNotAuthorized, .notEligible: return fail(.planNotAuthorized, m, .needsPermission(m))
            case .reauthorizationRequired, .identityNotVerified, .accountMismatch, .clientRejected: return fail(.reauthorizationRequired, m, .reconnect(m))
            case .temporarilyUnavailable, .incomplete, .interrupted: return fail(.unavailable, m, .failed(m, retryable: true))
            default: return fail(.rejected, m, .failed(m, retryable: false))
            }
        } catch {
            let m = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return fail(.other, m, .failed(m, retryable: false))
        }
    }

    /// The outcome a finished record represents.
    public func outcome(of r: DelegationRecord?) -> AskOutcome? {
        guard let r else { return nil }
        switch r.status {
        case .completed, .responseImported: return .answered(text: r.response ?? "", source: r.responseSource ?? "", recordID: r.id)
        case .partial: return .partial(text: r.response ?? "", source: r.responseSource ?? "", recordID: r.id, message: r.error ?? "")
        case .failed, .cancelled:
            switch r.failure {
            case .usageLimit?: return .usageLimit(r.error ?? "")
            case .unsupportedCapability?: return .unsupported(r.error ?? "")
            case .planNotAuthorized?: return .needsPermission(r.error ?? "")
            case .reauthorizationRequired?: return .reconnect(r.error ?? "")
            default: return .failed(r.error ?? "Failed.", retryable: r.canRetry)
            }
        default: return nil
        }
    }
}

/// Words for a finished delegation's notification: the kind and the user's own request, shortened.
public enum DelegationText {
    public static func notificationLine(_ r: DelegationRecord) -> String {
        "\(r.kind.label): \(topic(r.task))"
    }

    /// "Research the fundamentals of quantum physics." → "the fundamentals of quantum physics".
    public static func topic(_ task: String) -> String {
        var t = task.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
        t = t.replacingOccurrences(of: #"^(?:please\s+)?(?:research|investigate|look into|think (?:deeply|carefully|hard) about|explain|summari[sz]e|analy[sz]e)\s+(?:about\s+)?"#,
                                   with: "", options: [.regularExpression, .caseInsensitive])
        if t.count > 90 { t = String(t.prefix(89)) + "…" }
        return t.isEmpty ? task : t
    }
}
