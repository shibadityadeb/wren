import Foundation
import SwiftData

/// What a trusted handler reports back. `detail` is a short, non-sensitive summary.
public struct HandlerOutcome: Sendable {
    public var detail: String?
    public init(detail: String? = nil) { self.detail = detail }
}

/// Implemented by each integration. The broker is the only caller.
@MainActor
public protocol ActionHandler: AnyObject {
    var descriptor: ActionDescriptor { get }
    func execute(_ request: ActionRequest) async throws -> HandlerOutcome
    /// Checks the real state after execution. Return `.notVerifiable` only when no check exists.
    func verify(_ request: ActionRequest) async -> Verification
}

public struct ActionResult: Sendable, Equatable {
    public var requestID: UUID
    public var status: ExecutionStatus
    public var authorization: AuthorizationSource?
    public var verification: Verification
    /// Prompt for confirmation, denial reason, failure reason, or outcome detail.
    public var message: String?

    public var succeeded: Bool { status == .succeeded }
}

/// The single path from "something wants X done" to "X was done". Every request is
/// authorized, executed by a registered handler, verified, and audited, in that order.
@MainActor
public final class ActionBroker {
    private var handlers: [ActionID: ActionHandler] = [:]
    private var reservedDescriptors: [ActionID: ActionDescriptor] = [:]
    private var usedConfirmations: Set<UUID> = []
    public let policyStore: PolicyStoring
    let context: ModelContext
    let clock: WrenClock
    /// When true, every request stops after authorization and is recorded as a dry run.
    public var globalDryRun = false
    public static let auditLimit = 2000

    public init(context: ModelContext, policyStore: PolicyStoring, clock: WrenClock) {
        self.context = context; self.policyStore = policyStore; self.clock = clock
        for d in BuiltInAction.reservedExternal { reservedDescriptors[d.id] = d }
    }

    public func register(_ h: ActionHandler) { handlers[h.descriptor.id] = h }

    public func descriptor(_ id: ActionID) -> ActionDescriptor? { handlers[id]?.descriptor ?? reservedDescriptors[id] }
    public var allDescriptors: [ActionDescriptor] {
        (Array(handlers.values.map(\.descriptor)) + reservedDescriptors.values).sorted { $0.id.rawValue < $1.id.rawValue }
    }

    /// Decide without executing or auditing (for showing what would happen).
    public func preview(_ r: ActionRequest, confirmation: Confirmation? = nil) -> AuthorizationDecision {
        let policy = (try? policyStore.load()) ?? PolicySnapshot(grants: [], rules: [])
        return Authorizer.decide(r, descriptor: descriptor(r.action), policy: policy, confirmation: confirmation,
                                 usedConfirmations: usedConfirmations, now: clock.now)
    }

    /// Called only from a Wren confirmation UI after the user approves the exact request shown.
    public func confirm(_ r: ActionRequest) -> Confirmation { Confirmation(for: r, at: clock.now) }

    /// The user said no. The action stays denied for this target until they lift it.
    public func decline(_ r: ActionRequest, reason: String = "Declined") {
        try? policyStore.recordDenial(r, reason: reason)
        let rec = AuditRecord(request: r, descriptor: descriptor(r.action), at: clock.now)
        rec.status = .denied; rec.detail = "Declined by you"
        context.insert(rec); try? context.save()
    }

    /// The user cancelled a proposal they asked for. Audited, but no lasting denial, so
    /// they can ask again differently ("no, Monday").
    public func cancel(_ r: ActionRequest) {
        let rec = AuditRecord(request: r, descriptor: descriptor(r.action), at: clock.now)
        rec.status = .denied; rec.detail = "Cancelled by you"
        context.insert(rec); try? context.save()
    }

    /// Records something Wren did outside a request (for example applying a restore at startup),
    /// so the activity log stays complete. Labels only.
    public func recordEvent(action: ActionID, target: TargetRef, origin: ActionOrigin, detail: String) {
        let r = ActionRequest(action: action, target: target, origin: origin, createdAt: clock.now)
        let rec = AuditRecord(request: r, descriptor: descriptor(action), at: clock.now)
        rec.status = .succeeded; rec.verification = .verified; rec.detail = String(detail.prefix(200))
        context.insert(rec); try? context.save()
    }

    @discardableResult
    public func submit(_ r: ActionRequest, confirmation: Confirmation? = nil, dryRun: Bool = false) async -> ActionResult {
        let d = descriptor(r.action)
        let rec = AuditRecord(request: r, descriptor: d, at: clock.now)
        context.insert(rec)
        defer { trimAudit(); try? context.save() }

        let policy: PolicySnapshot
        do { policy = try policyStore.load() } catch {
            return finish(rec, r, .denied, nil, .notRun, "Couldn't read permissions: \(error.localizedDescription)")
        }
        let decision = Authorizer.decide(r, descriptor: d, policy: policy, confirmation: confirmation,
                                         usedConfirmations: usedConfirmations, now: clock.now)
        switch decision {
        case let .deny(reason):
            return finish(rec, r, .denied, nil, .notRun, reason)
        case let .needsConfirmation(prompt):
            return finish(rec, r, .awaitingConfirmation, nil, .notRun, prompt)
        case let .allow(source):
            rec.authorization = source.label
            if case let .userConfirmation(id) = source {
                usedConfirmations.insert(id)
                rec.confirmationObtained = true
            }
            if dryRun || globalDryRun {
                rec.dryRun = true
                return finish(rec, r, .dryRun, source, .notRun, "Would run: \(d?.summary ?? r.action.rawValue)")
            }
            guard let h = handlers[r.action] else {
                return finish(rec, r, .failed, source, .notRun, "No handler is installed for this action yet.")
            }
            rec.status = .executing
            try? context.save()
            let outcome: HandlerOutcome
            do { outcome = try await h.execute(r) } catch {
                return finish(rec, r, .failed, source, .notRun, (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
            let v = await h.verify(r)
            switch v {
            case .verified: return finish(rec, r, .succeeded, source, v, outcome.detail)
            case .notVerifiable: return finish(rec, r, .unverified, source, v, outcome.detail ?? "Executed; result could not be checked.")
            case .mismatch, .notRun: return finish(rec, r, .failed, source, v, "The change didn't take effect.")
            }
        }
    }

    private func finish(_ rec: AuditRecord, _ r: ActionRequest, _ s: ExecutionStatus, _ a: AuthorizationSource?,
                        _ v: Verification, _ msg: String?) -> ActionResult {
        rec.status = s
        rec.verification = v
        rec.detail = msg.map { String($0.prefix(200)) }
        return ActionResult(requestID: r.id, status: s, authorization: a, verification: v, message: msg)
    }

    public func recentAudit(limit: Int = 100) -> [AuditRecord] {
        var d = FetchDescriptor<AuditRecord>(sortBy: [SortDescriptor(\.at, order: .reverse)])
        d.fetchLimit = limit
        return (try? context.fetch(d)) ?? []
    }

    private func trimAudit() {
        guard let count = try? context.fetchCount(FetchDescriptor<AuditRecord>()), count > Self.auditLimit else { return }
        var d = FetchDescriptor<AuditRecord>(sortBy: [SortDescriptor(\.at)])
        d.fetchLimit = count - Self.auditLimit
        (try? context.fetch(d))?.forEach(context.delete)
    }
}
