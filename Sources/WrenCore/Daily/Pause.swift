import Foundation

/// "Don't notify me" state. Persisted by the app so it survives restarts.
public struct NotificationPause: Codable, Equatable, Sendable {
    public var since: Date
    /// nil = until resumed manually.
    public var until: Date?

    public init(since: Date, until: Date?) { self.since = since; self.until = until }

    public func isActive(at now: Date) -> Bool { until.map { now < $0 } ?? true }

    public enum Option: String, CaseIterable, Sendable {
        case oneHour, endOfDay, untilResumed
        public var label: String {
            switch self {
            case .oneHour: "For 1 hour"
            case .endOfDay: "Until the end of today"
            case .untilResumed: "Until I resume"
            }
        }
    }

    public static func make(_ o: Option, now: Date, calendar: Calendar) -> NotificationPause {
        switch o {
        case .oneHour: NotificationPause(since: now, until: now.addingTimeInterval(3600))
        case .endOfDay: NotificationPause(since: now, until: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))
        case .untilResumed: NotificationPause(since: now, until: nil)
        }
    }

    public func label(now: Date, calendar: Calendar) -> String {
        guard let until else { return "Paused until you resume" }
        return "Paused until \(DueText.describe(until, hasTime: true, now: now, calendar: calendar))"
    }
}
