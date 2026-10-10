import Foundation

public extension BuiltInAction {
    static let reschedule: ActionID = "item.reschedule"
    static let archive: ActionID = "item.archive"
    static let split: ActionID = "item.split"
    static let convertToGoal: ActionID = "item.convertToGoal"
    static let updateWaiting: ActionID = "waiting.update"
    static let acknowledgeFollowUp: ActionID = "waiting.acknowledgeFollowUp"
    static let createGoal: ActionID = "goal.create"
    static let editGoal: ActionID = "goal.edit"
    static let setGoalStatus: ActionID = "goal.setStatus"
    static let setGoalProgress: ActionID = "goal.setProgress"
    static let setGoalMethod: ActionID = "goal.setMethod"
    static let linkToGoal: ActionID = "goal.linkTask"
    static let unlinkFromGoal: ActionID = "goal.unlinkTask"
    static let addMilestone: ActionID = "goal.addMilestone"
    static let dismissInsight: ActionID = "insight.dismiss"
    static let resolveInsight: ActionID = "insight.resolve"

    /// Registers Milestone 3 handlers. All local and reversible; none is covered by an
    /// automation rule, so only the user (directly or by confirming a proposal) can run them.
    @MainActor
    static func registerContextual(on broker: ActionBroker, store: WrenStore, clock: WrenClock) {
        func item(_ r: ActionRequest) throws -> Commitment {
            guard r.target.kind == "commitment", let id = UUID(uuidString: r.target.id), let c = try store.item(id: id) else { throw BrokerError.targetMissing }
            return c
        }
        func goal(_ r: ActionRequest) throws -> Goal {
            guard r.target.kind == "goal", let id = UUID(uuidString: r.target.id), let g = try store.goal(id: id) else { throw BrokerError.targetMissing }
            return g
        }
        func goalParam(_ p: [String: JSONValue]) throws -> Goal {
            guard let s = p.string("goalID"), let id = UUID(uuidString: s), let g = try store.goal(id: id) else { throw BrokerError.badParameter("goalID") }
            return g
        }
        func itemNow(_ r: ActionRequest) -> Commitment? { UUID(uuidString: r.target.id).flatMap { try? store.item(id: $0) } }
        func goalNow(_ r: ActionRequest) -> Goal? { UUID(uuidString: r.target.id).flatMap { try? store.goal(id: $0) } }
        func d(_ id: ActionID, _ summary: String, _ verification: String, _ perm: Permission = .manageItems) -> ActionDescriptor {
            ActionDescriptor(id: id, category: .localReversible, permission: perm, confirmation: .none, summary: summary, verification: verification)
        }
        let n = { clock.now }

        let handlers: [ClosureHandler] = [
            ClosureHandler(d(reschedule, "Change the deadline", "Deadline equals the requested date"),
                execute: { r in
                    let c = try item(r)
                    try store.reschedule(c, deadline: r.parameters.date("deadline"), hasTime: r.parameters.bool("hasTime") ?? false, now: n())
                    return r.parameters.date("deadline").map { "to \(WrenStore.stamp($0))" }
                }, verify: { r in itemNow(r)?.deadline == r.parameters.date("deadline") }),
            ClosureHandler(d(archive, "Archive (can be reopened)", "Item status is archived"),
                execute: { r in try store.archive(try item(r), now: n()); return nil },
                verify: { r in itemNow(r)?.status == .archived }),
            ClosureHandler(d(split, "Break into smaller tasks", "New tasks exist; original unchanged"),
                execute: { r in
                    guard case let .array(a)? = r.parameters["titles"] else { throw BrokerError.badParameter("titles") }
                    let titles = a.compactMap { if case let .string(s) = $0 { s } else { nil } }
                    let made = try store.split(try item(r), into: titles, now: n())
                    return "\(made.count) new tasks"
                }, verify: { r in itemNow(r)?.events.contains { $0.kind == .split } == true }),
            ClosureHandler(d(convertToGoal, "Turn into a goal", "A goal exists and the item is archived and linked"),
                execute: { r in let g = try store.convertToGoal(try item(r), now: n()); return "goal “\(g.title.prefix(60))”" },
                verify: { r in itemNow(r).map { $0.status == .archived && $0.goal != nil } ?? false }),
            ClosureHandler(d(updateWaiting, "Update what you're waiting for", "Waiting fields equal the request", .reminders),
                execute: { r in
                    try store.updateWaiting(try item(r), waitingOn: r.parameters.string("waitingOn"), expected: r.parameters.string("expected"),
                                            followUpAt: r.parameters.date("followUpAt"), now: n())
                    return r.parameters.date("followUpAt").map { "follow up \(WrenStore.stamp($0))" }
                }, verify: { r in itemNow(r).map { $0.kind == .waiting && $0.followUpAt == r.parameters.date("followUpAt") } ?? false }),
            ClosureHandler(d(acknowledgeFollowUp, "Mark as followed up", "Acknowledgement recorded", .reminders),
                execute: { r in
                    try store.acknowledgeFollowUp(try item(r), next: r.parameters.date("next"), note: r.parameters.string("note"), now: n())
                    return r.parameters.date("next").map { "next \(WrenStore.stamp($0))" }
                }, verify: { r in itemNow(r).map { $0.followUpAcknowledgedAt != nil && $0.followUpAt == r.parameters.date("next") } ?? false }),
            ClosureHandler(d(createGoal, "Create a goal", "A goal with this title exists"),
                execute: { r in
                    guard let title = r.parameters.string("title") else { throw BrokerError.badParameter("title") }
                    let g = try store.createGoal(title: title, originalText: r.parameters.string("originalText"), details: r.parameters.string("details"),
                                                 targetDate: r.parameters.date("targetDate"),
                                                 method: r.parameters.string("method").flatMap(ProgressMethod.init(rawValue:)) ?? .manual, now: n())
                    return g.id.uuidString
                }, verify: { r in ((try? store.goals()) ?? []).contains { $0.title == r.parameters.string("title")?.trimmingCharacters(in: .whitespacesAndNewlines) } }),
            ClosureHandler(d(editGoal, "Edit goal", "Title and target date equal the edit"),
                execute: { r in
                    guard let title = r.parameters.string("title") else { throw BrokerError.badParameter("title") }
                    try store.editGoal(try goal(r), title: title, details: r.parameters.string("details"), targetDate: r.parameters.date("targetDate"), now: n())
                    return nil
                }, verify: { r in goalNow(r).map { $0.targetDate == r.parameters.date("targetDate") } ?? false }),
            ClosureHandler(d(setGoalStatus, "Change goal status", "Goal status equals the request"),
                execute: { r in
                    guard let s = r.parameters.string("status").flatMap(GoalStatus.init(rawValue:)) else { throw BrokerError.badParameter("status") }
                    try store.setGoalStatus(try goal(r), s, now: n()); return s.label
                }, verify: { r in goalNow(r)?.status.rawValue == r.parameters.string("status") }),
            ClosureHandler(d(setGoalProgress, "Set goal progress", "Manual progress equals the request"),
                execute: { r in
                    guard case let .number(v)? = r.parameters["value"] else { throw BrokerError.badParameter("value") }
                    try store.setManualProgress(try goal(r), v, now: n()); return "\(Int((v * 100).rounded()))%"
                }, verify: { r in
                    guard case let .number(v)? = r.parameters["value"], let g = goalNow(r) else { return false }
                    return abs(g.manualProgress - min(max(v, 0), 1)) < 0.0001
                }),
            ClosureHandler(d(setGoalMethod, "Change how progress is measured", "Method equals the request"),
                execute: { r in
                    guard let m = r.parameters.string("method").flatMap(ProgressMethod.init(rawValue:)) else { throw BrokerError.badParameter("method") }
                    try store.setProgressMethod(try goal(r), m, now: n()); return m.label
                }, verify: { r in goalNow(r)?.method.rawValue == r.parameters.string("method") }),
            ClosureHandler(d(linkToGoal, "Link to a goal", "Item's goal equals the request"),
                execute: { r in
                    let g = try goalParam(r.parameters)
                    try store.link(try item(r), to: g, asMilestone: r.parameters.bool("milestone") ?? false, now: n())
                    return "“\(g.title.prefix(60))”"
                }, verify: { r in itemNow(r)?.goal?.id.uuidString == r.parameters.string("goalID") }),
            ClosureHandler(d(unlinkFromGoal, "Unlink from its goal", "Item has no goal"),
                execute: { r in try store.unlink(try item(r), now: n()); return nil },
                verify: { r in itemNow(r)?.goal == nil }),
            ClosureHandler(d(addMilestone, "Add a milestone", "A milestone with this title is linked"),
                execute: { r in
                    guard let title = r.parameters.string("title")?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { throw BrokerError.badParameter("title") }
                    let g = try goal(r)
                    let c = try store.capture(title, source: .manual, now: n())
                    c.kind = .commitment; c.processing = .manual
                    c.deadline = r.parameters.date("deadline")
                    try store.link(c, to: g, asMilestone: true, now: n())
                    return nil
                }, verify: { r in goalNow(r)?.milestones.contains { $0.title == r.parameters.string("title")?.trimmingCharacters(in: .whitespacesAndNewlines) } ?? false }),
            ClosureHandler(d(dismissInsight, "Dismiss an observation", "Observation is closed"),
                execute: { r in try store.closeInsight(try r.parameters.insight(r), as: .dismissed, now: n()); return nil },
                verify: { r in (try? store.insightRecord(r.target.id))?.state == .dismissed }),
            ClosureHandler(d(resolveInsight, "Mark an observation handled", "Observation is closed"),
                execute: { r in
                    let i = try r.parameters.insight(r)
                    if i.kind == .postponed, let id = i.subjectUUID, let c = try store.item(id: id) {
                        try store.recordPostponementReview(c, note: r.parameters.string("note") ?? "kept as is", now: n())
                    }
                    try store.closeInsight(i, as: .resolved, now: n())
                    return nil
                }, verify: { r in (try? store.insightRecord(r.target.id))?.state == .resolved }),
        ]
        handlers.forEach(broker.register)
    }
}

