import Foundation

/// Explainable goal progress for the method the user chose.
public struct GoalProgressReport: Sendable, Equatable {
    /// nil when there's nothing to measure yet.
    public var fraction: Double?
    public var explanation: String
    public var percentText: String { fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }

    public static func of(_ g: Goal) -> GoalProgressReport {
        switch g.method {
        case .manual:
            return .init(fraction: g.manualProgress, explanation: "Set by you: \(Int((g.manualProgress * 100).rounded()))%.")
        case .linkedTasks:
            return counted(g.tasks, noun: "linked task", empty: "No linked tasks yet. Link tasks, or switch to setting progress yourself.")
        case .milestones:
            return counted(g.milestones, noun: "milestone", empty: "No milestones yet. Add one, or switch to setting progress yourself.")
        }
    }

    private static func counted(_ items: [Commitment], noun: String, empty: String) -> GoalProgressReport {
        let counted = items.filter { $0.status == .pending || $0.status == .completed }
        let excluded = items.count - counted.count
        guard !counted.isEmpty else { return .init(fraction: nil, explanation: empty) }
        let done = counted.filter { $0.status == .completed }.count
        var text = "\(done) of \(counted.count) \(noun)\(counted.count == 1 ? "" : "s") done."
        if excluded > 0 { text += " \(excluded) dropped or archived not counted." }
        text += " Each counts equally, whatever its size."
        return .init(fraction: Double(done) / Double(counted.count), explanation: text)
    }
}

public enum InsightKind: String, Codable, Sendable, CaseIterable {
    case followUpDue, postponed, goalApproaching, stale
    var rank: Int { switch self { case .followUpDue: 0; case .postponed: 1; case .goalApproaching: 2; case .stale: 3 } }
    public var sectionTitle: String {
        switch self {
        case .followUpDue: "Follow-ups due"
        case .postponed: "Moved several times"
        case .goalApproaching: "Goals coming up"
        case .stale: "Quiet for a while"
        }
    }
}

public enum InsightSubject: String, Codable, Sendable { case commitment, goal }

/// One neutral observation that needs a decision. Derived only from stored data.
public struct Insight: Sendable, Equatable, Identifiable {
    public var kind: InsightKind
    public var subject: InsightSubject
    public var subjectID: String
    public var title: String
    /// What Wren noticed, phrased neutrally.
    public var message: String
    /// The exact criteria that matched.
    public var reason: String
    /// Changes only when the situation changes, so a dismissed observation stays dismissed.
    public var fingerprint: String

    public var key: String { "\(kind.rawValue)|\(subjectID)|\(fingerprint)" }
    public var id: String { key }
    public var subjectUUID: UUID? { UUID(uuidString: subjectID) }
}

/// Thresholds, all user-adjustable.
public struct InsightSettings: Sendable, Equatable, Codable {
    public var postponeThreshold = 3
    public var staleTaskDays = 14
    public var staleIdeaDays = 30
    public var staleGoalDays = 14
    /// A due follow-up is shown as "due" this many days, then as stale.
    public var followUpGraceDays = 3
    public var goalApproachDays = 7
    public init() {}

    public func normalized() -> InsightSettings {
        var s = self
        s.postponeThreshold = min(max(postponeThreshold, 2), 10)
        s.staleTaskDays = min(max(staleTaskDays, 3), 90)
        s.staleIdeaDays = min(max(staleIdeaDays, 7), 365)
        s.staleGoalDays = min(max(staleGoalDays, 3), 90)
        s.followUpGraceDays = min(max(followUpGraceDays, 1), 14)
        s.goalApproachDays = min(max(goalApproachDays, 1), 30)
        return s
    }
}

