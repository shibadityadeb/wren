import Foundation

/// A date found in the user's own words. `phrase` is the exact text it came from.
public struct ParsedDate: Equatable, Sendable {
    public var date: Date
    public var hasTime: Bool
    /// True for ranges like "this weekend" or "next week" where Wren picked a representative day.
    public var isApproximate: Bool
    public var phrase: String
}

/// Deterministic English date/time reader. It only resolves what is literally written;
/// it never guesses a date that isn't in the text. Numeric dates like 10/11 are
/// deliberately unsupported because day/month order is ambiguous.
public struct DateParser: Sendable {
    public var calendar: Calendar
    public init(calendar: Calendar = .current) { self.calendar = calendar }

    static let weekdays: [(String, Int)] = [
        ("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4), ("thursday", 5), ("friday", 6), ("saturday", 7),
        ("sun", 1), ("mon", 2), ("tues", 3), ("tue", 3), ("wed", 4), ("thurs", 5), ("thu", 5), ("fri", 6), ("sat", 7),
    ]
    static let months = ["january", "february", "march", "april", "may", "june", "july", "august",
                         "september", "october", "november", "december"]

    public func parse(_ text: String, now: Date) -> ParsedDate? {
        let s = text.lowercased()
        if let rel = relative(s, now: now) { return rel }

        let day = dayPart(s, now: now)
        let time = timePart(s)

        switch (day, time) {
        case let (d?, t0?):
            var t = t0
            // "tonight at 8" / "tomorrow evening at 7": the part of day decides am/pm.
            if !t.meridiemKnown, let implied = d.impliedHour, implied >= 12, t.hour < 12 { t.hour += 12 }
            guard let date = calendar.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: d.date) else { return nil }
            return ParsedDate(date: date, hasTime: true, isApproximate: d.approx, phrase: joinPhrases(s, d.range, t.range))
        case let (d?, nil):
            let start = calendar.startOfDay(for: d.date)
            if let h = d.impliedHour, let date = calendar.date(bySettingHour: h, minute: 0, second: 0, of: start) {
                return ParsedDate(date: date, hasTime: true, isApproximate: d.approx, phrase: String(s[d.range]))
            }
            return ParsedDate(date: start, hasTime: false, isApproximate: d.approx, phrase: String(s[d.range]))
        case let (nil, t?):
            // Time only: the next occurrence. "at 9" without am/pm picks whichever of 9:00/21:00 comes next.
            let today = calendar.startOfDay(for: now)
            var candidates: [Date] = []
            let hours = (t.meridiemKnown || t.hour == 0 || t.hour >= 12) ? [t.hour] : [t.hour, t.hour + 12]
            for dayOffset in 0...1 {
                guard let base = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
                for h in hours {
                    if let c = calendar.date(bySettingHour: h, minute: t.minute, second: 0, of: base), c > now { candidates.append(c) }
                }
            }
            guard let date = candidates.min() else { return nil }
            return ParsedDate(date: date, hasTime: true, isApproximate: !t.meridiemKnown, phrase: String(s[t.range]))
        default:
            return nil
        }
    }

    // MARK: "in 20 minutes", "in 2 hours", "in 3 days"

