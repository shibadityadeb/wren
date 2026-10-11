import Foundation
import Security

/// Sign in with ChatGPT for open-source local apps, implemented natively from OpenAI's documented
/// protocol (https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt). Wren registers
/// itself dynamically on first sign-in, so there is no API key, no client secret and no manually
/// registered client. The user signs in on OpenAI's own page in their browser; Wren only ever sees
/// the tokens OpenAI hands back, which live in the Keychain.
public enum SIWC {
    public static let issuer = "https://auth.openai.com"
    public static let resource = "https://api.openai.com/v1"
    public static let planScope = "chatgpt.tokens.use.direct"
    public static let scopes = ["openid", "profile", "email", "offline_access", "resource.invoke", planScope]
    public static let dynamicClient = "dynamic_agent_client"
    public static let appName = "Wren"
    public static let callbackPath = "/auth/callback"
    public static let manageUsageURL = URL(string: "https://chatgpt.com/settings/usage")!
    /// Refresh-time errors that mean the user has to sign in again.
    public static let reauthCodes: Set<String> = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                                                  "refresh_token_invalidated", "refresh_token_reused"]
}

/// Everything Wren keeps about a ChatGPT connection, stored as one Keychain item.
public struct ChatGPTConnection: Codable, Equatable, Sendable {
    /// The client ID OpenAI issued to this copy of Wren at registration (`oaiapp_…`).
    public var clientID: String
    public var subject: String
    public var email: String?
    public var name: String?
    /// The plan named in the signed identity, when OpenAI includes it.
    public var planType: String?
    public var idToken: String
    public var accessToken: String?
    public var refreshToken: String?
    public var expiresAt: Date?
    public var earliestRefreshAt: Date?
    public var scopes: [String]
    public var savedAt: Date

    public var planUsageAuthorized: Bool { scopes.contains(SIWC.planScope) && accessToken != nil }
}

public enum ChatGPTError: Error, Equatable, LocalizedError {
    case signInCancelled
    case registrationIncomplete
    case identityNotVerified
    case accountMismatch
    case reauthorizationRequired(String)
    case planNotAuthorized
    case notEligible
    case usageLimitReached
    case temporarilyUnavailable(String)
    case clientRejected
    case unsupportedRequest(String)
    case incomplete(partial: String)
    case interrupted(partial: String)
    case invalidResponse(String)
    case backgroundUseNotAllowed

    public var errorDescription: String? {
        switch self {
        case .signInCancelled: "Sign-in wasn't completed. You can try again when you're ready."
        case .registrationIncomplete: "ChatGPT didn't finish registering Wren. Try signing in again."
        case .identityNotVerified: "Wren couldn't verify the ChatGPT identity it received, so it didn't keep the connection. Sign in again."
        case .accountMismatch: "That sign-in returned a different ChatGPT account. Sign in with the original account, or disconnect first."
        case let .reauthorizationRequired(s): s
        case .planNotAuthorized: "You didn't allow Wren to use your ChatGPT plan. Reconnect and approve plan usage to send requests."
        case .notEligible: "This ChatGPT account or workspace can't share its plan with apps. A ChatGPT Plus or Pro plan is needed."
        case .usageLimitReached: "Your ChatGPT usage limit for apps has been reached. Check it under Manage usage in ChatGPT."
        case let .temporarilyUnavailable(s): s
        case .clientRejected: "ChatGPT no longer accepts this copy of Wren's registration. Reconnect to register again."
        case let .unsupportedRequest(s): s
        case .incomplete: "ChatGPT stopped before finishing the answer. You can keep the partial text or try again."
        case .interrupted: "The connection ended before the answer was complete. You can keep the partial text or try again."
        case let .invalidResponse(s): "ChatGPT returned something unexpected (\(s)). Try again."
        case .backgroundUseNotAllowed: "Wren uses your ChatGPT plan only for requests you start and confirm. Background tasks can't use it."
        }
    }

    /// Maps an OpenAI error body and status to a plain-language error. Never includes request text.
    public static func from(status: Int?, body: Data?, duringRefresh: Bool = false) -> ChatGPTError {
        let code = errorCode(body)
        return from(status: status, code: code, duringRefresh: duringRefresh)
    }

