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
    /// The message carries a `List-Unsubscribe` header (newsletters, notifications, marketing).
    public var isBulk: Bool?
    /// The Gmail account it belongs to, so "Open in Gmail" opens the right mailbox.
    public var account: String?
    public var unread: Bool { labels.contains("UNREAD") }
    /// In Spam or Trash: never part of triage, digests or alerts.
    public var isSpamOrTrash: Bool { labels.contains("SPAM") || labels.contains("TRASH") }
    public var senderName: String {
        if let r = from.range(of: "<") { return from[..<r.lowerBound].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        return from
    }
    public var senderAddress: String {
        if let a = from.range(of: "<"), let b = from.range(of: ">", range: a.upperBound..<from.endIndex) { return from[a.upperBound..<b.lowerBound].lowercased() }
        return from.trimmingCharacters(in: .whitespaces).lowercased()
    }
    /// Opens this message's conversation in Gmail on the web, in the right account when known.
    public var webURL: URL {
        var c = URLComponents(string: "https://mail.google.com/mail/")!
        c.queryItems = [URLQueryItem(name: "authuser", value: account ?? "0")]
        // Gmail's web client opens a conversation by its (hex) thread ID under #all.
        let fragmentID = threadId.isEmpty ? id : threadId
        return URL(string: c.url!.absoluteString + "#all/" + (fragmentID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? fragmentID))!
    }

    public init(id: String, threadId: String, from: String, to: String, subject: String, date: Date, snippet: String, labels: [String],
                isBulk: Bool? = nil, account: String? = nil) {
        self.id = id; self.threadId = threadId; self.from = from; self.to = to; self.subject = subject; self.date = date
        self.snippet = snippet; self.labels = labels; self.isBulk = isBulk; self.account = account
    }
}

/// The only Gmail change Wren implements. Even when Google granted `gmail.modify` (which at the
/// OAuth level allows much more), Wren's client exposes nothing else: no send, delete, archive,
/// trash, label or filter calls exist in this code.
public enum GmailAllowedAction: String, CaseIterable, Sendable {
    case markRead

    /// The exact `messages.modify` body for the action.
    public var modifyBody: JSONValue {
        switch self {
        case .markRead: .object(["removeLabelIds": .array([.string("UNREAD")])])
        }
    }
}

public enum GmailSyncError: Error, Equatable, LocalizedError {
    /// The stored history cursor is too old or invalid (HTTP 404): a full sync is needed.
    case historyExpired
    public var errorDescription: String? { "Gmail's change history for Wren expired; Wren is re-reading your inbox." }
}

/// One page of changes since a history ID.
public struct GmailHistory: Equatable, Sendable {
    public var added: [String] = []
    /// message ID → labels added / removed (UNREAD, INBOX, SPAM, TRASH …).
    public var labelsAdded: [String: Set<String>] = [:]
    public var labelsRemoved: [String: Set<String>] = [:]
    public var deleted: Set<String> = []
    public var historyID: String
}

/// What Wren's mail features need from Gmail (the live client, or a fake in tests).
public protocol GmailAPI: Sendable {
    func profile() async throws -> (email: String, historyID: String)
    func inboxMessageIDs(query: String, limit: Int) async throws -> [String]
    func history(since: String) async throws -> GmailHistory
    func metadata(_ id: String) async throws -> EmailMessage
    /// Performs one allowlisted change and returns the message's labels as Gmail reports them afterwards.
    func perform(_ action: GmailAllowedAction, on id: String) async throws -> [String]
}

