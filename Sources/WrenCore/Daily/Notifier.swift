import Foundation

public struct ReminderPayload: Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var body: String
    public var late: Bool

    static func body(for c: Commitment) -> String {
        if let d = c.deadline { return "Due \(DueText.describe(d, hasTime: c.deadlineHasTime))." }
        return "You asked Wren to remind you."
    }
}

/// Notification delivery, injected so engines are testable and model-free.
/// Every method returns whether macOS accepted the request; visibility is not guaranteed.
@MainActor
public protocol WrenNotifier: AnyObject {
    func canDeliver() async -> Bool
    func deliverReminder(_ p: ReminderPayload) async -> Bool
    func deliverBriefing(_ b: Briefing) async -> Bool
    func deliverCheckIn(_ c: CheckIn) async -> Bool
    func withdrawReminder(id: UUID)
    /// One notification summarising reminders that came due while notifications were paused.
    func deliverPauseSummary(_ items: [ReminderPayload], pausedSince: Date) async -> Bool
}

public enum DueText {
    public static func describe(_ d: Date, hasTime: Bool, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = d.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone))
        let day: String
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: d)).day ?? 99
        switch days {
        case 0: day = "today"
        case 1: day = "tomorrow"
        case -1: day = "yesterday"
        case 2...6:
            var f = Date.FormatStyle.dateTime.weekday(.wide); f.timeZone = calendar.timeZone
            day = d.formatted(f)
        default:
            var f = Date.FormatStyle.dateTime.day().month(.abbreviated); f.timeZone = calendar.timeZone
            day = d.formatted(f)
        }
        return hasTime ? "\(day) at \(time)" : day
    }
}