/// Generic trusted handler built from two closures.
@MainActor
final class ClosureHandler: ActionHandler {
    let descriptor: ActionDescriptor
    let run: @MainActor (ActionRequest) throws -> String?
    let check: @MainActor (ActionRequest) -> Bool
    init(_ d: ActionDescriptor, execute: @escaping @MainActor (ActionRequest) throws -> String?, verify: @escaping @MainActor (ActionRequest) -> Bool) {
        descriptor = d; run = execute; check = verify
    }
    func execute(_ r: ActionRequest) async throws -> HandlerOutcome { HandlerOutcome(detail: try run(r)) }
    func verify(_ r: ActionRequest) async -> Verification { check(r) ? .verified : .mismatch }
}

public extension Insight {
    /// Request target and parameters for acting on this observation.
    var targetRef: TargetRef { TargetRef(kind: "insight", id: key, label: title) }
    var parameters: [String: JSONValue] {
        ["kind": .string(kind.rawValue), "subject": .string(subject.rawValue), "subjectID": .string(subjectID),
         "fingerprint": .string(fingerprint), "title": .string(title)]
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func insight(_ r: ActionRequest) throws -> Insight {
        guard let k = string("kind").flatMap(InsightKind.init(rawValue:)), let sub = string("subject").flatMap(InsightSubject.init(rawValue:)),
              let sid = string("subjectID"), let fp = string("fingerprint") else { throw BrokerError.badParameter("insight") }
        let i = Insight(kind: k, subject: sub, subjectID: sid, title: string("title") ?? "", message: "", reason: "", fingerprint: fp)
        guard i.key == r.target.id else { throw BrokerError.badParameter("insight key") }
        return i
    }
}

public extension Goal {
    var targetRef: TargetRef { TargetRef(kind: "goal", id: id.uuidString, label: title) }
}
