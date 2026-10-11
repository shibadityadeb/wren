import Foundation

/// Wren's public Notion integration, registered by Wren's maintainers. Notion's token endpoint needs
/// the integration's client secret, which must never ship in the app, so the code exchange, refresh and
/// revocation go through a small relay the maintainers run (`services/notion-oauth-relay`). The relay
/// holds the secret, stores nothing, and forwards Notion's redirect to Wren's loopback listener.
public struct NotionOAuthConfig: Equatable, Sendable {
    public var clientID: String
    /// Base URL of the maintainers' relay (HTTPS).
    public var relay: URL

    public init(clientID: String, relay: URL) { self.clientID = clientID; self.relay = relay }

    public var isPlausible: Bool {
        relay.scheme == "https" && (relay.host?.contains(".") ?? false) && relay.query == nil
            && clientID.count >= 8 && clientID.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil
    }
    /// The redirect URI registered with Notion: the relay's callback, which bounces to 127.0.0.1.
    public var redirectURI: URL { relay.appendingPathComponent("notion/callback") }
}

/// What Wren keeps (in the Keychain) after the user authorizes Wren in Notion.
public struct NotionTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var botID: String?
    public var workspaceID: String?
    public var workspaceName: String?
    public var ownerName: String?
}

public struct NotionOAuth: Sendable {
    public static let authorizeURL = URL(string: "https://api.notion.com/v1/oauth/authorize")!
    public static let callbackPath = "/notion/callback"
    public var config: NotionOAuthConfig
    public var http: ConnectorHTTP
    public var now: @Sendable () -> Date

    public init(config: NotionOAuthConfig, session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        http = ConnectorHTTP(allowedHosts: [config.relay.host?.lowercased() ?? ""], session: session)
        self.now = now
    }

    /// `state` carries the loopback port so the relay knows where to send the browser back, plus a
    /// random part that Wren checks. Nothing else in it is trusted.
    public static func makeState(port: UInt16) -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "\(port).\(PKCE.base64url(Data(bytes)))"
    }

    public func authorizationURL(state: String) -> URL {
        var c = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "owner", value: "user"),
            .init(name: "redirect_uri", value: config.redirectURI.absoluteString),
            .init(name: "state", value: state),
        ]
        return c.url!
    }

    func post(_ path: String, _ body: [String: JSONValue]) async throws -> JSONValue {
        do {
            return try await http.json(config.relay.appendingPathComponent(path), method: "POST", body: .object(body))
        } catch let ConnectorError.http(400, m) where m.contains("invalid_grant") {
            throw ConnectorError.unauthorized
        } catch let ConnectorError.http(_, m) where m.contains("invalid_client") {
            throw OAuthError.invalidClient
        } catch ConnectorError.unauthorized {
            // The relay answers 401 only when Notion rejected the integration's own credentials.
            throw OAuthError.invalidClient
        } catch let ConnectorError.http(404, _) {
            throw ConnectorError.notConfigured("Wren's Notion sign-in service isn't answering correctly. That's a problem on Wren's side, not your account; try again later.")
        }
    }

    func tokens(_ v: JSONValue, previous: NotionTokens? = nil) throws -> NotionTokens {
        guard let access = v["access_token"]?.string, !access.isEmpty else { throw ConnectorError.badResponse("Notion didn't return an access token") }
        return NotionTokens(accessToken: access,
                            refreshToken: v["refresh_token"]?.string ?? previous?.refreshToken,
                            expiresAt: v["expires_in"]?.number.map { now().addingTimeInterval($0) },
                            botID: v["bot_id"]?.string ?? previous?.botID,
                            workspaceID: v["workspace_id"]?.string ?? previous?.workspaceID,
                            workspaceName: v["workspace_name"]?.string ?? previous?.workspaceName,
                            ownerName: v["owner_name"]?.string ?? previous?.ownerName)
    }

    public func exchange(code: String) async throws -> NotionTokens {
        try tokens(try await post("notion/token", ["code": .string(code), "redirect_uri": .string(config.redirectURI.absoluteString)]))
    }

    public func refresh(_ t: NotionTokens) async throws -> NotionTokens {
        guard let rt = t.refreshToken else { throw ConnectorError.unauthorized }
        return try tokens(try await post("notion/refresh", ["refresh_token": .string(rt)]), previous: t)
    }

    /// Asks Notion (through the relay) to revoke the token. Throws if that couldn't be confirmed.
    public func revoke(_ token: String) async throws {
        _ = try await post("notion/revoke", ["token": .string(token)])
    }
}

/// Holds the Notion tokens and hands out a valid access token, refreshing when Notion set an expiry.
public final class NotionSession: @unchecked Sendable {
    public static let key = "notion.oauth"
    /// Where an earlier development build kept a pasted integration token. Only read to delete it.
    public static let legacyTokenKey = "notion.token"
    let store: CredentialStore
    public init(store: CredentialStore) { self.store = store }
    public var tokens: NotionTokens? { store.readJSON(Self.key, as: NotionTokens.self) }
    public func save(_ t: NotionTokens) throws { try store.writeJSON(Self.key, t) }
    public func clear() throws { try store.delete(Self.key) }

    public func accessToken(oauth: NotionOAuth?) async throws -> String {
        guard var t = tokens else { throw ConnectorError.notConfigured("Notion isn't connected.") }
        if let exp = t.expiresAt, let oauth, exp.timeIntervalSince(oauth.now()) < 60 {
            t = try await oauth.refresh(t)
            try save(t)
        }
        return t.accessToken
    }
}
