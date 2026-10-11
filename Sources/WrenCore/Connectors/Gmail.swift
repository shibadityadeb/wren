import Foundation

public struct EmailMessage: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var threadId: String
    public var from: String
    public var to: String
    public var subject: String
    public var date: Date
    public var snippet: String
    public var labels: [String]
    public var unread: Bool { labels.contains("UNREAD") }
    public var senderName: String {
        if let r = from.range(of: "<") { return from[..<r.lowerBound].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        return from
    }
    public var webURL: URL { URL(string: "https://mail.google.com/mail/u/0/#all/\(threadId)")! }
}

/// Read-only Gmail client (scope gmail.readonly). Fetches headers and snippets, not full bodies.
public struct GmailClient: Sendable {
    public var http: ConnectorHTTP
    public var token: @Sendable () async throws -> String
    static let base = "https://gmail.googleapis.com/gmail/v1/users/me"

    public init(session: URLSession = .shared, token: @escaping @Sendable () async throws -> String) {
        http = ConnectorHTTP(allowedHosts: ["gmail.googleapis.com"], session: session)
        self.token = token
    }

    func get(_ path: String, _ query: [URLQueryItem] = []) async throws -> JSONValue {
        var c = URLComponents(string: Self.base + path)!
        if !query.isEmpty { c.queryItems = query }
        return try await http.json(c.url!, headers: ["Authorization": "Bearer \(try await token())"])
    }

    public func profileEmail() async throws -> String {
        guard let e = try await get("/profile")["emailAddress"]?.string else { throw ConnectorError.badResponse("no emailAddress") }
        return e
    }

    /// Message IDs matching a Gmail search, following pages up to `limit`.
    public func search(_ q: String, limit: Int = 25) async throws -> [String] {
        var ids: [String] = [], page: String?
        repeat {
            var items = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "maxResults", value: String(min(100, limit - ids.count)))]
            if let page { items.append(.init(name: "pageToken", value: page)) }
            let v = try await get("/messages", items)
            ids += v["messages"]?.array.compactMap { $0["id"]?.string } ?? []
            page = v["nextPageToken"]?.string
        } while page != nil && ids.count < limit
        return Array(ids.prefix(limit))
    }

    public func message(_ id: String) async throws -> EmailMessage {
        let v = try await get("/messages/\(id)", ["format=metadata", "metadataHeaders=From", "metadataHeaders=To", "metadataHeaders=Subject", "metadataHeaders=Date"]
            .map { let p = $0.split(separator: "="); return URLQueryItem(name: String(p[0]), value: String(p[1])) })
        return Self.parse(v)
    }

    public func messages(matching q: String, limit: Int = 25) async throws -> [EmailMessage] {
        var out: [EmailMessage] = []
        for id in try await search(q, limit: limit) { out.append(try await message(id)) }
        return out.sorted { $0.date > $1.date }
    }

    static func parse(_ v: JSONValue) -> EmailMessage {
        let headers = v["payload"]?["headers"]?.array ?? []
        func h(_ n: String) -> String { headers.first { $0["name"]?.string?.lowercased() == n.lowercased() }?["value"]?.string ?? "" }
        let ms = Double(v["internalDate"]?.string ?? "") ?? 0
        return EmailMessage(id: v["id"]?.string ?? "", threadId: v["threadId"]?.string ?? "", from: h("From"), to: h("To"),
                            subject: h("Subject"), date: Date(timeIntervalSince1970: ms / 1000),
                            snippet: decodeEntities(v["snippet"]?.string ?? ""), labels: v["labelIds"]?.array.compactMap(\.string) ?? [])
    }

    static func decodeEntities(_ s: String) -> String {
        var t = s
        for (k, r) in [("&#39;", "'"), ("&quot;", "\""), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] { t = t.replacingOccurrences(of: k, with: r) }
        return t
    }
}

/// Why a message might need attention. Deterministic; the message text is data only.
public struct EmailTriage: Sendable, Equatable {
    public enum Reason: String, Sendable, CaseIterable { case request, deadline, bill, interview, security, markedImportant, fromImportantSender }
    public var message: EmailMessage
    public var reasons: [Reason]
    public var deadline: Date?
    public var isLowValue: Bool
    public var needsAttention: Bool { !reasons.isEmpty && !isLowValue || reasons.contains(.security) || reasons.contains(.fromImportantSender) }