/// Gmail client. Reads headers, labels and Gmail's snippet (never full bodies or attachments).
/// The only write is `perform(_:on:)`, limited to `GmailAllowedAction` (mark as read).
public struct GmailClient: GmailAPI, Sendable {
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
        guard Self.isValidID(id) else { throw ConnectorError.badResponse("message id") }
        let v = try await get("/messages/\(id)", ["format=metadata", "metadataHeaders=From", "metadataHeaders=To", "metadataHeaders=Subject",
                                                  "metadataHeaders=Date", "metadataHeaders=List-Unsubscribe"]
            .map { let p = $0.split(separator: "="); return URLQueryItem(name: String(p[0]), value: String(p[1])) })
        return Self.parse(v)
    }

    /// Fetches metadata for several messages, a few at a time (not one after another).
    public func messages(ids: [String], concurrency: Int = 6) async throws -> [EmailMessage] {
        var out: [EmailMessage] = []
        var index = 0
        while index < ids.count {
            let batch = ids[index..<min(ids.count, index + concurrency)]
            index += batch.count
            try await withThrowingTaskGroup(of: EmailMessage?.self) { g in
                for id in batch {
                    g.addTask {
                        do { return try await message(id) } catch ConnectorError.http(404, _) { return nil }   // deleted meanwhile
                    }
                }
                for try await m in g { if let m { out.append(m) } }
            }
        }
        return out
    }

    public func messages(matching q: String, limit: Int = 25) async throws -> [EmailMessage] {
        // Gmail's search leaves out Spam and Trash unless asked; Wren also drops them explicitly.
        try await messages(ids: try await search(q, limit: limit)).filter { !$0.isSpamOrTrash }.sorted { $0.date > $1.date }
    }

    static func isValidID(_ id: String) -> Bool { !id.isEmpty && id.count <= 64 && id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil }

    /// Inbox only: the INBOX label excludes Spam and Trash by definition.
    public func inboxMessageIDs(query: String, limit: Int) async throws -> [String] {
        var ids: [String] = [], page: String?
        repeat {
            var items = [URLQueryItem(name: "labelIds", value: "INBOX"), URLQueryItem(name: "includeSpamTrash", value: "false"),
                         URLQueryItem(name: "maxResults", value: String(min(100, limit - ids.count)))]
            if !query.isEmpty { items.append(.init(name: "q", value: query)) }
            if let page { items.append(.init(name: "pageToken", value: page)) }
            let v = try await get("/messages", items)
            ids += v["messages"]?.array.compactMap { $0["id"]?.string } ?? []
            page = v["nextPageToken"]?.string
        } while page != nil && ids.count < limit
        return Array(ids.prefix(limit))
    }

    public func profile() async throws -> (email: String, historyID: String) {
        let v = try await get("/profile")
        guard let e = v["emailAddress"]?.string, let h = v["historyId"]?.string else { throw ConnectorError.badResponse("profile") }
        return (e, h)
    }

    /// Changes since `since` (users.history.list). A 404 means the cursor expired.
    public func history(since: String) async throws -> GmailHistory {
        var out = GmailHistory(historyID: since), page: String?
        repeat {
            var items = [URLQueryItem(name: "startHistoryId", value: since), URLQueryItem(name: "maxResults", value: "500")]
            for t in ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"] { items.append(.init(name: "historyTypes", value: t)) }
            if let page { items.append(.init(name: "pageToken", value: page)) }
            let v: JSONValue
            do { v = try await get("/history", items) } catch ConnectorError.http(404, _) { throw GmailSyncError.historyExpired }
            Self.apply(v, to: &out)
            page = v["nextPageToken"]?.string
        } while page != nil
        return out
    }

    static func apply(_ v: JSONValue, to out: inout GmailHistory) {
        for h in v["history"]?.array ?? [] {
            for a in h["messagesAdded"]?.array ?? [] {
                guard let id = a["message"]?["id"]?.string else { continue }
                let labels = a["message"]?["labelIds"]?.array.compactMap(\.string) ?? []
                if labels.contains("INBOX"), !labels.contains("SPAM"), !labels.contains("TRASH"), !out.added.contains(id) { out.added.append(id) }
            }
            for d in h["messagesDeleted"]?.array ?? [] { if let id = d["message"]?["id"]?.string { out.deleted.insert(id) } }
            for a in h["labelsAdded"]?.array ?? [] {
                guard let id = a["message"]?["id"]?.string else { continue }
                out.labelsAdded[id, default: []].formUnion(a["labelIds"]?.array.compactMap(\.string) ?? [])
            }
            for r in h["labelsRemoved"]?.array ?? [] {
                guard let id = r["message"]?["id"]?.string else { continue }
                out.labelsRemoved[id, default: []].formUnion(r["labelIds"]?.array.compactMap(\.string) ?? [])
            }
        }
        if let id = v["historyId"]?.string { out.historyID = id }
    }

    public func metadata(_ id: String) async throws -> EmailMessage { try await message(id) }

    /// The single allowlisted write. Gmail returns the message's labels after the change.
    public func perform(_ action: GmailAllowedAction, on id: String) async throws -> [String] {
        guard Self.isValidID(id) else { throw ConnectorError.badResponse("message id") }
        let url = URL(string: Self.base + "/messages/\(id)/modify")!
        let v = try await http.json(url, method: "POST", headers: ["Authorization": "Bearer \(try await token())"], body: action.modifyBody)
        guard let labels = v["labelIds"]?.array.compactMap(\.string) ?? (v["id"] != nil ? [] : nil) else { throw ConnectorError.badResponse("modify") }
        return labels
    }

    static func parse(_ v: JSONValue) -> EmailMessage {
        let headers = v["payload"]?["headers"]?.array ?? []
        func h(_ n: String) -> String { headers.first { $0["name"]?.string?.lowercased() == n.lowercased() }?["value"]?.string ?? "" }
        let ms = Double(v["internalDate"]?.string ?? "") ?? 0
        return EmailMessage(id: v["id"]?.string ?? "", threadId: v["threadId"]?.string ?? "", from: h("From"), to: h("To"),
                            subject: h("Subject"), date: Date(timeIntervalSince1970: ms / 1000),
                            snippet: decodeEntities(v["snippet"]?.string ?? ""), labels: v["labelIds"]?.array.compactMap(\.string) ?? [],
                            isBulk: !h("List-Unsubscribe").isEmpty)
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
