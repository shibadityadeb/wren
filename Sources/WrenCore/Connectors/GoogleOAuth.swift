import CryptoKit
import Foundation
import Network

/// Wren's Google OAuth client (type "Desktop app"), registered by Wren's maintainers and injected into
/// the app bundle at build time (see `ProviderConfig`). Never entered by a user and never committed.
/// Google treats a desktop client's secret as non-confidential, but its token endpoint still expects
/// it for that client type.
public struct GoogleOAuthConfig: Codable, Equatable, Sendable {
    public var clientID: String
    public var clientSecret: String?
    public init(clientID: String, clientSecret: String?) { self.clientID = clientID; self.clientSecret = clientSecret }
    public var isPlausible: Bool { clientID.hasSuffix(".apps.googleusercontent.com") && clientID.count > 40 }
}

public struct OAuthTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String
    public var account: String?
}

public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public static func make() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64url(Data(bytes))
        return PKCE(verifier: verifier, challenge: challenge(for: verifier))
    }
    public static func challenge(for verifier: String) -> String { base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public enum OAuthError: Error, Equatable, LocalizedError {
    case denied
    case stateMismatch
    case missingCode
    case providerError(String)
    case scopeNotGranted(String)
    case noRefreshToken
    case invalidClient
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .denied: "Access wasn't granted on the consent screen. You can connect again whenever you're ready."
        case .stateMismatch: "The sign-in response didn't match this request, so it was ignored."
        case .missingCode: "The sign-in page didn't return an authorization code. Try connecting again."
        case let .providerError(e): "Sign-in failed (\(e)). Try connecting again."
        case let .scopeNotGranted(s): "Missing permission: Google didn't grant \(Self.plain(s)). Connect again and leave that box ticked on Google's consent screen."
        case .noRefreshToken: "Google didn't return a refresh token. Remove Wren's access in your Google account and connect again."
        case .invalidClient: "Google rejected this copy of Wren's sign-in configuration. That's a problem with how Wren was built, not with your account; it needs a fix from Wren's maintainers."
        case .timedOut: "Sign-in wasn't completed within 5 minutes."
        }
    }

    static func plain(_ scope: String) -> String {
        switch scope {
        case ConnectorCatalog.gmailScope: "read-only access to your email"
        case ConnectorCatalog.calendarScope: "read-only access to your calendars"
        default: scope
        }
    }
}

public struct GoogleOAuth: Sendable {
    public static let authorizeURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!

    public var config: GoogleOAuthConfig
    public var http: ConnectorHTTP
    public var now: @Sendable () -> Date

    public init(config: GoogleOAuthConfig, session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        http = ConnectorHTTP(allowedHosts: ["accounts.google.com", "oauth2.googleapis.com"], session: session)
        self.now = now
    }

    public func authorizationURL(scopes: [String], redirect: URL, state: String, pkce: PKCE) -> URL {
        var c = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: redirect.absoluteString),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        return c.url!
    }

    /// Validates the redirect Google sent to the loopback listener and returns the code.
    public static func parseCallback(_ url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ k: String) -> String? { items.first { $0.name == k }?.value }
        guard v("state") == expectedState else { throw OAuthError.stateMismatch }
        if let e = v("error") { throw e == "access_denied" ? OAuthError.denied : OAuthError.providerError(e) }
        guard let code = v("code"), !code.isEmpty else { throw OAuthError.missingCode }
        return code
    }

    static func form(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return Data(pairs.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
    }

    func postForm(_ url: URL, _ pairs: [(String, String)]) async throws -> JSONValue {
        do {
            let d = try await http.request(url, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Self.form(pairs))
            guard let v = try? JSONDecoder().decode(JSONValue.self, from: d) else { throw ConnectorError.badResponse("token response") }
            return v
        } catch let ConnectorError.http(400, m) where m.contains("invalid_grant") {
            throw ConnectorError.unauthorized
        } catch let ConnectorError.http(_, m) where m.contains("invalid_client") || m.contains("unauthorized_client") {
            throw OAuthError.invalidClient
        } catch ConnectorError.unauthorized {
            throw OAuthError.invalidClient
        }
    }

    func tokens(from v: JSONValue, requiredScope: String?, previousRefresh: String?) throws -> OAuthTokens {
        guard let access = v["access_token"]?.string else { throw ConnectorError.badResponse("no access token") }
        let scope = v["scope"]?.string ?? ""
        if let required = requiredScope, !scope.split(separator: " ").map(String.init).contains(required) {
            throw OAuthError.scopeNotGranted(required)
        }
        let expires = v["expires_in"]?.number ?? 3600
        return OAuthTokens(accessToken: access, refreshToken: v["refresh_token"]?.string ?? previousRefresh,
                           expiresAt: now().addingTimeInterval(expires), scope: scope, account: nil)
    }

    public func exchange(code: String, pkce: PKCE, redirect: URL, requiredScope: String) async throws -> OAuthTokens {
        var p = [("code", code), ("client_id", config.clientID), ("code_verifier", pkce.verifier),
                 ("redirect_uri", redirect.absoluteString), ("grant_type", "authorization_code")]
        if let s = config.clientSecret, !s.isEmpty { p.append(("client_secret", s)) }
        let t = try tokens(from: try await postForm(Self.tokenURL, p), requiredScope: requiredScope, previousRefresh: nil)
        guard t.refreshToken != nil else { throw OAuthError.noRefreshToken }
        return t
    }

    public func refresh(_ t: OAuthTokens) async throws -> OAuthTokens {
        guard let rt = t.refreshToken else { throw OAuthError.noRefreshToken }
        var p = [("client_id", config.clientID), ("refresh_token", rt), ("grant_type", "refresh_token")]
        if let s = config.clientSecret, !s.isEmpty { p.append(("client_secret", s)) }
        var n = try tokens(from: try await postForm(Self.tokenURL, p), requiredScope: nil, previousRefresh: rt)
        n.account = t.account
        if n.scope.isEmpty { n.scope = t.scope }
        return n
    }

    /// Best effort: revoking an already-invalid token is not an error.
    public func revoke(_ token: String) async {
        _ = try? await http.request(Self.revokeURL, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                    body: Self.form([("token", token)]))
    }
}