    public static func from(status: Int?, code: String?, duringRefresh: Bool = false) -> ChatGPTError {
        if let code {
            if duringRefresh, SIWC.reauthCodes.contains(code) {
                return .reauthorizationRequired("Your ChatGPT connection can no longer be renewed. Reconnect to keep using your plan.")
            }
            switch code {
            case "subscription_sharing_usage_limit_exceeded": return .usageLimitReached
            case "subscription_sharing_user_not_eligible": return .notEligible
            case "subscription_sharing_usage_unavailable": return .temporarilyUnavailable("ChatGPT couldn't check your plan usage right now. Try again shortly.")
            case "subscription_sharing_user_unavailable": return .temporarilyUnavailable("Your ChatGPT account is temporarily unavailable. Try again shortly.")
            case "subscription_sharing_invalid_user", "invalid_token", "invalid_api_key":
                return .reauthorizationRequired("ChatGPT didn't accept this connection anymore. Reconnect to keep using your plan.")
            case "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context", "insufficient_scope", "missing_scope":
                return .planNotAuthorized
            case "invalid_client", "subscription_sharing_v2_client_not_enabled": return .clientRejected
            case "access_denied": return .signInCancelled
            case "subscription_sharing_unsupported_capability": return .unsupportedRequest("This request uses something ChatGPT plan sharing doesn't support.")
            case "subscription_sharing_route_not_supported": return .unsupportedRequest("ChatGPT plan sharing doesn't support this kind of request.")
            case "model_not_found": return .unsupportedRequest("That model isn't available for your ChatGPT connection. Choose another model.")
            default:
                if SIWC.reauthCodes.contains(code) {
                    return .reauthorizationRequired("ChatGPT didn't accept the sign-in. Reconnect to try again.")
                }
            }
        }
        switch status {
        case 401?: return .reauthorizationRequired("ChatGPT didn't accept this connection anymore. Reconnect to keep using your plan.")
        case 403?: return .planNotAuthorized
        case 429?: return .temporarilyUnavailable("ChatGPT is receiving too many requests. Wait a moment and try again.")
        case let s? where s >= 500: return .temporarilyUnavailable("ChatGPT is temporarily unavailable. Try again shortly.")
        case let s? where s == 400 || s == 422: return .unsupportedRequest("ChatGPT couldn't accept this request.")
        default: return .invalidResponse(status.map { "HTTP \($0)" } ?? "no status")
        }
    }

    /// `{"error": "code"}`, `{"error": {"code": …}}`, `{"code": …}`, `{"detail": {"code": …}}`.
    static func errorCode(_ body: Data?) -> String? {
        guard let body, let v = try? JSONDecoder().decode(JSONValue.self, from: body) else { return nil }
        return errorCode(v)
    }

    static func errorCode(_ v: JSONValue) -> String? {
        let raw = v["error"]?.string ?? v["error"]?["code"]?.string ?? v["code"]?.string ?? v["detail"]?["code"]?.string
            ?? v["response"]?["error"]?["code"]?.string
        guard let raw, raw.count <= 100, raw.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else { return nil }
        return raw
    }

    static func fromTransport(_ e: Error) -> ChatGPTError {
        if let e = e as? ChatGPTError { return e }
        switch ConnectorHTTP.mapTransport(e) {
        case .cancelled: return .temporarilyUnavailable("Cancelled.")
        case .timedOut: return .temporarilyUnavailable("ChatGPT didn't answer in time. Try again.")
        case .hostNotAllowed: return .invalidResponse("refused address")
        default: return .temporarilyUnavailable("Couldn't reach ChatGPT. Check your internet connection and try again.")
        }
    }
}

/// The OpenID provider metadata Wren relies on, checked to belong to the issuer.
public struct SIWCDiscovery: Equatable, Sendable {
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var jwksURI: URL
    public var revocationEndpoint: URL?

    public static func parse(_ v: JSONValue) throws -> SIWCDiscovery {
        guard v["issuer"]?.string == SIWC.issuer else { throw ChatGPTError.invalidResponse("sign-in configuration") }
        func url(_ k: String) throws -> URL? {
            guard let s = v[k]?.string else { return nil }
            guard let u = URL(string: s), u.scheme == "https", u.host == "auth.openai.com" else { throw ChatGPTError.invalidResponse("sign-in configuration") }
            return u
        }
        guard let a = try url("authorization_endpoint"), let t = try url("token_endpoint"), let j = try url("jwks_uri") else {
            throw ChatGPTError.invalidResponse("sign-in configuration")
        }
        return SIWCDiscovery(authorizationEndpoint: a, tokenEndpoint: t, jwksURI: j, revocationEndpoint: try url("revocation_endpoint"))
    }
}

/// Verified claims from an ID token.
public struct SIWCIdentity: Equatable, Sendable {
    public var subject: String
    public var email: String?
    public var name: String?
    public var planType: String?
}

