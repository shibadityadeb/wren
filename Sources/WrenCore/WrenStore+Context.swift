import Foundation
import SwiftData

public enum GoalError: Error, LocalizedError, Equatable {
    case invalidTransition(GoalStatus, GoalStatus)
    case emptyTitle
    public var errorDescription: String? {
        switch self {
        case let .invalidTransition(a, b): "A goal can't go from \(a.label.lowercased()) to \(b.label.lowercased())."
        case .emptyTitle: "A goal needs a title."
        }
    }
}

/// Goals, waiting items, archive, reschedule, split, and the insight ledger.
/// Every change is logged as history; nothing here runs without a caller (the broker).
@MainActor
extension WrenStore {
    static func isLater(_ new: Date?, than old: Date?) -> Bool {
        guard let new, let old else { return false }
        return new > old
    }

    func logGoal(_ g: Goal, _ kind: GoalEventKind, at: Date, note: String? = nil) {
        let e = GoalEvent(kind: kind, at: at, note: note)
        context.insert(e)
        e.goal = g
    }

    // MARK: Items

    /// Changes only the deadline. Moving it later is recorded as a postponement.
    /// Moves the deadline. If the item had a reminder, the reminder moves with it (to the new time,
    /// or `reminderHour` on the new day when no time was given), so moving never silently drops it.
    public func reschedule(_ c: Commitment, deadline: Date?, hasTime: Bool, reminderHour: Int = 10, calendar: Calendar = .current, now: Date = .now) throws {
        try requirePending(c, "reschedule")
        if c.recurrence != nil { throw StoreError.invalidTransition(from: c.status, action: "move a repeating reminder (change its schedule instead)") }
        let later = Self.isLater(deadline, than: c.deadline)
        let hadReminder = c.nextReminderAt != nil || c.reminderFromDeadline
        c.deadline = deadline
        c.deadlineHasTime = hasTime
        if hadReminder {
            let when = deadline.flatMap { d in hasTime ? d : calendar.date(bySettingHour: reminderHour, minute: 0, second: 0, of: d) }
            c.nextReminderAt = when.flatMap { $0 > now ? $0 : nil }
            c.reminderFromDeadline = c.nextReminderAt != nil
            if let w = c.nextReminderAt { log(c, .reminderScheduled, at: now, note: "moved with the deadline, \(Self.stamp(w))") }
        }
        log(c, later ? .deadlineMoved : .edited, at: now, note: deadline.map { "deadline \(Self.stamp($0))" } ?? "deadline removed")
        try save()
    }

    public func archive(_ c: Commitment, now: Date = .now) throws {
        try requirePending(c, "archive")
        c.status = .archived
        c.archivedAt = now
        c.nextReminderAt = nil
        log(c, .archived, at: now)
        try save()
    }

    /// Creates smaller tasks from one item. The original is left as it is; the user decides what to do with it.
    @discardableResult
    public func split(_ c: Commitment, into titles: [String], now: Date = .now) throws -> [Commitment] {
        try requirePending(c, "split")
        let clean = titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { throw StoreError.emptyText }
        let parts = clean.map { t -> Commitment in
            let n = Commitment(originalText: t, source: .manual, now: now)
            n.kind = .commitment
            n.processing = .manual
            n.goal = c.goal
            context.insert(n)
            log(n, .captured, at: now, note: "split from “\(c.title.prefix(60))”")
            return n
        }
        log(c, .split, at: now, note: "into \(parts.count) tasks")
        try save()
        return parts
    }

    /// The user answered a postponement observation without changing the item.
    public func recordPostponementReview(_ c: Commitment, note: String, now: Date = .now) throws {
        log(c, .postponementReviewed, at: now, note: note)
        try save()
    }

    // MARK: Waiting items

