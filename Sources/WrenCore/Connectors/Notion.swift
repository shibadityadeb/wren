import Foundation

public struct NotionPage: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var url: URL?
    public var lastEdited: Date?
}

public struct NotionBlock: Equatable, Sendable {
    public var type: String
    public var text: String
    public var supported: Bool
    public var depth: Int
}

/// Notion API (version 2026-03-11) with the OAuth access token of Wren's public integration. Sees only
/// the pages the user picked on Notion's consent screen. Retries once on rate limiting.
public struct NotionClient: Sendable {
    public static let version = "2026-03-11"
    public var http: ConnectorHTTP
    public var token: @Sendable () async throws -> String
    public var maxWait: TimeInterval = 10
    static let base = "https://api.notion.com/v1"

    public init(session: URLSession = .shared, token: @escaping @Sendable () async throws -> String) {
        http = ConnectorHTTP(allowedHosts: ["api.notion.com"], session: session)
        self.token = token
    }

    func call(_ path: String, method: String = "GET", body: JSONValue? = nil, query: [URLQueryItem] = []) async throws -> JSONValue {
        var c = URLComponents(string: Self.base + path)!
        if !query.isEmpty { c.queryItems = query }
        let headers = ["Authorization": "Bearer \(try await token())", "Notion-Version": Self.version]
        do { return try await http.json(c.url!, method: method, headers: headers, body: body) } catch let ConnectorError.rateLimited(r) {
            try await Task.sleep(nanoseconds: UInt64(min(r ?? 1, maxWait) * 1_000_000_000))
            return try await http.json(c.url!, method: method, headers: headers, body: body)
        }
    }

    /// Workspace name and integration name for display.
    public func identity() async throws -> String {
        let v = try await call("/users/me")
        let ws = v["bot"]?["workspace_name"]?.string
        let name = v["name"]?.string
        return [ws, name.map { "integration “\($0)”" }].compactMap { $0 }.joined(separator: " · ")
    }

    public func searchPages(_ query: String, limit: Int = 20) async throws -> [NotionPage] {
        var out: [NotionPage] = [], cursor: String?
        repeat {
            var body: [String: JSONValue] = ["query": .string(query), "page_size": .number(Double(min(100, limit))),
                                             "filter": .object(["property": .string("object"), "value": .string("page")])]
            if let cursor { body["start_cursor"] = .string(cursor) }
            let v = try await call("/search", method: "POST", body: .object(body))
            out += v["results"]?.array.compactMap(Self.page) ?? []
            cursor = v["has_more"]?.bool == true ? v["next_cursor"]?.string : nil
        } while cursor != nil && out.count < limit
        return Array(out.prefix(limit))
    }

    static func page(_ v: JSONValue) -> NotionPage? {
        guard let id = v["id"]?.string, v["in_trash"]?.bool != true else { return nil }
        var title = "Untitled"
        if case let .object(props)? = v["properties"] {
            for (_, p) in props where p["type"]?.string == "title" {
                let t = p["title"]?.array.compactMap { $0["plain_text"]?.string }.joined() ?? ""
                if !t.isEmpty { title = t }
            }
        }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return NotionPage(id: id, title: title, url: v["url"]?.string.flatMap(URL.init(string:)),
                          lastEdited: v["last_edited_time"]?.string.flatMap { f.date(from: $0) })
    }

    static let textTypes: Set<String> = ["paragraph", "heading_1", "heading_2", "heading_3", "bulleted_list_item", "numbered_list_item",
                                         "to_do", "quote", "callout", "toggle", "code"]

    /// Readable blocks of a page (two levels deep). Unsupported blocks are kept as markers, never dropped silently.
    public func blocks(_ pageID: String, depth: Int = 0, limit: Int = 300) async throws -> [NotionBlock] {
        var out: [NotionBlock] = [], cursor: String?
        repeat {
            var q = [URLQueryItem(name: "page_size", value: "100")]
            if let cursor { q.append(.init(name: "start_cursor", value: cursor)) }
            let v = try await call("/blocks/\(pageID)/children", query: q)
            for b in v["results"]?.array ?? [] {
                out.append(Self.block(b, depth: depth))
                if b["has_children"]?.bool == true, depth < 1, let id = b["id"]?.string, out.count < limit {
                    out += try await blocks(id, depth: depth + 1, limit: limit - out.count)
                }
            }
            cursor = v["has_more"]?.bool == true ? v["next_cursor"]?.string : nil
        } while cursor != nil && out.count < limit
        return Array(out.prefix(limit))
    }

    static func block(_ b: JSONValue, depth: Int) -> NotionBlock {
        let type = b["type"]?.string ?? "unknown"
        if type == "divider" { return NotionBlock(type: type, text: "---", supported: true, depth: depth) }
        guard textTypes.contains(type) else { return NotionBlock(type: type, text: "[\(type) block not shown]", supported: false, depth: depth) }
        var text = b[type]?["rich_text"]?.array.compactMap { $0["plain_text"]?.string }.joined() ?? ""
        switch type {
        case "heading_1": text = "# " + text
        case "heading_2": text = "## " + text
        case "heading_3": text = "### " + text
        case "bulleted_list_item", "numbered_list_item": text = "- " + text
        case "to_do": text = (b[type]?["checked"]?.bool == true ? "[x] " : "[ ] ") + text
        case "quote": text = "> " + text
        default: break
        }
        return NotionBlock(type: type, text: text, supported: true, depth: depth)
    }

    public static func plainText(_ blocks: [NotionBlock]) -> String {
        blocks.map { String(repeating: "  ", count: $0.depth) + $0.text }.joined(separator: "\n")
    }

    /// Creates a page under a parent page the integration can access. Called only after confirmation.
    public func createPage(parentID: String, title: String, body: String) async throws -> NotionPage {
        let paragraphs: [JSONValue] = body.split(separator: "\n", omittingEmptySubsequences: true).prefix(90).map { line in
            .object(["object": .string("block"), "type": .string("paragraph"),
                     "paragraph": .object(["rich_text": .array([.object(["type": .string("text"), "text": .object(["content": .string(String(line.prefix(1900)))])])])])])
        }
        let v = try await call("/pages", method: "POST", body: .object([
            "parent": .object(["page_id": .string(parentID)]),
            "properties": .object(["title": .object(["title": .array([.object(["text": .object(["content": .string(String(title.prefix(200)))])])])])]),
            "children": .array(paragraphs),
        ]))
        guard let p = Self.page(v) else { throw ConnectorError.badResponse("page not returned") }
        return p
    }
}