    private func relative(_ s: String, now: Date) -> ParsedDate? {
        let re = /\bin\s+(\d{1,3}|an?|one|two|three)\s*(minutes?|mins?|hours?|hrs?|days?|weeks?)\b/
        guard let m = s.firstMatch(of: re) else { return nil }
        let words = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3]
        let n = Int(m.1) ?? words[String(m.1)] ?? 1
        let unit = String(m.2)
        let phrase = String(s[m.range])
        if unit.hasPrefix("min") { return ParsedDate(date: now.addingTimeInterval(Double(n) * 60), hasTime: true, isApproximate: false, phrase: phrase) }
        if unit.hasPrefix("h") { return ParsedDate(date: now.addingTimeInterval(Double(n) * 3600), hasTime: true, isApproximate: false, phrase: phrase) }
        let days = unit.hasPrefix("w") ? n * 7 : n
        guard let d = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) else { return nil }
        return ParsedDate(date: d, hasTime: false, isApproximate: false, phrase: phrase)
    }

    // MARK: Day references

    struct DayHit { var date: Date; var range: Range<String.Index>; var approx: Bool; var impliedHour: Int? }

    private func dayPart(_ s: String, now: Date) -> DayHit? {
        let today = calendar.startOfDay(for: now)
        func plus(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: today)! }

        if let m = s.firstMatch(of: /\b(tomorrow|tmrw|tmr)(\s+(morning|afternoon|evening|night))?\b/) {
            let hour = m.3.map { Self.partOfDayHour(String($0)) }
            return DayHit(date: plus(1), range: m.range, approx: false, impliedHour: hour)
        }
        if let m = s.firstMatch(of: /\b(tonight|this evening)\b/) {
            return DayHit(date: today, range: m.range, approx: false, impliedHour: 20)
        }
        if let m = s.firstMatch(of: /\bthis (morning|afternoon)\b/) {
            return DayHit(date: today, range: m.range, approx: false, impliedHour: Self.partOfDayHour(String(m.1)))
        }
        if let m = s.firstMatch(of: /\btoday\b/) {
            return DayHit(date: today, range: m.range, approx: false, impliedHour: nil)
        }
        if let m = s.firstMatch(of: /\b(this\s+)?weekend\b/) {
            return DayHit(date: plus(daysUntil(weekday: 7, from: today, allowToday: true)), range: m.range, approx: true, impliedHour: nil)
        }
        if let m = s.firstMatch(of: /\bnext week\b/) {
            return DayHit(date: plus(daysUntil(weekday: 2, from: today, allowToday: false)), range: m.range, approx: true, impliedHour: nil)
        }
        if let m = s.firstMatch(of: /\bend of (the )?month\b/) {
            let comps = calendar.dateComponents([.year, .month], from: today)
            let start = calendar.date(from: comps)!
            let last = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start)!
            return DayHit(date: last, range: m.range, approx: false, impliedHour: nil)
        }
        if let m = s.firstMatch(of: /\bend of (the )?week\b/) {
            return DayHit(date: plus(daysUntil(weekday: 6, from: today, allowToday: true)), range: m.range, approx: true, impliedHour: nil)
        }
        // "15 october", "october 15", "oct 15th"
        for (i, name) in Self.months.enumerated() {
            let short = String(name.prefix(3))
            let pattern = "\\b(?:(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:\(name)|\(short))|(?:\(name)|\(short))\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?)\\b"
            guard let re = try? Regex(pattern), let m = s.firstMatch(of: re) else { continue }
            let dayStr = (m.output[1].substring ?? m.output[2].substring).map(String.init) ?? ""
            guard let dayNum = Int(dayStr), (1...31).contains(dayNum) else { continue }
            var comps = calendar.dateComponents([.year], from: today)
            comps.month = i + 1; comps.day = dayNum
            guard var d = calendar.date(from: comps), calendar.component(.day, from: d) == dayNum else { continue }
            if d < today { d = calendar.date(byAdding: .year, value: 1, to: d)! }
            return DayHit(date: d, range: m.range, approx: false, impliedHour: nil)
        }
        // Weekdays. A weekday equal to today means next week's (test plan P3-15).
        for (name, wd) in Self.weekdays {
            guard let re = try? Regex("\\b(next\\s+|this\\s+|on\\s+|by\\s+)?\(name)\\b"), let m = s.firstMatch(of: re) else { continue }
            return DayHit(date: plus(daysUntil(weekday: wd, from: today, allowToday: false)), range: m.range, approx: false, impliedHour: nil)
        }
        return nil
    }

    private func daysUntil(weekday: Int, from day: Date, allowToday: Bool) -> Int {
        let current = calendar.component(.weekday, from: day)
        var diff = (weekday - current + 7) % 7
        if diff == 0 && !allowToday { diff = 7 }
        return diff
    }

    static func partOfDayHour(_ p: String) -> Int {
        switch p { case "morning": 9; case "afternoon": 14; case "evening": 18; default: 20 }
    }

    // MARK: Times

    struct TimeHit { var hour: Int; var minute: Int; var meridiemKnown: Bool; var range: Range<String.Index> }

    private func timePart(_ s: String) -> TimeHit? {
        if let m = s.firstMatch(of: /\b(noon|midday)\b/) { return TimeHit(hour: 12, minute: 0, meridiemKnown: true, range: m.range) }
        if let m = s.firstMatch(of: /\bmidnight\b/) { return TimeHit(hour: 23, minute: 59, meridiemKnown: true, range: m.range) }
        // 9pm, 9 pm, 9:30pm, 9.30 am
        if let m = s.firstMatch(of: /\b(?:at\s+)?(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)/) {
            guard var h = Int(m.1), (1...12).contains(h) else { return nil }
            let min = m.2.flatMap { Int($0) } ?? 0
            let pm = m.3.hasPrefix("p")
            if pm && h != 12 { h += 12 }
            if !pm && h == 12 { h = 0 }
            return TimeHit(hour: h, minute: min, meridiemKnown: true, range: m.range)
        }
        // 24h "at 21:30" or "at 9" / "at 9:30" (meridiem unknown below 13)
        if let m = s.firstMatch(of: /\bat\s+(\d{1,2})(?:[:.](\d{2}))?\b/) {
            guard let h = Int(m.1), (0...23).contains(h) else { return nil }
            let min = m.2.flatMap { Int($0) } ?? 0
            guard (0...59).contains(min) else { return nil }
            return TimeHit(hour: h, minute: min, meridiemKnown: h == 0 || h > 12, range: m.range)
        }
        if let m = s.firstMatch(of: /\b(\d{1,2}):(\d{2})\b/) {
            guard let h = Int(m.1), let min = Int(m.2), (0...23).contains(h), (0...59).contains(min) else { return nil }
            return TimeHit(hour: h, minute: min, meridiemKnown: h == 0 || h > 12, range: m.range)
        }
        return nil
    }

    private func joinPhrases(_ s: String, _ a: Range<String.Index>, _ b: Range<String.Index>) -> String {
        let lo = min(a.lowerBound, b.lowerBound), hi = max(a.upperBound, b.upperBound)
        return String(s[lo..<hi])
    }
}
