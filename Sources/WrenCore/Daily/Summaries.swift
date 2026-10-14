import Foundation

/// A lightweight, Sendable view of one item for summaries.
public struct SummaryItem: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var kind: CaptureKind
    public var priority: Priority
    public var deadline: Date?
    public var deadlineHasTime: Bool
    public var nextReminderAt: Date?

    public init(_ c: Commitment) {
        id = c.id; title = c.title; kind = c.kind; priority = c.priority
        deadline = c.deadline; deadlineHasTime = c.deadlineHasTime; nextReminderAt = c.nextReminderAt
    }
}

/// Deterministic classification of items relative to a day. No model involved.
struct DayView {
    let now: Date
    let calendar: Calendar
    var startOfToday: Date { calendar.startOfDay(for: now) }
    var startOfTomorrow: Date { calendar.date(byAdding: .day, value: 1, to: startOfToday)! }
    func startOf(daysAhead n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: startOfToday)! }

    func isOverdue(_ c: Commitment) -> Bool {
        guard c.status == .pending, c.kind == .commitment, let d = c.deadline else { return false }
        return c.deadlineHasTime ? d < now : d < startOfToday
    }
    func isDueToday(_ c: Commitment) -> Bool {
        guard c.status == .pending, c.kind == .commitment, let d = c.deadline, !isOverdue(c) else { return false }
        return d >= startOfToday && d < startOfTomorrow
    }
    func isUpcoming(_ c: Commitment, days: Int) -> Bool {
        guard c.status == .pending, c.kind == .commitment, let d = c.deadline else { return false }
        return d >= startOfTomorrow && d < startOf(daysAhead: days + 1)
    }
    func waitingNeedsFollowUp(_ c: Commitment, afterDays: Int) -> Bool {
        guard c.status == .pending, c.kind == .waiting else { return false }
        if let r = c.nextReminderAt, r < startOfTomorrow { return true }
        return calendar.dateComponents([.day], from: c.createdAt, to: now).day ?? 0 >= afterDays
    }
    func reminderToday(_ c: Commitment) -> Bool {
        guard c.status == .pending, let r = c.nextReminderAt else { return false }
        return r >= startOfToday && r < startOfTomorrow
    }

    static func byUrgency(_ a: Commitment, _ b: Commitment) -> Bool {
        if a.priority != b.priority { return a.priority > b.priority }
        switch (a.deadline, b.deadline) {
        case let (x?, y?): return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.createdAt < b.createdAt
        }
    }
}

/// Read-only highlights from connected services, fetched at briefing time.
public struct ExternalBriefing: Sendable, Equatable {
    public var emails: [String]
    public var events: [String]
    /// Sources that couldn't be read this time (shown, never hidden).
    public var problems: [String]
    public init(emails: [String] = [], events: [String] = [], problems: [String] = []) {
        self.emails = emails; self.events = events; self.problems = problems
    }
    public var isEmpty: Bool { emails.isEmpty && events.isEmpty }
}

public struct Briefing: Sendable, Equatable {
    public var day: String
    public var overdue: [SummaryItem]
    public var dueToday: [SummaryItem]
    public var upcoming: [SummaryItem]
    /// Waiting items whose follow-up date has arrived (and weren't already surfaced).
    public var waiting: [SummaryItem]
    public var remindersToday: [SummaryItem]
    /// Observations that need a decision: repeated postponement, goals coming up, quiet items.
    public var decisions: [Insight] = []

    public var external: ExternalBriefing?
    /// Open items marked important (high priority) that aren't already listed by date.
    public var important: [SummaryItem] = []
    /// How many of `upcoming` are due tomorrow (named on their own in the notification).
    public var dueTomorrowCount = 0

    public var isEmpty: Bool {
        overdue.isEmpty && dueToday.isEmpty && upcoming.isEmpty && waiting.isEmpty && remindersToday.isEmpty && decisions.isEmpty
            && important.isEmpty && (external?.isEmpty ?? true)
    }

    /// Every insight this briefing shows, for marking as surfaced.
    public var surfacedInsights: [Insight] = []

    /// The few items worth doing first: overdue, then due today, by priority.
    public var focus: [SummaryItem] { Array((overdue + dueToday).prefix(3)) }

    public var title: String { isEmpty ? "Good morning" : "Good morning. Here's today." }

    /// One or two short lines for a notification. The full list lives in the briefing view.
    public var notificationBody: String {
        if isEmpty { return "Nothing due today. Enjoy the space." }
        var counts: [String] = []
        if !overdue.isEmpty { counts.append("\(overdue.count) overdue") }
        if !dueToday.isEmpty { counts.append("\(dueToday.count) due today") }
        if dueTomorrowCount > 0 { counts.append("\(dueTomorrowCount) due tomorrow") }
        if upcoming.count > dueTomorrowCount { counts.append("\(upcoming.count - dueTomorrowCount) more coming up") }
        if !important.isEmpty { counts.append("\(important.count) marked important") }
        if !waiting.isEmpty { counts.append("\(waiting.count) follow-up\(waiting.count == 1 ? "" : "s") due") }
        if !decisions.isEmpty { counts.append("\(decisions.count) need\(decisions.count == 1 ? "s" : "") a decision") }
        if let e = external {
            if !e.events.isEmpty { counts.append("\(e.events.count) event\(e.events.count == 1 ? "" : "s") today") }
            if !e.emails.isEmpty { counts.append("\(e.emails.count) email\(e.emails.count == 1 ? "" : "s") need attention") }
        }
        if !remindersToday.isEmpty && counts.isEmpty { counts.append("\(remindersToday.count) reminder\(remindersToday.count == 1 ? "" : "s") today") }
        var s = counts.joined(separator: ", ") + "."
        if let first = focus.first ?? important.first ?? upcoming.first { s += " Start with “\(first.title)”." }
        return s
    }