/// The OAuth half of Sign in with ChatGPT: discovery, the authorization URL, the loopback callback,
/// code exchange, refresh, ID-token verification against OpenAI's published keys, and revocation.
public final class ChatGPTAuth: @unchecked Sendable {
    let http: ConnectorHTTP
    let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cachedDiscovery: SIWCDiscovery?
    private var keys: [String: SecKey] = [:]

    public init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        var h = ConnectorHTTP(allowedHosts: ["auth.openai.com"], session: session)
        h.timeout = 20
        http = h
        self.now = now
    }

    public func discovery() async throws -> SIWCDiscovery {
        if let d = lock.withLock({ cachedDiscovery }) { return d }
        let data: Data, resp: HTTPURLResponse
        do { (data, resp) = try await http.raw(URL(string: SIWC.issuer + "/.well-known/openid-configuration")!) } catch { throw ChatGPTError.fromTransport(error) }
        guard resp.statusCode == 200, let v = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ChatGPTError.temporarilyUnavailable("ChatGPT sign-in is temporarily unavailable. Try again shortly.")
        }
        let d = try SIWCDiscovery.parse(v)
        lock.withLock { cachedDiscovery = d }
        return d
    }

    /// The URL to open in the browser. A first sign-in registers Wren (`dynamic_agent_client` plus the
    /// app name); later ones reuse the issued client ID so no second registration is created.
    public static func authorizationURL(_ d: SIWCDiscovery, registeredClientID: String?, hostID: String, redirect: URL,
                                        state: String, nonce: String, pkce: PKCE, loginHint: String?, reconsent: Bool) -> URL {
        var c = URLComponents(url: d.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var q: [URLQueryItem] = [
            .init(name: "client_id", value: registeredClientID ?? SIWC.dynamicClient),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirect.absoluteString),
            .init(name: "scope", value: SIWC.scopes.joined(separator: " ")),
            .init(name: "resource", value: SIWC.resource),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "ext_agent_host_id", value: hostID),
        ]
        if registeredClientID == nil { q.append(.init(name: "agent_name_hint", value: SIWC.appName)) }
        if let loginHint { q.append(.init(name: "login_hint", value: loginHint)) }
        if reconsent { q.append(.init(name: "prompt", value: "consent")) }
        c.queryItems = q
        // URLComponents leaves "+" unescaped, which form decoders read as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    /// Validates the redirect: one state that matches, a code, and the issued client ID.
    public static func parseCallback(_ url: URL, expectedState: String, registeredClientID: String?) throws -> (code: String, clientID: String) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func all(_ k: String) -> [String] { items.filter { $0.name == k }.compactMap(\.value) }
        guard all("state") == [expectedState] else { throw OAuthError.stateMismatch }
        if let e = all("error").first { throw ChatGPTError.from(status: nil, code: e) }
        let codes = all("code"), returned = all("client_id")
        guard codes.count == 1, !codes[0].isEmpty, returned.count <= 1 else { throw ChatGPTError.registrationIncomplete }
        guard let clientID = returned.first ?? registeredClientID, clientID != SIWC.dynamicClient,
              clientID.range(of: "^[A-Za-z0-9_-]{1,200}$", options: .regularExpression) != nil else { throw ChatGPTError.registrationIncomplete }
        if let registeredClientID, let r = returned.first, r != registeredClientID { throw ChatGPTError.registrationIncomplete }
        return (codes[0], clientID)
    }

    func tokenRequest(_ pairs: [(String, String)], duringRefresh: Bool) async throws -> JSONValue {
        let d = try await discovery()
        let data: Data, resp: HTTPURLResponse
        do {
            (data, resp) = try await http.raw(d.tokenEndpoint, method: "POST",
                                              headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
                                              body: GoogleOAuth.form(pairs))
        } catch { throw ChatGPTError.fromTransport(error) }
        guard (200..<300).contains(resp.statusCode) else { throw ChatGPTError.from(status: resp.statusCode, body: data, duringRefresh: duringRefresh) }
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = v else { throw ChatGPTError.invalidResponse("token response") }
        return v
    }

    struct Granted { var scopes: [String]; var access: String?; var refresh: String?; var expiresAt: Date?; var earliest: Date? }

    func granted(_ v: JSONValue, previousScopes: [String]?, previousRefresh: String?) throws -> Granted {
        guard let scope = v["scope"]?.string ?? previousScopes?.joined(separator: " ") else { throw ChatGPTError.invalidResponse("no granted permissions") }
        let scopes = scope.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let access = v["access_token"]?.string, !access.isEmpty else {
            if scopes.contains(SIWC.planScope) || scopes.contains("offline_access") { throw ChatGPTError.invalidResponse("missing credentials") }
            return Granted(scopes: scopes, access: nil, refresh: nil, expiresAt: nil, earliest: nil)
        }
        guard v["token_type"]?.string?.lowercased() == "bearer", let exp = v["expires_in"]?.number, exp > 0 else { throw ChatGPTError.invalidResponse("incomplete credentials") }
        let refresh = v["refresh_token"]?.string ?? previousRefresh
        if scopes.contains("offline_access"), refresh == nil { throw ChatGPTError.invalidResponse("no refresh credential") }
        var earliest: Date?
        if let n = v["earliest_refresh_at"]?.number { earliest = Date(timeIntervalSince1970: n) }
        else if let s = v["earliest_refresh_at"]?.string { earliest = ISO8601DateFormatter().date(from: s) }
        return Granted(scopes: scopes, access: access, refresh: refresh, expiresAt: now().addingTimeInterval(exp), earliest: earliest)
    }

    /// Exchanges the one-time code, verifies the identity, and returns the connection to store.
    public func exchange(code: String, clientID: String, pkce: PKCE, redirect: URL, nonce: String, expectedSubject: String?) async throws -> ChatGPTConnection {
        let v = try await tokenRequest([("grant_type", "authorization_code"), ("client_id", clientID), ("code", code),
                                        ("code_verifier", pkce.verifier), ("redirect_uri", redirect.absoluteString),
                                        ("resource", SIWC.resource)], duringRefresh: false)
        guard let idToken = v["id_token"]?.string else { throw ChatGPTError.identityNotVerified }
        let identity = try await verifyIDToken(idToken, clientID: clientID, nonce: nonce)
        if let expectedSubject, expectedSubject != identity.subject { throw ChatGPTError.accountMismatch }
        let g = try granted(v, previousScopes: nil, previousRefresh: nil)
        return ChatGPTConnection(clientID: clientID, subject: identity.subject, email: identity.email, name: identity.name,
                                 planType: identity.planType, idToken: idToken, accessToken: g.access, refreshToken: g.refresh,
                                 expiresAt: g.expiresAt, earliestRefreshAt: g.earliest, scopes: g.scopes, savedAt: now())
    }

    /// Uses the refresh token. The rotated tokens are handed to `persist` before the new ID token is
    /// checked, so a key-server outage can't lose a single-use refresh token. A new ID token must
    /// verify and name the same account.
    public func refresh(_ c: ChatGPTConnection, persist: @Sendable (ChatGPTConnection) throws -> Void = { _ in }) async throws -> ChatGPTConnection {
        guard let rt = c.refreshToken else {
            throw ChatGPTError.reauthorizationRequired("Your ChatGPT connection has expired. Reconnect to keep using your plan.")
        }
        let v = try await tokenRequest([("grant_type", "refresh_token"), ("client_id", c.clientID), ("refresh_token", rt),
                                        ("resource", SIWC.resource)], duringRefresh: true)
        let g = try granted(v, previousScopes: c.scopes, previousRefresh: rt)
        guard g.access != nil else { throw ChatGPTError.invalidResponse("no access credential") }
        var out = c
        out.accessToken = g.access; out.refreshToken = g.refresh; out.expiresAt = g.expiresAt; out.earliestRefreshAt = g.earliest
        out.scopes = g.scopes; out.savedAt = now()
        try persist(out)
        if let idToken = v["id_token"]?.string {
            let identity = try await verifyIDToken(idToken, clientID: c.clientID, nonce: nil)
            guard identity.subject == c.subject else { throw ChatGPTError.accountMismatch }
            out.idToken = idToken; out.email = identity.email ?? c.email; out.name = identity.name ?? c.name; out.planType = identity.planType ?? c.planType
            try persist(out)
        }
        return out
    }

    /// Revokes the renewable session. Throws when revocation couldn't be confirmed.
    public func revoke(_ c: ChatGPTConnection) async throws {
        guard let token = c.refreshToken ?? c.accessToken else { return }
        let d = try await discovery()
        guard let endpoint = d.revocationEndpoint else { throw ChatGPTError.temporarilyUnavailable("no revocation endpoint") }
        let hint = c.refreshToken != nil ? "refresh_token" : "access_token"
        for attempt in 0..<2 {
            do {
                let (_, resp) = try await http.raw(endpoint, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                                   body: GoogleOAuth.form([("token", token), ("token_type_hint", hint), ("client_id", c.clientID)]), timeout: 10)
                if resp.statusCode == 200 { return }
                if resp.statusCode < 500 || attempt == 1 { break }
            } catch { if attempt == 1 { break } }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        throw ChatGPTError.temporarilyUnavailable("revocation not confirmed")
    }

    // MARK: ID token verification (RS256 against the issuer's JWKS)

    public func verifyIDToken(_ token: String, clientID: String, nonce: String?) async throws -> SIWCIdentity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let hData = JWT.decode(parts[0]), let pData = JWT.decode(parts[1]), let sig = JWT.decode(parts[2]),
              let header = try? JSONDecoder().decode(JSONValue.self, from: hData),
              let claims = try? JSONDecoder().decode(JSONValue.self, from: pData) else { throw ChatGPTError.identityNotVerified }
        guard header["alg"]?.string == "RS256", let kid = header["kid"]?.string else { throw ChatGPTError.identityNotVerified }
        let key = try await publicKey(kid)
        let signed = Data((parts[0] + "." + parts[1]).utf8)
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, sig as CFData, nil) else { throw ChatGPTError.identityNotVerified }
        return try JWT.checkClaims(claims, issuer: SIWC.issuer, clientID: clientID, nonce: nonce, now: now())
    }

    func publicKey(_ kid: String) async throws -> SecKey {
        if let k = lock.withLock({ keys[kid] }) { return k }
        let d = try await discovery()
        let data: Data, resp: HTTPURLResponse
        do { (data, resp) = try await http.raw(d.jwksURI) } catch { throw ChatGPTError.fromTransport(error) }
        guard resp.statusCode == 200, let v = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ChatGPTError.temporarilyUnavailable("ChatGPT identity verification is temporarily unavailable. Try again shortly.")
        }
        var found: [String: SecKey] = [:]
        for k in v["keys"]?.array ?? [] {
            guard k["kty"]?.string == "RSA", let id = k["kid"]?.string, let n = k["n"]?.string.flatMap(JWT.decode),
                  let e = k["e"]?.string.flatMap(JWT.decode), let key = JWT.rsaKey(modulus: n, exponent: e) else { continue }
            found[id] = key
        }
        lock.withLock { keys = found }
        guard let k = found[kid] else { throw ChatGPTError.identityNotVerified }
        return k
    }
}

