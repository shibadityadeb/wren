import Foundation

/// Deterministic reminder rules. Pure functions of (items, settings, now).
public struct ReminderPolicy: Sendable, Equatable {
    /// Hour used when a deadline has a date but no time ("by Friday").
    public var dateOnlyReminderHour: Int
    public var calendar: Calendar

    public init(dateOnlyReminderHour: Int = 10, calendar: Calendar = .current) {
        self.dateOnlyReminderHour = dateOnlyReminderHour
        self.calendar = calendar
    }

    /// First reminder implied by a deadline. Nil for non-commitments, undated items,
    /// or when the implied time has already passed.
    public func initialReminder(for c: Commitment, now: Date) -> Date? {
        guard c.status == .pending, c.kind == .commitment, let deadline = c.deadline else { return nil }
        let when: Date
        if c.deadlineHasTime {
            when = deadline
        } else {
            when = calendar.date(bySettingHour: dateOnlyReminderHour, minute: 0, second: 0, of: deadline) ?? deadline
        }
        return when > now ? when : nil
    }

    /// An item is due iff it is pending, has a reminder time that has arrived,
    /// and that exact reminder has not already been sent.
    public static func isDue(_ c: Commitment, now: Date) -> Bool {
        guard c.status == .pending, let next = c.nextReminderAt, next <= now else { return false }
        if let last = c.lastReminderAt, last >= next { return false }
        return true
    }

    public static func due(_ items: [Commitment], now: Date) -> [Commitment] {
        items.filter { isDue($0, now: now) }.sorted { ($0.nextReminderAt ?? now) < ($1.nextReminderAt ?? now) }
    }

    /// When the scheduler should next wake: the earliest future reminder, capped.
    public static func nextWake(_ items: [Commitment], now: Date, cap: TimeInterval = 60) -> Date {
        let upcoming = items.compactMap { $0.status == .pending ? $0.nextReminderAt : nil }.filter { $0 > now }.min()
        return min(upcoming ?? now.addingTimeInterval(cap), now.addingTimeInterval(cap))
    }
}
