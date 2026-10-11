import Foundation

public struct CalendarEvent: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var isRecurring: Bool
    public var link: URL?

    public func timeText(calendar: Calendar, now: Date) -> String {
        if isAllDay { return "\(DueText.describe(start, hasTime: false, now: now, calendar: calendar)), all day" }
        var f = Date.FormatStyle(date: .omitted, time: .shortened); f.timeZone = calendar.timeZone
        return "\(DueText.describe(start, hasTime: false, now: now, calendar: calendar)) \(start.formatted(f))–\(end.formatted(f))"
    }
}

/// Read-only Google Calendar client (scope calendar.readonly). Recurring events are expanded
/// by the API (`singleEvents=true`); times are converted to the Mac's calendar.
public struct GoogleCalendarClient: Sendable {
    public var http: ConnectorHTTP
    public var token: @Sendable () async throws -> String
    static let base = "https://www.googleapis.com/calendar/v3/calendars/primary"

    public init(session: URLSession = .shared, token: @escaping @Sendable () async throws -> String) {
        http = ConnectorHTTP(allowedHosts: ["www.googleapis.com"], session: session)
        self.token = token
    }

    public func accountID() async throws -> String {
        let v = try await http.json(URL(string: Self.base)!, headers: ["Authorization": "Bearer \(try await token())"])
        return v["id"]?.string ?? v["summary"]?.string ?? "primary"
    }

    public func events(from: Date, to: Date, search: String? = nil, calendar: Calendar, limit: Int = 250) async throws -> [CalendarEvent] {
        let iso = ISO8601DateFormatter()
        var out: [CalendarEvent] = [], page: String?
        repeat {
            var c = URLComponents(string: Self.base + "/events")!
            c.queryItems = [.init(name: "timeMin", value: iso.string(from: from)), .init(name: "timeMax", value: iso.string(from: to)),
                            .init(name: "singleEvents", value: "true"), .init(name: "orderBy", value: "startTime"),
                            .init(name: "maxResults", value: "250"), .init(name: "timeZone", value: calendar.timeZone.identifier)]
            if let search, !search.isEmpty { c.queryItems!.append(.init(name: "q", value: search)) }
            if let page { c.queryItems!.append(.init(name: "pageToken", value: page)) }
            let v = try await http.json(c.url!, headers: ["Authorization": "Bearer \(try await token())"])
            out += v["items"]?.array.compactMap { Self.parse($0, calendar: calendar) } ?? []
            page = v["nextPageToken"]?.string
        } while page != nil && out.count < limit
        return Array(out.prefix(limit))
    }

    /// `dateTime` carries an offset; all-day events have a `date` meaning a calendar day in the
    /// user's zone (end date is exclusive). Cancelled instances are skipped.
    public static func parse(_ v: JSONValue, calendar: Calendar) -> CalendarEvent? {
        guard v["status"]?.string != "cancelled", let id = v["id"]?.string else { return nil }
        func time(_ o: JSONValue?) -> (Date, Bool)? {
            if let dt = o?["dateTime"]?.string {
                let f = ISO8601DateFormatter()
                if let d = f.date(from: dt) { return (d, false) }
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return f.date(from: dt).map { ($0, false) }
            }
            if let ds = o?["date"]?.string {
                let p = ds.split(separator: "-").compactMap { Int($0) }
                guard p.count == 3, let d = calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) else { return nil }
                return (d, true)
            }
            return nil
        }
        guard let (start, allDay) = time(v["start"]), let (end, _) = time(v["end"]) else { return nil }
        return CalendarEvent(id: id, title: v["summary"]?.string ?? "(No title)", start: start, end: end, isAllDay: allDay,
                             location: v["location"]?.string, isRecurring: v["recurringEventId"]?.string != nil,
                             link: v["htmlLink"]?.string.flatMap(URL.init(string:)))
    }
}

/// Calendar questions: "what meetings do I have tomorrow?", "today's schedule", "anything on Friday?"
public enum CalendarQuestion {
    public static func isCalendarQuestion(_ text: String) -> Bool {
        text.lowercased().firstMatch(of: /\b(meetings?|calendar|schedule|events?|appointments?|am i free|busy)\b/) != nil
    }

    /// The day range asked about (defaults to today), in the user's calendar.
    public static func range(_ text: String, now: Date, calendar: Calendar) -> (Date, Date, String) {
        let s = text.lowercased()
        let start = calendar.startOfDay(for: now)
        if s.contains("this week") || s.contains("week") {
            return (now, calendar.date(byAdding: .day, value: 7, to: start)!, "the next 7 days")
        }
        if let p = DateParser(calendar: calendar).parse(text, now: now) {
            let d = calendar.startOfDay(for: p.date)
            return (d, calendar.date(byAdding: .day, value: 1, to: d)!, DueText.describe(d, hasTime: false, now: now, calendar: calendar))
        }
        return (start, calendar.date(byAdding: .day, value: 1, to: start)!, "today")
    }
}