/// Small, dependency-free JWT helpers.
public enum JWT {
    public static func decode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    /// Public key from a JWK's modulus and exponent (PKCS#1 RSAPublicKey DER).
    public static func rsaKey(modulus n: Data, exponent e: Data) -> SecKey? {
        func length(_ l: Int) -> [UInt8] {
            if l < 0x80 { return [UInt8(l)] }
            var bytes: [UInt8] = []; var v = l
            while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
        func integer(_ d: Data) -> [UInt8] {
            var b = [UInt8](d); while b.count > 1 && b[0] == 0 { b.removeFirst() }
            if let f = b.first, f & 0x80 != 0 { b.insert(0, at: 0) }
            return [0x02] + length(b.count) + b
        }
        let body = integer(n) + integer(e)
        let der = Data([0x30] + length(body.count) + body)
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil)
    }

    public static func checkClaims(_ c: JSONValue, issuer: String, clientID: String, nonce: String?, now: Date, leeway: TimeInterval = 120) throws -> SIWCIdentity {
        guard c["iss"]?.string == issuer, let sub = c["sub"]?.string, !sub.isEmpty,
              let exp = c["exp"]?.number, c["iat"]?.number != nil else { throw ChatGPTError.identityNotVerified }
        let aud: [String] = c["aud"]?.string.map { [$0] } ?? c["aud"]?.array.compactMap(\.string) ?? []
        guard aud.contains(clientID) else { throw ChatGPTError.identityNotVerified }
        if let azp = c["azp"]?.string, azp != clientID { throw ChatGPTError.identityNotVerified }
        if aud.count > 1, c["azp"]?.string != clientID { throw ChatGPTError.identityNotVerified }
        guard Date(timeIntervalSince1970: exp + leeway) > now else { throw ChatGPTError.identityNotVerified }
        if let nonce, c["nonce"]?.string != nonce { throw ChatGPTError.identityNotVerified }
        let auth = c["https://api.openai.com/auth"]
        let profile = c["https://api.openai.com/profile"]
        return SIWCIdentity(subject: sub, email: c["email"]?.string ?? profile?["email"]?.string, name: c["name"]?.string,
                            planType: auth?["chatgpt_plan_type"]?.string)
    }
}
