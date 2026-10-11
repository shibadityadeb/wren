import Foundation

/// Answers and briefing lines built from connector results. Everything shown comes from what the
/// provider returned; email text is quoted as data and never acted on.
public enum ConnectorAnswers {
    public static func email(question: String, query: String, triaged: [EmailTriage], now: Date, calendar: Calendar) -> Answer {
        let wantsAttention = question.lowercased().contains("attention") || question.lowercased().contains("important")
        let shown = wantsAttention ? triaged.filter(\.needsAttention) : triaged
        let lines = shown.prefix(12).map { t in
            var l = "\(t.message.senderName): \(t.message.subject.isEmpty ? "(no subject)" : t.message.subject)"
            l += " · \(DueText.describe(t.message.date, hasTime: false, now: now, calendar: calendar))"
            if !t.reasons.isEmpty { l += " · \(t.explanation)" }
            return AnswerLine(l, recordID: nil, externalURL: t.message.webURL)
        }
        let title = shown.isEmpty ? (wantsAttention ? "Nothing in your mail needs attention right now." : "No matching email.")
                                  : "\(wantsAttention ? "Needs attention" : "Matching email") (\(shown.count))"
        return Answer(title: title, lines: Array(lines),
                      basis: "From Gmail, read-only (search: \(query)). Reasons are Wren's guesses from the subject and preview; nothing was changed in your mailbox.")
    }

    public static func calendar(label: String, events: [CalendarEvent], now: Date, calendar: Calendar) -> Answer {
        Answer(title: events.isEmpty ? "Nothing on your calendar for \(label)." : "\(label.prefix(1).uppercased() + label.dropFirst()): \(events.count) event\(events.count == 1 ? "" : "s")",
               lines: events.map { e in
                   AnswerLine("\(e.timeText(calendar: calendar, now: now)) · \(e.title)\(e.location.map { " · \($0)" } ?? "")\(e.isRecurring ? " · repeats" : "")",
                              recordID: nil, externalURL: e.link)
               },
               basis: "From Google Calendar, read-only, in \(calendar.timeZone.identifier).")
    }

    public static func briefingEmails(_ triaged: [EmailTriage]) -> [String] {
        triaged.filter(\.needsAttention).prefix(5).map { "\($0.message.senderName): \($0.message.subject) (\($0.explanation))" }
    }

    public static func briefingEvents(_ events: [CalendarEvent], now: Date, calendar: Calendar) -> [String] {
        events.prefix(8).map { "\($0.timeText(calendar: calendar, now: now)) \($0.title)" }
    }
}
