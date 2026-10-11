import Foundation

/// Notion through Notion's hosted MCP server (`https://mcp.notion.com/mcp`). Wren registers itself
/// on first sign-in (OAuth dynamic client registration, RFC 7591) as a public client with PKCE, so
/// there's no Notion integration to create, no client secret, and no server of Wren's own. The user
/// signs in and chooses access on Notion's normal OAuth page.
public enum NotionMCP {
    public static let issuer = "https://mcp.notion.com"
    public static let resource = "https://mcp.notion.com/mcp"
    public static let endpoint = URL(string: "https://mcp.notion.com/mcp")!
    public static let callbackPath = "/notion/callback"
    public static let protocolVersion = "2025-06-18"
}

/// What Wren keeps after the user connects Notion (in its private credentials file).
public struct NotionMCPConnection: Codable, Equatable, Sendable {
    /// Issued to this copy of Wren at registration; bound to `redirectURI`.
    public var clientID: String
    public var redirectURI: String
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var workspace: String?
    public var user: String?
    public var savedAt: Date
}

public struct NotionMCPMetadata: Equatable, Sendable {
    public var authorization: URL
    public var token: URL
    public var registration: URL
    public var revocation: URL?

    public static func parse(_ v: JSONValue) throws -> NotionMCPMetadata {
        guard v["issuer"]?.string == NotionMCP.issuer else { throw ConnectorError.badResponse("Notion sign-in configuration") }
        func url(_ k: String) -> URL? {
            guard let s = v[k]?.string, let u = URL(string: s), u.scheme == "https", u.host == "mcp.notion.com" else { return nil }
            return u
        }
        guard let a = url("authorization_endpoint"), let t = url("token_endpoint"), let r = url("registration_endpoint") else {
            throw ConnectorError.badResponse("Notion sign-in configuration")
        }
        return NotionMCPMetadata(authorization: a, token: t, registration: r, revocation: url("revocation_endpoint"))
    }
}

/// OAuth with Notion's MCP authorization server.
public struct NotionMCPAuth: Sendable {
    public var http: ConnectorHTTP
    public var now: @Sendable () -> Date

    public init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        var h = ConnectorHTTP(allowedHosts: ["mcp.notion.com"], session: session)
        h.timeout = 20
        http = h
        self.now = now
    }

    public func metadata() async throws -> NotionMCPMetadata {
        try NotionMCPMetadata.parse(try await http.json(URL(string: NotionMCP.issuer + "/.well-known/oauth-authorization-server")!))
    }

    /// Registers Wren for this exact loopback redirect and returns the issued client ID.
    public func register(_ m: NotionMCPMetadata, redirect: URL) async throws -> String {
        let body: JSONValue = .object([
            "client_name": .string("Wren"),
            "redirect_uris": .array([.string(redirect.absoluteString)]),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]),
            "token_endpoint_auth_method": .string("none"),
        ])
        let v = try await http.json(m.registration, method: "POST", body: body)
        guard let id = v["client_id"]?.string, !id.isEmpty else { throw ConnectorError.badResponse("Notion didn't register Wren") }
        return id
    }

    public static func authorizationURL(_ m: NotionMCPMetadata, clientID: String, redirect: URL, state: String, pkce: PKCE) -> URL {
        var c = URLComponents(url: m.authorization, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect.absoluteString),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "scope", value: "default"),
            .init(name: "resource", value: NotionMCP.resource),
        ]
        return c.url!
    }

    /// Checks state (and the issuer, when Notion includes it) and returns the code.
    public static func parseCallback(_ url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ k: String) -> String? { items.first { $0.name == k }?.value }
        guard items.filter({ $0.name == "state" }).count == 1, v("state") == expectedState else { throw OAuthError.stateMismatch }
        if let iss = v("iss"), iss != NotionMCP.issuer { throw OAuthError.providerError("unexpected issuer") }
        if let e = v("error") { throw e == "access_denied" ? OAuthError.denied : OAuthError.providerError(e) }
        guard let code = v("code"), !code.isEmpty else { throw OAuthError.missingCode }
        return code
    }

    func tokenRequest(_ m: NotionMCPMetadata, _ pairs: [(String, String)]) async throws -> JSONValue {
        let (data, resp) = try await http.raw(m.token, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
                                              body: GoogleOAuth.form(pairs))
        guard (200..<300).contains(resp.statusCode) else {
            let code = ChatGPTError.errorCode(data)
            if code == "invalid_grant" || resp.statusCode == 401 { throw ConnectorError.unauthorized }
            if code == "invalid_client" { throw ConnectorError.unauthorized }
            if resp.statusCode >= 500 { throw ConnectorError.server(resp.statusCode) }
            throw ConnectorError.http(resp.statusCode, code ?? "token request refused")
        }
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw ConnectorError.badResponse("token response") }
        return v
    }

    func connection(_ v: JSONValue, clientID: String, redirect: String, previous: NotionMCPConnection?) throws -> NotionMCPConnection {
        guard let access = v["access_token"]?.string, !access.isEmpty else { throw ConnectorError.badResponse("Notion didn't return an access token") }
        return NotionMCPConnection(clientID: clientID, redirectURI: redirect, accessToken: access,
                                   refreshToken: v["refresh_token"]?.string ?? previous?.refreshToken,
                                   expiresAt: v["expires_in"]?.number.map { now().addingTimeInterval($0) },
                                   workspace: previous?.workspace, user: previous?.user, savedAt: now())
    }

    public func exchange(_ m: NotionMCPMetadata, code: String, clientID: String, redirect: URL, pkce: PKCE) async throws -> NotionMCPConnection {
        let v = try await tokenRequest(m, [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirect.absoluteString),
                                           ("client_id", clientID), ("code_verifier", pkce.verifier), ("resource", NotionMCP.resource)])
        return try connection(v, clientID: clientID, redirect: redirect.absoluteString, previous: nil)
    }

    public func refresh(_ c: NotionMCPConnection) async throws -> NotionMCPConnection {
        guard let rt = c.refreshToken else { throw ConnectorError.unauthorized }
        let m = try await metadata()
        let v = try await tokenRequest(m, [("grant_type", "refresh_token"), ("refresh_token", rt), ("client_id", c.clientID), ("resource", NotionMCP.resource)])
        return try connection(v, clientID: c.clientID, redirect: c.redirectURI, previous: c)
    }

    /// True when Notion confirmed the revocation.
    public func revoke(_ c: NotionMCPConnection) async -> Bool {
        guard let m = try? await metadata(), let endpoint = m.revocation else { return false }
        let token = c.refreshToken ?? c.accessToken
        guard let (_, resp) = try? await http.raw(endpoint, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                                  body: GoogleOAuth.form([("token", token), ("token_type_hint", c.refreshToken != nil ? "refresh_token" : "access_token"),
                                                                          ("client_id", c.clientID)])) else { return false }
        return resp.statusCode == 200
    }
}

