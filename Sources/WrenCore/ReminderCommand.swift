import Foundation

/// When a reminder fires.
public enum ReminderWhen: Equatable, Sendable {
    case once(Date)
    case repeating(RecurrenceRule)
}

/// An explicit "remind me to …" request, read deterministically. It never invents a time:
/// a missing or ambiguous time becomes a question, and a time that has passed is refused.
public enum ReminderCommand: Equatable, Sendable {
    /// Clear request. `explanation` says how the time was read when it wasn't literal
    /// (for example "10:00 AM, your default reminder time").
    case create(title: String, when: ReminderWhen, explanation: String?)
    /// What's missing, as a short question, with the title kept for the follow-up.
    case clarify(title: String, question: String)
    /// The time has already passed.
    case past(title: String, message: String)

    public static let triggers = ["remind me to ", "remind me about ", "remind me that ", "remind me ", "set a reminder to ",
                                  "set a reminder for ", "set reminder to ", "reminder to ", "add a reminder to "]

    /// Strips a leading "Hey Wren," / "Wren," that a voice transcript may still carry.
    public static func stripAddress(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"^(hey|hi|ok|okay)?[\s,]*wren[\s,.:!]+"#, options: [.regularExpression, .caseInsensitive]) { t.removeSubrange(r) }
        return t
    }