    public func updateWaiting(_ c: Commitment, waitingOn: String?, expected: String?, followUpAt: Date?, now: Date = .now) throws {
        try requirePending(c, "update")
        func clean(_ s: String?) -> String? { s.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) } }
        c.kind = .waiting
        c.waitingOn = clean(waitingOn)
        c.expectedResponse = clean(expected)
        if c.waitingSince == nil { c.waitingSince = now }
        let changedFollowUp = followUpAt != c.followUpAt
        c.followUpAt = followUpAt
        log(c, .waitingUpdated, at: now)
        if changedFollowUp, let f = followUpAt { log(c, .followUpScheduled, at: now, note: Self.stamp(f)) }
        try save()
    }

    /// The user dealt with a due follow-up. It stays quiet until `next` (if given).
    public func acknowledgeFollowUp(_ c: Commitment, next: Date?, note: String?, now: Date = .now) throws {
        try requirePending(c, "follow up on")
        c.followUpAcknowledgedAt = now
        c.followUpAt = next
        log(c, .followedUp, at: now, note: note.map { String($0.prefix(120)) })
        if let next { log(c, .followUpScheduled, at: now, note: Self.stamp(next)) }
        try save()
    }

    // MARK: Goals

    public func goals() throws -> [Goal] {
        try context.fetch(FetchDescriptor<Goal>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    public func goal(id: UUID) throws -> Goal? {
        var d = FetchDescriptor<Goal>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    @discardableResult
    public func createGoal(title: String, originalText: String? = nil, details: String? = nil, targetDate: Date?,
                           method: ProgressMethod = .manual, now: Date = .now) throws -> Goal {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw GoalError.emptyTitle }
        let g = Goal(title: String(t.prefix(200)), originalText: originalText ?? t, targetDate: targetDate, now: now)
        g.details = details
        g.method = method
        context.insert(g)
        logGoal(g, .created, at: now, note: targetDate.map { "target \(Self.stamp($0))" })
        try save()
        return g
    }

    /// Explicit edit. Target date changes are logged separately so they're never silent.
    public func editGoal(_ g: Goal, title: String, details: String?, targetDate: Date?, now: Date = .now) throws {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw GoalError.emptyTitle }
        if g.title != t || g.details != details { logGoal(g, .edited, at: now) }
        if g.targetDate != targetDate {
            logGoal(g, .targetDateChanged, at: now, note: targetDate.map { Self.stamp($0) } ?? "removed")
        }
        g.title = String(t.prefix(200))
        g.details = details?.isEmpty == true ? nil : details
        g.targetDate = targetDate
        g.updatedAt = now
        try save()
    }

    public func setGoalStatus(_ g: Goal, _ s: GoalStatus, now: Date = .now) throws {
        let allowed: [GoalStatus: Set<GoalStatus>] = [
            .active: [.paused, .completed, .archived],
            .paused: [.active, .completed, .archived],
            .completed: [.active, .archived],
            .archived: [.active],
        ]
        guard allowed[g.status]?.contains(s) == true else { throw GoalError.invalidTransition(g.status, s) }
        logGoal(g, .statusChanged, at: now, note: "\(g.status.rawValue) → \(s.rawValue)")
        g.status = s
        g.completedAt = s == .completed ? now : nil
        g.updatedAt = now
        try save()
    }

    public func setProgressMethod(_ g: Goal, _ m: ProgressMethod, now: Date = .now) throws {
        guard g.method != m else { return }
        logGoal(g, .methodChanged, at: now, note: m.label)
        g.method = m
        g.updatedAt = now
        try save()
    }

    public func setManualProgress(_ g: Goal, _ value: Double, now: Date = .now) throws {
        let v = min(max(value, 0), 1)
        logGoal(g, .progressChanged, at: now, note: "\(Int((g.manualProgress * 100).rounded()))% → \(Int((v * 100).rounded()))%")
        g.manualProgress = v
        g.lastProgressAt = now
        g.updatedAt = now
        try save()
    }

    public func link(_ c: Commitment, to g: Goal, asMilestone: Bool, now: Date = .now) throws {
        if let old = c.goal, old.id != g.id { try unlink(c, now: now) }
        c.goal = g
        c.isMilestone = asMilestone
        log(c, .linkedToGoal, at: now, note: "“\(g.title.prefix(60))”\(asMilestone ? " as a milestone" : "")")
        logGoal(g, .taskLinked, at: now, note: "“\(c.title.prefix(60))”")
        g.updatedAt = now
        try save()
    }

    public func unlink(_ c: Commitment, now: Date = .now) throws {
        guard let g = c.goal else { return }
        log(c, .unlinkedFromGoal, at: now, note: "“\(g.title.prefix(60))”")
        logGoal(g, .taskUnlinked, at: now, note: "“\(c.title.prefix(60))”")
        c.goal = nil
        c.isMilestone = false
        g.updatedAt = now
        try save()
    }

    /// Turns an item into a goal. The item is archived (not deleted) and stays linked, so its history is kept.
    @discardableResult
    public func convertToGoal(_ c: Commitment, now: Date = .now) throws -> Goal {
        try requirePending(c, "convert")
        let g = try createGoal(title: c.title, originalText: c.originalText, details: c.details, targetDate: c.deadline, now: now)
        c.goal = g
        c.status = .archived
        c.archivedAt = now
        c.nextReminderAt = nil
        log(c, .convertedToGoal, at: now, note: "“\(g.title.prefix(60))”")
        logGoal(g, .taskLinked, at: now, note: "from “\(c.title.prefix(60))”")
        try save()
        return g
    }

    // MARK: Erase

    /// Removes everything the user created and resets permissions to the defaults. Keeps only the
    /// audit record of this erase (so the log shows that it happened, without content).
    public func eraseAllUserData(keepingAuditFor requestID: UUID?, now: Date = .now) throws {
        try context.fetch(FetchDescriptor<Commitment>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<ActivityEvent>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<Goal>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<GoalEvent>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<InsightRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<DailyRun>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<DenialRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<AuditRecord>()).filter { $0.requestID != requestID }.forEach(context.delete)
        try context.fetch(FetchDescriptor<PermissionGrantRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<StandingRuleRecord>()).forEach(context.delete)
        for p in PolicySnapshot.defaultGrants { context.insert(PermissionGrantRecord(p, at: now)) }
        for k in StandingRuleKind.defaults { context.insert(StandingRuleRecord(k, at: now)) }
        try save()
    }

    public func userDataCounts() -> [String: Int] {
        ["items": (try? context.fetchCount(FetchDescriptor<Commitment>())) ?? 0,
         "goals": (try? context.fetchCount(FetchDescriptor<Goal>())) ?? 0,
         "historyEvents": (try? context.fetchCount(FetchDescriptor<ActivityEvent>())) ?? 0]
    }

    // MARK: Insight ledger

    public func insightRecord(_ key: String) throws -> InsightRecord? {
        var d = FetchDescriptor<InsightRecord>(predicate: #Predicate { $0.key == key })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    func ensureInsightRecord(_ i: Insight, now: Date) throws -> InsightRecord {
        if let r = try insightRecord(i.key) { return r }
        let r = InsightRecord(key: i.key, kind: i.kind.rawValue, subjectID: i.subjectID, fingerprint: i.fingerprint, at: now)
        context.insert(r)
        return r
    }

    /// Dismissed or resolved insights stay closed for this exact situation.
    public func isClosed(_ i: Insight) -> Bool {
        guard let r = try? insightRecord(i.key) else { return false }
        return r.state != .open
    }

    public func wasSurfaced(_ i: Insight) -> Bool {
        (try? insightRecord(i.key))?.surfacedAt != nil
    }

    public func markSurfaced(_ insights: [Insight], now: Date) throws {
        for i in insights { try ensureInsightRecord(i, now: now).surfacedAt = now }
        try save()
    }

    public func closeInsight(_ i: Insight, as state: InsightState, now: Date) throws {
        let r = try ensureInsightRecord(i, now: now)
        r.state = state
        r.closedAt = now
        try save()
    }
}
