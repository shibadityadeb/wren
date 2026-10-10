import AppKit
import WrenCore

/// What the capture panel should show after Return.
enum CaptureReply {
    /// Saved as a new item; close the panel.
    case saved
    case resolution(ContextResolution)
    case failed(String)
}

/// Goals, waiting items, insights and contextual commands. Every change goes through `run`
/// (the ActionBroker). Contextual proposals are confirmed explicitly before they run.
@MainActor
extension AppModel {
    func noteRecent(_ id: UUID) {
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
        if recentIDs.count > 10 { recentIDs.removeLast() }
    }

    var conversation: ConversationContext {
        var selected: UUID?
        if case let .detail(id) = route { selected = id }
        return ConversationContext(selected: selected, recent: recentIDs)
    }

    var resolver: ContextResolver { ContextResolver(calendar: clock.calendar, dateOnlyReminderHour: reminderHour) }

    // MARK: Capture panel entry point

    /// A command about an existing item gets a preview or question; anything else is saved as a new capture.
    func submitFromCapture(_ text: String) async -> CaptureReply {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("Nothing to save.") }
        reload()
        let all = (try? store?.all()) ?? []
        let result = resolver.resolve(trimmed, items: all, goals: goals, context: conversation, now: clock.now)
        switch result {
        case .notACommand:
            return capture(trimmed, source: .hotkey) ? .saved : .failed("Couldn't save. Your text is still here.")
        case let .notFound(msg):
            if let picked = await modelFallback(trimmed, all: all) { return .resolution(picked) }
            return .resolution(.notFound(msg))
        default:
            return .resolution(result)
        }
    }

    /// Only when no title matched and a local model is ready. The model picks from a list; the result is a
    /// `.model` proposal, which still has to be confirmed.
    private func modelFallback(_ text: String, all: [Commitment]) async -> ContextResolution? {
        guard settings.useModel, modelStatus.isReady, let name = selectedModel, let client = try? OllamaClient(),
              let (cmd, ref) = resolver.command(text, now: clock.now) else { return nil }
        let pool = all.filter { $0.status == .pending }.sorted { $0.lastActivityAt > $1.lastActivityAt }.prefix(15)
        let cands = pool.map(resolver.candidate)
        guard let pick = await ModelTargetPicker(client: client, model: name).pick(reference: ref, among: Array(cands)),
              let c = pool.first(where: { $0.id == pick.id }) else { return nil }
        return resolver.proposal(for: cmd, item: c, now: clock.now,
                                 note: "Suggested by the local model for “\(ref)”. Check it's the right one.", origin: .model(name))
    }

    func choose(_ candidate: Candidate, for pending: PendingCommand) -> ContextResolution {
        guard let c = item(candidate.id) else { return .notFound("That item no longer exists.") }
        return resolver.proposal(for: pending, item: c, now: clock.now)
    }

    /// The user confirmed the exact preview shown. The confirmation binds to this request only.
    func confirmProposal(_ p: ContextProposal) async -> ActionResult? {
        guard let broker else { return nil }
        noteRecent(UUID(uuidString: p.request.target.id) ?? UUID())
        return await run(p.request, confirmation: broker.confirm(p.request))
    }

    func cancelProposal(_ p: ContextProposal) { broker?.cancel(p.request); reload() }

    // MARK: Goals

    private func goalRequest(_ a: ActionID, _ g: Goal, _ p: [String: JSONValue] = [:]) -> ActionRequest {
        ActionRequest(action: a, target: g.targetRef, parameters: p, origin: .user(.popover), createdAt: clock.now)
    }

    func createGoal(title: String, targetDate: Date?, originalText: String? = nil) {
        var p: [String: JSONValue] = ["title": .string(title)]
        if let t = targetDate { p["targetDate"] = time(t) }
        if let o = originalText { p["originalText"] = .string(o) }
        Task { await run(ActionRequest(action: BuiltInAction.createGoal, target: TargetRef(kind: "goal", id: "new", label: title),
                                       parameters: p, origin: .user(.popover), createdAt: clock.now)) }
    }
    func editGoal(_ g: Goal, title: String, details: String?, targetDate: Date?) {
        var p: [String: JSONValue] = ["title": .string(title), "details": details.map(JSONValue.string) ?? .null]
        if let t = targetDate { p["targetDate"] = time(t) }
        Task { await run(goalRequest(BuiltInAction.editGoal, g, p)) }
    }
    func setGoalStatus(_ g: Goal, _ s: GoalStatus) { Task { await run(goalRequest(BuiltInAction.setGoalStatus, g, ["status": .string(s.rawValue)])) } }
    func setGoalMethod(_ g: Goal, _ m: ProgressMethod) { Task { await run(goalRequest(BuiltInAction.setGoalMethod, g, ["method": .string(m.rawValue)])) } }
    func setGoalProgress(_ g: Goal, _ v: Double) { Task { await run(goalRequest(BuiltInAction.setGoalProgress, g, ["value": .number(v)])) } }
    func addMilestone(_ g: Goal, title: String) { Task { await run(goalRequest(BuiltInAction.addMilestone, g, ["title": .string(title)])) } }
    func link(_ c: Commitment, to g: Goal, milestone: Bool) {
        Task { await run(request(BuiltInAction.linkToGoal, c, .popover, ["goalID": .string(g.id.uuidString), "milestone": .bool(milestone)])) }
    }
    func unlink(_ c: Commitment) { Task { await run(request(BuiltInAction.unlinkFromGoal, c, .popover)) } }
    func convertToGoal(_ c: Commitment) {
        Task {
            let r = await run(request(BuiltInAction.convertToGoal, c, .popover))
            if r?.status == .succeeded, let g = item(c.id)?.goal { route = .goal(g.id) }
        }
    }
    func goal(_ id: UUID) -> Goal? { try? store?.goal(id: id) }

    // MARK: Items

    func archive(_ c: Commitment, via ch: UserChannel = .popover) { Task { await run(request(BuiltInAction.archive, c, ch)) } }
    func reschedule(_ c: Commitment, to d: Date, hasTime: Bool) {
        Task { await run(request(BuiltInAction.reschedule, c, .popover, ["deadline": time(d), "hasTime": .bool(hasTime)])) }
    }
    func split(_ c: Commitment, into titles: [String]) {
        Task { await run(request(BuiltInAction.split, c, .popover, ["titles": .array(titles.map(JSONValue.string))])) }
    }

    // MARK: Waiting

    func updateWaiting(_ c: Commitment, on: String, expected: String, followUp: Date?) {
        var p: [String: JSONValue] = ["waitingOn": .string(on), "expected": .string(expected)]
        if let f = followUp { p["followUpAt"] = time(f) }
        Task { await run(request(BuiltInAction.updateWaiting, c, .popover, p)) }
    }
    func followedUp(_ c: Commitment, next: Date?, note: String? = nil) {
        var p: [String: JSONValue] = [:]
        if let n = next { p["next"] = time(n) }
        if let note { p["note"] = .string(note) }
        Task { await run(request(BuiltInAction.acknowledgeFollowUp, c, .popover, p)) }
    }

    // MARK: Insights

    func dismiss(_ i: Insight) {
        Task { await run(ActionRequest(action: BuiltInAction.dismissInsight, target: i.targetRef, parameters: i.parameters, origin: .user(.popover), createdAt: clock.now)) }
    }
    func resolve(_ i: Insight, note: String) {
        var p = i.parameters; p["note"] = .string(note)
        Task { await run(ActionRequest(action: BuiltInAction.resolveInsight, target: i.targetRef, parameters: p, origin: .user(.popover), createdAt: clock.now)) }
    }

    func updateInsightSettings(_ f: (inout InsightSettings) -> Void) {
        var s = insightSettings; f(&s)
        insightSettings = s.normalized()
        settings.insights = insightSettings
        reload()
    }
}