    /// The request in the form "remind me …" or "set a reminder for …"; nil when it isn't a request to
    /// be reminded. Reads the outer request only: "Can you make a reminder to …", "Could you remind me
    /// to …", "Don't let me forget to …", "I'd like a reminder about …", "Reminder: …", "Ping me at 5
    /// to …", "Tomorrow at 9, remind me to …". `request` has address and politeness removed already
    /// (`CommandGrammar.request`).
    public static func canonical(_ request: String) -> String? {
        let t = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        // "Remind me what the deadline is" asks Wren to tell, not to schedule.
        if lower.firstMatch(of: /^remind me (?:what|who|where|when|why|how|which|whether|if)\b/) != nil { return nil }
        if triggers.contains(where: { lower.hasPrefix($0) }) { return t }
        let verbs = #"(?:make|create|add|schedule|set|set up|setup|put in|put|give me|new)"#
        let noun = #"\s+(?:me\s+)?(?:a\s+|an\s+)?(?:new\s+)?reminder"#
        let maps: [(String, String)] = [
            ("^" + verbs + noun + #"\s+(?:for me\s+)?(?:to|that)\s+"#, "remind me to "),
            ("^" + verbs + noun + #"\s+(?:for me\s+)?(?:about|of)\s+"#, "remind me about "),
            ("^" + verbs + noun + #"\s+for\s+"#, "set a reminder for "),
            ("^" + verbs + noun + #"\s*[:,\-–]\s*"#, "remind me to "),
            (#"^reminder\s*[:\-–]\s*"#, "remind me to "),
            (#"^(?:don'?t|do not) let me forget\s+to\s+"#, "remind me to "),
            (#"^(?:don'?t|do not) let me forget\s+(?:about\s+)?"#, "remind me about "),
            (#"^(?:i(?:'d| would)? like|i want|i need)\s+(?:a reminder|to be reminded)\s+(?:to|that)\s+"#, "remind me to "),
            (#"^(?:i(?:'d| would)? like|i want|i need)\s+(?:a reminder|to be reminded)\s+(?:about|of)\s+"#, "remind me about "),
            (#"^(?:i(?:'d| would)? like|i want|i need)\s+a reminder\s+for\s+"#, "set a reminder for "),
            (#"^(?:ping|nudge) me\s+"#, "remind me "),
            (#"^(?:notify|alert) me\s+to\s+"#, "remind me to "),
        ]
        for (pattern, replacement) in maps {
            if let r = t.range(of: pattern, options: [.regularExpression, .caseInsensitive]), r.lowerBound == t.startIndex, r.upperBound < t.endIndex {
                return replacement + t[r.upperBound...]
            }
        }
        // "Tomorrow at 9, remind me to call Sam": the time first, then the request.
        if let m = t.firstMatch(of: /^(?i)(.{2,40}?),?\s+remind me\s+(to|about|that)\s+(.+)$/),
           let d = DateParser().parse(String(m.1), now: Date()), d.phrase.count >= m.1.count - 4 {
            return "remind me \(m.2) \(m.3) \(m.1)"
        }
        return nil
    }

    /// nil when the text isn't a reminder request.
    public static func parse(_ raw: String, now: Date, calendar: Calendar = .current, defaultHour: Int = 10) -> ReminderCommand? {
        guard let text = canonical(CommandGrammar.request(stripAddress(raw))) else { return nil }
        let lower = text.lowercased()
        guard let trigger = triggers.first(where: { lower.hasPrefix($0) }) else { return nil }
        let body = String(text.dropFirst(trigger.count))
        let parser = DateParser(calendar: calendar)

        if let found = RecurrenceRule.find(in: body, calendar: calendar) {
            let title = cleanTitle(body, removing: [found.phrase])
            guard !title.isEmpty else { return .clarify(title: "", question: "What should I remind you about?") }
            guard let rule = found.rule else {
                return .clarify(title: title, question: "At what time should I remind you to \(lowerFirst(title))? For example “at 3 PM”.")
            }
            return .create(title: title, when: .repeating(rule), explanation: nil)
        }

        guard let parsed = parser.parse(body, now: now) else {
            let title = cleanTitle(body, removing: [])
            guard !title.isEmpty else { return .clarify(title: "", question: "What should I remind you about?") }
            return .clarify(title: title, question: "When should I remind you to \(lowerFirst(title))? For example “tomorrow at 10 AM” or “in 30 minutes”.")
        }
        let title = cleanTitle(body, removing: [parsed.phrase])
        guard !title.isEmpty else { return .clarify(title: "", question: "What should I remind you about?") }
        if parsed.meridiemAmbiguous {
            let h = calendar.component(.hour, from: parsed.date) % 12
            let m = calendar.component(.minute, from: parsed.date)
            let t = m == 0 ? "\(h == 0 ? 12 : h)" : String(format: "%d:%02d", h == 0 ? 12 : h, m)
            return .clarify(title: title, question: "Is that \(t) AM or \(t) PM?")
        }
        var when = parsed.date
        var explanation: String?
        if !parsed.hasTime {
            guard let d = calendar.date(bySettingHour: defaultHour, minute: 0, second: 0, of: parsed.date) else { return nil }
            when = d
            let t = d.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone))
            explanation = "No time was given, so it's set for \(t), your default reminder time."
        } else if parsed.isApproximate {
            explanation = "“\(parsed.phrase)” is approximate; change it if needed."
        }
        guard when > now else {
            return .past(title: title, message: "\(DueText.describe(when, hasTime: true, now: now, calendar: calendar).capitalizedFirst) has already passed. Say a later time, for example “tomorrow at the same time”.")
        }
        return .create(title: title, when: .once(when), explanation: explanation)
    }

    /// The deadline the user stated in a reminder request ("remind me to submit the form by Friday",
    /// "… before Monday", "… due Thursday"). nil when the time is only when to remind ("tomorrow at 10").
    public static func statedDeadline(_ raw: String, now: Date, calendar: Calendar = .current) -> ParsedDate? {
        guard let text = canonical(CommandGrammar.request(stripAddress(raw))),
              let p = DateParser(calendar: calendar).parse(text, now: now) else { return nil }
        let lower = text.lowercased(), phrase = p.phrase.lowercased()
        if phrase.hasPrefix("by ") || phrase.hasPrefix("before ") { return p }
        guard let r = lower.range(of: phrase) else { return nil }
        return lower[..<r.lowerBound].range(of: #"\b(?:by|before|due|until|no later than)\s*$"#, options: .regularExpression) != nil ? p : nil
    }

    /// The task in the user's words, without the trigger and the date or repeat phrase.
    static func cleanTitle(_ body: String, removing phrases: [String]) -> String {
        var t = body
        for p in phrases where !p.isEmpty {
            if let r = t.range(of: p, options: .caseInsensitive) { t.removeSubrange(r) }
        }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        // "remind me in 30 minutes to stretch" leaves "to stretch".
        if let r = t.range(of: #"^(?:for\s+)?(to|about|that)\s+"#, options: [.regularExpression, .caseInsensitive]) { t.removeSubrange(r) }
        // Connectors left dangling once the date is gone: "call Sam at", "report by", "on".
        while let r = t.range(of: #"\s+(at|on|by|for|in|from|starting|every)$"#, options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(r)
            t = t.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        }
        return t.capitalizedFirst
    }

    static func lowerFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
