import Foundation

/// When the two daily events happen. Times are minutes after local midnight.
public struct DailySettings: Sendable, Equatable, Codable {
    public var briefingEnabled = true
    public var briefingMinutes = 11 * 60
    public var checkInEnabled = true
    public var checkInMinutes = 19 * 60
    /// Send even when there's nothing to report.
    public var sendEmptySummaries = false
    /// Nothing daily is sent at or after this hour; a missed event waits for tomorrow.
    public var lastDeliveryMinutes = 23 * 60

    public init() {}

    public static let briefingRange = (5 * 60)...(14 * 60 + 59)
    public static let checkInRange = (15 * 60)...(22 * 60 + 59)

    /// Clamp to sane ranges so the briefing is always before the check-in.
    public func normalized() -> DailySettings {
        var s = self
        s.briefingMinutes = min(max(briefingMinutes, Self.briefingRange.lowerBound), Self.briefingRange.upperBound)
        s.checkInMinutes = min(max(checkInMinutes, Self.checkInRange.lowerBound), Self.checkInRange.upperBound)
        return s
    }
}

public enum DailyEvent: Sendable, Equatable { case briefing, checkIn }

/// What the scheduler should do now for one daily event.
public enum DailyDecision: Sendable, Equatable {
    case wait
    /// Within its window and not yet handled today.
    case run
    /// Window passed without Wren running; record as missed (never sent late the next day).
    case markMissed
    case markDisabled
    /// Already handled today.
    case done
}

/// Pure timing rules.
///
/// Briefing window: from the briefing time until the check-in time (or the last delivery
/// time if the check-in is off). Check-in window: from the check-in time until the last
/// delivery time. If Wren starts inside a window, the event runs once, late. If it starts
/// after the window, the event is recorded as missed and not sent.
public enum DailySchedule {
    public static func window(_ e: DailyEvent, on day: Date, settings s: DailySettings, calendar: Calendar) -> Range<Date> {
        let s = s.normalized()
        let last = calendar.time(minutesAfterMidnight: s.lastDeliveryMinutes, on: day)
        switch e {
        case .briefing:
            let start = calendar.time(minutesAfterMidnight: s.briefingMinutes, on: day)
            let end = s.checkInEnabled ? calendar.time(minutesAfterMidnight: s.checkInMinutes, on: day) : last
            return start..<max(end, start)
        case .checkIn:
            let start = calendar.time(minutesAfterMidnight: s.checkInMinutes, on: day)
            return start..<max(last, start)
        }
    }

    public static func decide(_ e: DailyEvent, state: DailyEventState, now: Date, settings: DailySettings, calendar: Calendar) -> DailyDecision {
        guard state == .pending else { return .done }
        let enabled = e == .briefing ? settings.briefingEnabled : settings.checkInEnabled
        let w = window(e, on: now, settings: settings, calendar: calendar)
        if now < w.lowerBound { return .wait }
        if !enabled { return .markDisabled }
        return w.contains(now) ? .run : .markMissed
    }

    /// Next moment worth waking for daily events (start of the next pending window, or tomorrow).
    public static func nextBoundary(after now: Date, settings: DailySettings, calendar: Calendar) -> Date {
        let candidates = [DailyEvent.briefing, .checkIn].flatMap { e -> [Date] in
            [0, 1].compactMap { offset in
                calendar.date(byAdding: .day, value: offset, to: now).map { window(e, on: $0, settings: settings, calendar: calendar).lowerBound }
            }
        }
        return candidates.filter { $0 > now }.min() ?? now.addingTimeInterval(3600)
    }
}