/// A minimal MCP client over Streamable HTTP (JSON-RPC 2.0; replies as JSON or server-sent events).
public final class MCPClient: @unchecked Sendable {
    let http: ConnectorHTTP
    let endpoint: URL
    /// A valid bearer token; `true` asks for a refreshed one after a 401.
    let token: @Sendable (Bool) async throws -> String
    private let lock = NSLock()
    private var sessionID: String?
    private var nextID = 1

    public init(endpoint: URL = NotionMCP.endpoint, session: URLSession = .shared, token: @escaping @Sendable (Bool) async throws -> String) {
        var h = ConnectorHTTP(allowedHosts: [endpoint.host ?? ""], session: session)
        h.timeout = 60
        http = h; self.endpoint = endpoint; self.token = token
    }

    func newID() -> Int { lock.withLock { defer { nextID += 1 }; return nextID } }

    func post(_ body: JSONValue, bearer: String) async throws -> (Data, HTTPURLResponse) {
        var headers = ["Authorization": "Bearer \(bearer)", "Content-Type": "application/json",
                       "Accept": "application/json, text/event-stream", "MCP-Protocol-Version": NotionMCP.protocolVersion]
        if let s = lock.withLock({ sessionID }) { headers["Mcp-Session-Id"] = s }
        return try await http.raw(endpoint, method: "POST", headers: headers, body: try JSONEncoder().encode(body))
    }

    /// The JSON-RPC reply with this id, from a JSON body or an SSE stream.
    static func reply(_ data: Data, id: Int, contentType: String?) throws -> JSONValue {
        func matches(_ v: JSONValue) -> Bool { v["id"]?.number.map { Int($0) == id } ?? false }
        if contentType?.lowercased().contains("text/event-stream") == true {
            var parser = SSEParser()
            var payloads: [String] = []
            for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") { if let p = parser.feed(line) { payloads.append(p) } }
            if let p = parser.flush() { payloads.append(p) }
            for p in payloads {
                if let v = try? JSONDecoder().decode(JSONValue.self, from: Data(p.utf8)), matches(v) { return v }
            }
            throw ConnectorError.badResponse("no reply in the event stream")
        }
        let v = try JSONDecoder().decode(JSONValue.self, from: data)
        if case let .array(batch) = v, let hit = batch.first(where: matches) { return hit }
        return v
    }