/// Holds one connector's Google tokens and hands out valid access tokens (refreshing as needed).
public final class GoogleSession: @unchecked Sendable {
    public let key: String
    let store: CredentialStore
    let lock = NSLock()
    /// Where an earlier development build kept a user-entered client. Only read to delete it.
    public static let legacyConfigKey = "google.oauth.client"

    public init(connector: ConnectorID, store: CredentialStore) { key = "google.\(connector.rawValue).tokens"; self.store = store }

    public var tokens: OAuthTokens? { store.readJSON(key, as: OAuthTokens.self) }
    public func save(_ t: OAuthTokens) throws { try store.writeJSON(key, t) }
    public func clear() throws { try store.delete(key) }


    /// A token valid for at least a minute, refreshing (and saving) when needed.
    public func accessToken(oauth: GoogleOAuth) async throws -> String {
        guard var t = tokens else { throw ConnectorError.notConfigured("Not connected.") }
        if t.expiresAt.timeIntervalSince(oauth.now()) < 60 {
            t = try await oauth.refresh(t)
            try save(t)
        }
        return t.accessToken
    }
}

/// One-shot HTTP listener on 127.0.0.1 for an OAuth redirect (the supported desktop flow for Google,
/// Sign in with ChatGPT and Wren's Notion relay). Only a GET to `path` carrying exactly the expected
/// `state` completes the wait; anything else gets an error page and is ignored, so an unrelated local
/// request can't consume or spoof the sign-in.
public final class LoopbackReceiver: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "wren.oauth.loopback")
    private var continuation: CheckedContinuation<URL, Error>?
    private var settled = false
    /// A callback that arrived before `waitForRedirect` started waiting.
    private var early: URL?
    public private(set) var port: UInt16 = 0
    public let path: String
    /// When set, the callback must carry exactly this `state`.
    public var expectedState: String?

    public init(path: String = "/", expectedState: String? = nil) { self.path = path; self.expectedState = expectedState }

    public var redirectURL: URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    /// Starts listening on a random free port bound to loopback only.
    public func start() async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        params.acceptLocalOnly = true
        let l = try NWListener(using: params)
        listener = l
        final class Once: @unchecked Sendable { var done = false }   // touched only on `queue`
        let once = Once()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:
                    self?.port = l.port?.rawValue ?? 0
                    if !once.done { once.done = true; c.resume() }
                case let .failed(e):
                    if !once.done { once.done = true; c.resume(throwing: e) }
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.start(queue: queue)
        }
    }

    /// Waits for the provider's redirect (or times out).
    public func waitForRedirect(timeout: TimeInterval = 300) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { g in
            g.addTask { try await withCheckedThrowingContinuation { c in self.queue.async {
                if let u = self.early { self.early = nil; c.resume(returning: u) } else { self.continuation = c }
            } } }
            g.addTask { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); throw OAuthError.timedOut }
            defer { g.cancelAll(); stop() }
            return try await g.next()!
        }
    }

    public func stop() { listener?.cancel(); listener = nil }

    public enum Verdict: Equatable { case accept, notFound, badState }

    /// Pure check used by the listener (and tests).
    public static func verdict(_ url: URL?, path: String, expectedState: String?) -> Verdict {
        guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.path == path,
              let items = c.queryItems, !items.isEmpty else { return .notFound }
        if let expectedState {
            let states = items.filter { $0.name == "state" }
            guard states.count == 1, states[0].value == expectedState else { return .badState }
        }
        return .accept
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let url = Self.parseRequestLine(req, port: self.port)
            let verdict = self.settled ? .notFound : Self.verdict(url, path: self.path, expectedState: self.expectedState)
            let (status, text): (String, String) = switch verdict {
            case .accept: ("200 OK", "<h2>Done</h2><p>You can close this tab and return to Wren.</p>")
            case .badState: ("400 Bad Request", "<h2>This sign-in link doesn't match</h2><p>Return to the browser tab that Wren opened, or start again in Wren.</p>")
            case .notFound: ("404 Not Found", "<h2>Not found</h2>")
            }
            let body = "<!doctype html><html><head><meta charset='utf-8'><title>Wren</title></head><body style='font-family:-apple-system;padding:40px'>\(text)</body></html>"
            let resp = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            if verdict == .accept, let url {
                self.settled = true
                if let c = self.continuation { self.continuation = nil; c.resume(returning: url) } else { self.early = url }
            }
        }
    }

    /// "GET /?code=…&state=… HTTP/1.1" → http://127.0.0.1:port/?code=…
    public static func parseRequestLine(_ request: String, port: UInt16) -> URL? {
        guard let line = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", parts[1].hasPrefix("/") else { return nil }
        return URL(string: "http://127.0.0.1:\(port)\(parts[1])")
    }
}