    /// Builds from persisted items and precomputed insights only.
    /// `insights` should already exclude dismissed and previously surfaced ones.
    public static func build(from items: [Commitment], now: Date, calendar: Calendar, insights: [Insight] = [],
                             upcomingDays: Int = 3, limit: Int = 5, decisionLimit: Int = 3) -> Briefing {
        let v = DayView(now: now, calendar: calendar)
        let pending = items.filter { $0.status == .pending }
        func pick(_ f: (Commitment) -> Bool) -> [Commitment] { pending.filter(f).sorted(by: DayView.byUrgency) }
        let overdue = pick(v.isOverdue)
        let today = pick(v.isDueToday)
        let upcoming = pending.filter { v.isUpcoming($0, days: upcomingDays) }.sorted { ($0.deadline ?? now) < ($1.deadline ?? now) }
        let followUps = insights.filter { $0.kind == .followUpDue }
        let followUpIDs = Set(followUps.compactMap(\.subjectUUID))
        let waiting = pick { followUpIDs.contains($0.id) }
        let shown = Set((overdue + today + upcoming + waiting).map(\.id))
        let reminders = pending.filter { v.reminderToday($0) && !shown.contains($0.id) }
            .sorted { ($0.nextReminderAt ?? now) < ($1.nextReminderAt ?? now) }
        func s(_ a: [Commitment]) -> [SummaryItem] { a.prefix(limit).map(SummaryItem.init) }
        let decisions = Array(insights.filter { $0.kind != .followUpDue }.prefix(decisionLimit))
        var b = Briefing(day: calendar.dayKey(for: now), overdue: s(overdue), dueToday: s(today), upcoming: s(upcoming),
                         waiting: s(waiting), remindersToday: s(reminders), decisions: decisions)
        b.surfacedInsights = followUps.filter { f in b.waiting.contains { $0.id == f.subjectUUID } } + decisions
        let listed = shown.union(reminders.map(\.id))
        b.important = s(pick { $0.priority == .high && !listed.contains($0.id) })
        b.dueTomorrowCount = b.upcoming.filter { $0.deadline.map { calendar.isDate($0, inSameDayAs: v.startOfTomorrow) } ?? false }.count
        return b
    }
}

public struct CheckIn: Sendable, Equatable {
    public var day: String
    public var completedToday: [SummaryItem]
    public var open: [SummaryItem]        // overdue or due today, still pending
    public var dueSoon: [SummaryItem]     // next two days
    public var waiting: [SummaryItem]
    public var deferredToday: [SummaryItem]
    /// Repeated-postponement and follow-up observations not yet raised today.
    public var decisions: [Insight] = []

    /// Nothing to review. Completed-only days still count as worth a short note.
    public var isEmpty: Bool { completedToday.isEmpty && open.isEmpty && dueSoon.isEmpty && waiting.isEmpty && deferredToday.isEmpty && decisions.isEmpty }

    public var title: String {
        if open.count == 1, let only = open.first { return "Did you finish “\(only.title)”?" }
        return "Evening check-in"
    }

    public var notificationBody: String {
        if open.count == 1 {
            return completedToday.isEmpty ? "It was due today." : "You also finished \(completedToday.count) thing\(completedToday.count == 1 ? "" : "s") today."
        }
        var parts: [String] = []
        if !completedToday.isEmpty { parts.append("\(completedToday.count) done today") }
        if !open.isEmpty { parts.append("\(open.count) still open") }
        if !dueSoon.isEmpty { parts.append("\(dueSoon.count) due soon") }
        if !waiting.isEmpty { parts.append("\(waiting.count) waiting on others") }
        if !decisions.isEmpty { parts.append("\(decisions.count) need\(decisions.count == 1 ? "s" : "") a decision") }
        if parts.isEmpty && !deferredToday.isEmpty { parts.append("\(deferredToday.count) put off today") }
        return parts.joined(separator: ", ") + ". Tap to review."
    }

    /// The one item a single-item check-in notification asks about.
    public var singleItem: SummaryItem? { open.count == 1 ? open.first : nil }

    public static func build(from items: [Commitment], now: Date, calendar: Calendar, insights: [Insight] = [], limit: Int = 8) -> CheckIn {
        let v = DayView(now: now, calendar: calendar)
        let inToday: (Date?) -> Bool = { d in d.map { $0 >= v.startOfToday && $0 < v.startOfTomorrow } ?? false }
        let completed = items.filter { $0.status == .completed && inToday($0.completedAt) }.sorted { ($0.completedAt ?? now) < ($1.completedAt ?? now) }
        let pending = items.filter { $0.status == .pending }
        let open = pending.filter { v.isOverdue($0) || v.isDueToday($0) }.sorted(by: DayView.byUrgency)
        let soon = pending.filter { v.isUpcoming($0, days: 2) }.sorted { ($0.deadline ?? now) < ($1.deadline ?? now) }
        let waiting = pending.filter { $0.kind == .waiting }.sorted(by: DayView.byUrgency)
        let shown = Set((open + soon + waiting).map(\.id))
        let deferred = pending.filter { inToday($0.deferredAt) && !shown.contains($0.id) }
        func s(_ a: [Commitment]) -> [SummaryItem] { a.prefix(limit).map(SummaryItem.init) }
        return CheckIn(day: calendar.dayKey(for: now), completedToday: s(completed), open: s(open), dueSoon: s(soon),
                       waiting: s(waiting), deferredToday: s(deferred),
                       decisions: Array(insights.filter { $0.kind == .postponed || $0.kind == .followUpDue }.prefix(3)))
    }
}