    public var explanation: String {
        reasons.map {
            switch $0 {
            case .request: "asks you something"
            case .deadline: "mentions a date"
            case .bill: "looks like a bill or payment"
            case .interview: "about an interview"
            case .security: "security notice"
            case .markedImportant: "Gmail marked it important"
            case .fromImportantSender: "from a sender you marked important"
            }
        }.joined(separator: ", ")
    }

    public static func classify(_ m: EmailMessage, importantSenders: Set<String> = [], now: Date, calendar: Calendar) -> EmailTriage {
        let text = (m.subject + " " + m.snippet).lowercased()
        var r: [Reason] = []
        if text.firstMatch(of: /\b(could you|can you|would you|please|let me know|are you able|need you to|kindly)\b/) != nil || m.subject.hasSuffix("?") { r.append(.request) }
        if text.firstMatch(of: /\b(invoice|payment due|amount due|bill|receipt is due|overdue balance|statement is ready)\b/) != nil { r.append(.bill) }
        if text.firstMatch(of: /\binterview/) != nil { r.append(.interview) }
        if text.firstMatch(of: /\b(security alert|new sign-in|sign-in attempt|verification code|password (was )?(changed|reset)|unusual activity|2-step)\b/) != nil { r.append(.security) }
        var deadline: Date?
        if text.firstMatch(of: /\b(due|deadline|by|before|until)\b/) != nil, let p = DateParser(calendar: calendar).parse(m.subject + " " + m.snippet, now: m.date) {
            deadline = p.date; r.append(.deadline)
        }
        if m.labels.contains("IMPORTANT") { r.append(.markedImportant) }
        let addr = m.from.lowercased()
        if importantSenders.contains(where: { addr.contains($0.lowercased()) }) { r.append(.fromImportantSender) }
        let bulk = m.labels.contains { ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_FORUMS"].contains($0) }
        return EmailTriage(message: m, reasons: r, deadline: deadline, isLowValue: bulk)
    }
}

/// Turns a question into a Gmail search. Only used for questions the user typed.
public enum EmailQuestion {
    public static func isEmailQuestion(_ text: String) -> Bool {
        let s = text.lowercased()
        return s.firstMatch(of: /\b(e-?mails?|mail|inbox|gmail|messages?)\b/) != nil
            || s.firstMatch(of: /^(any(thing)?|did|has|have) .*\b(from|heard)\b/) != nil
            || s.firstMatch(of: /\bneeds? my attention\b/) != nil
    }

    /// "Anything from the recruiter?" → `recruiter newer_than:30d`
    public static func gmailQuery(_ text: String) -> String {
        let s = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "?!. "))
        var parts: [String] = []
        if let m = s.firstMatch(of: /\bfrom (?:the |my |a |an )?([a-z0-9@._ -]{2,40}?)(?:\s+(?:today|yesterday|this week|recently|lately|about .*))?$/) {
            let who = String(m.1).trimmingCharacters(in: .whitespaces)
            parts.append(who.contains("@") ? "from:\(who)" : (who.contains(" ") ? "\"\(who)\"" : who))
        }
        if let m = s.firstMatch(of: /\babout ([a-z0-9 ._-]{2,40})$/) { parts.append("\"\(m.1.trimmingCharacters(in: .whitespaces))\"") }
        if s.contains("unread") { parts.append("is:unread") }
        if s.contains("today") || s.contains("attention") { parts.append("newer_than:1d") }
        else if s.contains("yesterday") { parts.append("newer_than:2d") }
        else if s.contains("this week") { parts.append("newer_than:7d") }
        else { parts.append("newer_than:30d") }
        if s.contains("attention") || s.contains("important") { parts.append("-category:promotions -category:social") }
        return parts.joined(separator: " ")
    }
}

/// Optional on-disk cache of headers and snippets (off by default), pruned to `days`.
public struct EmailCache: Sendable {
    public let url: URL
    public var days = 7
    public init(directory: URL) { url = directory.appendingPathComponent("Cache/gmail.json") }

    public func save(_ ms: [EmailMessage], now: Date) throws {
        let keep = (load() + ms).reduce(into: [String: EmailMessage]()) { $0[$1.id] = $1 }.values
            .filter { now.timeIntervalSince($0.date) < Double(days) * 86400 }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try e.encode(Array(keep)).write(to: url, options: [.atomic, .completeFileProtection])
    }
    public func load() -> [EmailMessage] {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? d.decode([EmailMessage].self, from: $0) } ?? []
    }
    public func clear() { try? FileManager.default.removeItem(at: url) }
}