/// Deterministic rules. No model, no network.
public enum InsightEngine {
    public static func compute(items: [Commitment], goals: [Goal], now: Date, calendar cal: Calendar,
                               settings raw: InsightSettings = InsightSettings()) -> [Insight] {
        let s = raw.normalized()
        let today = cal.startOfDay(for: now)
        func days(_ from: Date, _ to: Date) -> Int { cal.dateComponents([.day], from: cal.startOfDay(for: from), to: cal.startOfDay(for: to)).day ?? 0 }
        func ago(_ d: Date) -> Int { days(d, now) }
        var out: [Insight] = []

        for c in items where c.status == .pending {
            let id = c.id.uuidString

            // Repeated postponement (commitments only).
            if c.kind == .commitment {
                let n = c.postponementCount
                if n >= s.postponeThreshold {
                    let bucket = n / s.postponeThreshold
                    out.append(Insight(kind: .postponed, subject: .commitment, subjectID: id, title: c.title,
                                       message: "You've moved this \(n) times. Would you like to reschedule it, break it into smaller steps, or drop it?",
                                       reason: "Snoozed or had its deadline moved later \(n) times (threshold \(s.postponeThreshold)).",
                                       fingerprint: "b\(bucket)"))
                }
            }

            // Waiting items.
            if c.kind == .waiting {
                let on = c.waitingOn.map { " on \($0)" } ?? ""
                if let f = c.followUpAt, f <= now, (c.followUpAcknowledgedAt ?? .distantPast) < f {
                    let late = ago(f)
                    if late < s.followUpGraceDays {
                        out.append(Insight(kind: .followUpDue, subject: .commitment, subjectID: id, title: c.title,
                                           message: "It's time to follow up\(on).\(c.expectedResponse.map { " Expected: \($0)." } ?? "")",
                                           reason: "Follow-up date \(DueText.describe(f, hasTime: false, now: now, calendar: cal)) has arrived.",
                                           fingerprint: "f\(Int(f.timeIntervalSince1970))"))
                    } else {
                        out.append(Insight(kind: .stale, subject: .commitment, subjectID: id, title: c.title,
                                           message: "The follow-up date passed \(late) days ago. Follow up, set a new date, or archive it?",
                                           reason: "Follow-up date passed more than \(s.followUpGraceDays) days ago without being marked as followed up.",
                                           fingerprint: "fs\(Int(f.timeIntervalSince1970))"))
                    }
                } else if c.followUpAt == nil, ago(c.effectiveWaitingSince) >= s.staleTaskDays, ago(c.lastActivityAt) >= s.staleTaskDays {
                    out.append(Insight(kind: .stale, subject: .commitment, subjectID: id, title: c.title,
                                       message: "You've been waiting\(on) for \(ago(c.effectiveWaitingSince)) days with no follow-up date.",
                                       reason: "Waiting \(s.staleTaskDays)+ days, no follow-up date, no activity since \(cal.dayKey(for: c.lastActivityAt)).",
                                       fingerprint: "a\(cal.dayKey(for: c.lastActivityAt))"))
                }
                continue
            }

            // Stale: open item with no activity and nothing ahead of it.
            let hasFutureDate = (c.deadline.map { $0 >= today } ?? false) || (c.nextReminderAt.map { $0 > now } ?? false)
            let overdue = c.deadline.map { c.deadlineHasTime ? $0 < now : $0 < today } ?? false
            guard !hasFutureDate, !overdue else { continue }
            let limit = c.kind == .idea ? s.staleIdeaDays : s.staleTaskDays
            let quiet = ago(c.lastActivityAt)
            if quiet >= limit {
                out.append(Insight(kind: .stale, subject: .commitment, subjectID: id, title: c.title,
                                   message: c.kind == .idea ? "This idea has been sitting for \(quiet) days. Keep it, act on it, or archive it?"
                                                            : "No activity for \(quiet) days. Keep it, give it a date, or archive it?",
                                   reason: "No activity for \(limit)+ days (last \(cal.dayKey(for: c.lastActivityAt))), no upcoming deadline or reminder.",
                                   fingerprint: "a\(cal.dayKey(for: c.lastActivityAt))"))
            }
        }

        for g in goals where g.status == .active {
            let id = g.id.uuidString
            let progress = GoalProgressReport.of(g)
            if let t = g.targetDate {
                let left = days(now, t)
                if left <= s.goalApproachDays {
                    let bucket = left < 0 ? "past" : left <= 1 ? "imminent" : "soon"
                    let when = left < 0 ? "was \(DueText.describe(t, hasTime: false, now: now, calendar: cal))" : "is \(DueText.describe(t, hasTime: false, now: now, calendar: cal))"
                    out.append(Insight(kind: .goalApproaching, subject: .goal, subjectID: id, title: g.title,
                                       message: "Target date \(when). Progress: \(progress.percentText).",
                                       reason: "Target within \(s.goalApproachDays) days. \(progress.explanation)",
                                       fingerprint: "\(bucket)|\(cal.dayKey(for: t))"))
                }
            }
            let quiet = ago(g.lastActivityAt)
            if quiet >= s.staleGoalDays {
                out.append(Insight(kind: .stale, subject: .goal, subjectID: id, title: g.title,
                                   message: "No progress recorded for \(quiet) days. Keep going, pause it, or archive it?",
                                   reason: "Active goal with no progress or linked-task activity for \(s.staleGoalDays)+ days.",
                                   fingerprint: "a\(cal.dayKey(for: g.lastActivityAt))"))
            }
        }
        return out.sorted { ($0.kind.rank, $0.title) < ($1.kind.rank, $1.title) }
    }
}
