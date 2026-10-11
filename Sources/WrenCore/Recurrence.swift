import Foundation

/// A repeating reminder at a wall-clock time: every day, or on chosen weekdays. Times are local
/// ("3 PM wherever you are"), so daylight-saving changes and travel keep the same clock time.
public struct RecurrenceRule: Codable, Equatable, Sendable, Hashable {
    /// Calendar weekdays (1 = Sunday … 7 = Saturday), sorted. Empty means every day.
    public var weekdays: [Int]
    public var hour: Int
    public var minute: Int

    public init(weekdays: [Int], hour: Int, minute: Int) {
        self.weekdays = Array(Set(weekdays.filter { (1...7).contains($0) })).sorted()
        self.hour = hour; self.minute = minute
    }

    public static let weekdaySet = [2, 3, 4, 5, 6]
    public static let weekendSet = [1, 7]

    public var isDaily: Bool { weekdays.isEmpty || weekdays.count == 7 }

    /// The next occurrence strictly after `date`. DST gaps resolve to the next valid time.
    public func next(after date: Date, calendar: Calendar) -> Date? {
        let days = isDaily ? [nil] : weekdays.map { Optional($0) }
        return days.compactMap { wd -> Date? in
            var c = DateComponents(); c.hour = hour; c.minute = minute; c.second = 0; c.weekday = wd
            return calendar.nextDate(after: date, matching: c, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
        }.min()
    }

    /// True when `date` is one of this rule's occurrences.
    public func matches(_ date: Date, calendar: Calendar) -> Bool {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard c.hour == hour, c.minute == minute else { return false }
        return isDaily || weekdays.contains(c.weekday ?? 0)
    }

    /// One repeating calendar trigger per weekday (or one daily), as macOS schedules them.
    public var triggerComponents: [DateComponents] {
        if isDaily { return [DateComponents(hour: hour, minute: minute)] }
        return weekdays.map { DateComponents(hour: hour, minute: minute, weekday: $0) }
    }

    public func label(calendar: Calendar = .current) -> String {
        let days: String
        switch weekdays {
        case _ where isDaily: days = "Every day"
        case Self.weekdaySet: days = "Every weekday"
        case Self.weekendSet: days = "Every weekend day"
        default:
            let names = calendar.weekdaySymbols
            days = "Every " + Self.list(weekdays.map { names[$0 - 1] })
        }
        var c = DateComponents(); c.hour = hour; c.minute = minute
        let t = calendar.date(from: c).map { $0.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)) } ?? "\(hour):\(minute)"
        return "\(days) at \(t)".replacingOccurrences(of: "\u{202F}", with: " ")
    }

    static func list(_ items: [String]) -> String {
        items.count <= 1 ? (items.first ?? "") : items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    // MARK: Reading "every weekday at 3 PM"

    public struct Found: Equatable, Sendable {
        /// nil when the days were clear but no time of day was given.
        public var rule: RecurrenceRule?
        public var weekdays: [Int]
        public var phrase: String
    }

    /// Finds a repetition in the text. Returns nil when there's none.
    public static func find(in text: String, calendar: Calendar = .current) -> Found? {
        let s = text.lowercased()
        let dayNames = DateParser.weekdays.map(\.0).sorted { $0.count > $1.count }.joined(separator: "|")
        let patterns: [(String, ([String]) -> [Int]?)] = [
            (#"\b(every\s+weekday|on\s+weekdays|weekdays|every\s+work\s*day)\b"#, { _ in weekdaySet }),
            (#"\b(every\s+weekend(\s+day)?|on\s+weekends|weekends)\b"#, { _ in weekendSet }),
            (#"\b(every\s*day|daily|each\s+day|every\s+(morning|afternoon|evening|night))\b"#, { _ in [] }),
            // "every monday and thursday", "each fri", or plural "on mondays". A plain "on friday" is one day, not a repeat.
            (#"\b(?:(?:every|each)\s+((?:"# + dayNames + #")s?(?:\s*(?:,|and|&)\s*(?:"# + dayNames + #")s?)*)|on\s+((?:"# + dayNames + #")s(?:\s*(?:,|and|&)\s*(?:"# + dayNames + #")s)*))\b"#, { groups in
                guard let g = groups.first(where: { !$0.isEmpty }) else { return nil }
                let words = g.split(whereSeparator: { !$0.isLetter }).map { String($0).hasSuffix("s") && $0.count > 3 ? String($0.dropLast()) : String($0) }
                let days = words.compactMap { w in DateParser.weekdays.first { $0.0 == w }?.1 }
                return days.isEmpty ? nil : days
            }),
        ]
        for (p, days) in patterns {
            guard let re = try? NSRegularExpression(pattern: p), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r = Range(m.range, in: s) else { continue }
            let groups = (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
            guard let wd = days(groups) else { continue }
            var phraseRange = r
            var time = DateParser(calendar: calendar).time(in: s)
            // "every evening" with no clock time means the evening hour.
            if time == nil, let part = s[r].firstMatch(of: /(morning|afternoon|evening|night)/) {
                let h = DateParser.partOfDayHour(String(part.1))
                return Found(rule: RecurrenceRule(weekdays: wd, hour: h, minute: 0), weekdays: wd, phrase: String(s[r]))
            }
            guard let t = time else { return Found(rule: nil, weekdays: wd, phrase: String(s[r])) }
            if !t.meridiemKnown, (1...11).contains(t.hour) { time = nil }   // "every day at 3": ask AM or PM
            phraseRange = min(r.lowerBound, t.range.lowerBound)..<max(r.upperBound, t.range.upperBound)
            guard let t2 = time else { return Found(rule: nil, weekdays: wd, phrase: String(s[phraseRange])) }
            return Found(rule: RecurrenceRule(weekdays: wd, hour: t2.hour, minute: t2.minute), weekdays: wd, phrase: String(s[phraseRange]))
        }
        return nil
    }
}