    /// One request, with session setup and a single retry after a refreshed token or an expired session.
    func request(_ method: String, _ params: JSONValue, retried: Bool = false) async throws -> JSONValue {
        try await ensureSession()
        let id = newID()
        let body: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params])
        let (data, resp) = try await post(body, bearer: try await token(retried))
        switch resp.statusCode {
        case 200..<300: break
        case 401 where !retried: return try await request(method, params, retried: true)
        case 401: throw ConnectorError.unauthorized
        case 404 where !retried:
            // The server forgot the session: start a new one.
            lock.withLock { sessionID = nil }
            return try await request(method, params, retried: true)
        case 403: throw ConnectorError.forbidden(ConnectorHTTP.message(data) ?? "forbidden")
        case 429: throw ConnectorError.rateLimited(retryAfter: nil)
        case 500...: throw ConnectorError.server(resp.statusCode)
        default: throw ConnectorError.http(resp.statusCode, ConnectorHTTP.message(data) ?? "")
        }
        let v = try Self.reply(data, id: id, contentType: resp.value(forHTTPHeaderField: "Content-Type"))
        if let e = v["error"], case .object = e { throw ConnectorError.badResponse(e["message"]?.string ?? "Notion returned an error") }
        guard let result = v["result"] else { throw ConnectorError.badResponse("no result") }
        return result
    }

    func ensureSession() async throws {
        if lock.withLock({ sessionID }) != nil { return }
        let id = newID()
        let body: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string("initialize"), "params": .object([
            "protocolVersion": .string(NotionMCP.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("Wren"), "version": .string("0.8")]),
        ])])
        var (data, resp) = try await post(body, bearer: try await token(false))
        if resp.statusCode == 401 { (data, resp) = try await post(body, bearer: try await token(true)) }
        guard (200..<300).contains(resp.statusCode) else {
            throw resp.statusCode == 401 ? ConnectorError.unauthorized : ConnectorError.http(resp.statusCode, "MCP initialize")
        }
        _ = try Self.reply(data, id: id, contentType: resp.value(forHTTPHeaderField: "Content-Type"))
        lock.withLock { sessionID = resp.value(forHTTPHeaderField: "Mcp-Session-Id") ?? "" }
        let note: JSONValue = .object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")])
        _ = try? await post(note, bearer: try await token(false))
    }

    /// Calls a tool and returns its text content. Throws when the tool reports an error.
    public func callTool(_ name: String, _ arguments: [String: JSONValue]) async throws -> String {
        let r = try await request("tools/call", .object(["name": .string(name), "arguments": .object(arguments)]))
        let text = r["content"]?.array.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n") ?? ""
        if r["isError"]?.bool == true { throw ConnectorError.badResponse(String(text.prefix(200))) }
        return text
    }
}

/// Wren's Notion features on top of Notion's MCP tools.
public struct NotionMCPClient: Sendable {
    public let mcp: MCPClient
    public init(mcp: MCPClient) { self.mcp = mcp }

    static func json(_ text: String) -> JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

    /// Every object in a JSON tree that has an id and a title.
    static func pages(in v: JSONValue) -> [NotionPage] {
        var out: [NotionPage] = []
        func walk(_ v: JSONValue) {
            switch v {
            case let .object(o):
                if let id = o["id"]?.string, let title = o["title"]?.string {
                    out.append(NotionPage(id: id, title: title.isEmpty ? "Untitled" : title, url: o["url"]?.string.flatMap(URL.init(string:)),
                                          lastEdited: nil))
                }
                o.values.forEach(walk)
            case let .array(a): a.forEach(walk)
            default: break
            }
        }
        walk(v)
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }

    /// Workspace name for display (and who signed in).
    public func identity() async throws -> (workspace: String?, user: String?) {
        let t = try await mcp.callTool("notion-get-self", [:])
        guard let v = Self.json(t) else { return (nil, nil) }
        return (v["workspace"]?["name"]?.string, v["user"]?["email"]?.string ?? v["user"]?["name"]?.string)
    }

    public func searchPages(_ query: String, limit: Int = 20) async throws -> [NotionPage] {
        let t = try await mcp.callTool("notion-search", ["query": .string(query.isEmpty ? " " : query), "limit": .number(Double(min(limit, 50)))])
        return Array(Self.json(t).map(Self.pages(in:))?.prefix(limit) ?? [])
    }

    /// The page as text (Notion returns it as Markdown).
    public func pageText(_ id: String) async throws -> String {
        let t = try await mcp.callTool("notion-fetch", ["id": .string(id)])
        if let v = Self.json(t) {
            let title = v["title"]?.string.map { "# \($0)\n\n" } ?? ""
            if let content = v["content"]?.string { return title + content }
            if let text = v["text"]?.string { return title + text }
        }
        return t
    }

    public func createPage(parentID: String, title: String, body: String) async throws -> NotionPage {
        let t = try await mcp.callTool("notion-create-pages", [
            "parent": .object(["page_id": .string(parentID)]),
            "pages": .array([.object(["properties": .object(["title": .string(title)]), "content": .string(body)])]),
        ])
        if let v = Self.json(t), let p = Self.pages(in: v).first { return p }
        if let v = Self.json(t), let id = Self.firstID(v) { return NotionPage(id: id, title: title, url: nil, lastEdited: nil) }
        throw ConnectorError.badResponse("Notion didn't confirm the new page")
    }

    static func firstID(_ v: JSONValue) -> String? {
        if let id = v["id"]?.string { return id }
        for x in v["pages"]?.array ?? v.array { if let id = firstID(x) { return id } }
        return nil
    }
}
