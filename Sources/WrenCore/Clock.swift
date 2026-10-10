import Foundation

/// Injected source of "now" and the user's calendar/timezone. Engines never call Date() directly.
public protocol WrenClock: Sendable {
    var now: Date { get }
    var calendar: Calendar { get }
}

public struct SystemClock: WrenClock {
    public init() {}
    public var now: Date { Date() }
    /// Re-read each time so timezone changes on the Mac are picked up.
    public var calendar: Calendar { Calendar.autoupdatingCurrent }
}

/// Settable clock for tests and previews.
public final class FixedClock: WrenClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    public let calendar: Calendar
    public init(_ now: Date, calendar: Calendar) { _now = now; self.calendar = calendar }
    public var now: Date { lock.withLock { _now } }
    public func set(_ d: Date) { lock.withLock { _now = d } }
    public func advance(_ seconds: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(seconds) } }
}

extension Calendar {
    /// Stable per-day key in this calendar's timezone, e.g. "2026-10-10".
    public func dayKey(for date: Date) -> String {
        let c = dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `minutes` after local midnight of `date`'s day. On a DST gap the next valid time is used.
    public func time(minutesAfterMidnight minutes: Int, on date: Date) -> Date {
        let start = startOfDay(for: date)
        return self.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: start, matchingPolicy: .nextTime,
                         repeatedTimePolicy: .first, direction: .forward) ?? start.addingTimeInterval(TimeInterval(minutes * 60))
    }
}
