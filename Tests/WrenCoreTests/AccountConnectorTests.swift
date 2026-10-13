import Security
import XCTest
@testable import WrenCore

private func stub() -> URLSession { RouteStub.session() }

/// Simulates the browser: after the app opens the provider's page, "the provider" redirects the
/// browser to Wren's loopback listener with the given query.
private func redirect(to base: URL, _ query: String) {
    let url = URL(string: base.absoluteString + "?" + query)!
    Task.detached {
        try? await Task.sleep(nanoseconds: 50_000_000)
        _ = try? await URLSession(configuration: .ephemeral).data(from: url)
    }
}

private func query(_ url: URL) -> [String: String] {
    Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { a, _ in a }
}

private func form(_ body: Data?) -> [String: String] {
    var c = URLComponents(); c.percentEncodedQuery = String(decoding: body ?? Data(), as: UTF8.self)
    return Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { a, _ in a }
}

// MARK: - Test signing key and ID tokens

final class TestSigner {
    let key: SecKey
    let kid = "test-key-1"
    init() {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        key = SecKeyCreateRandomKey(attrs as CFDictionary, nil)!
    }

    static func b64(_ d: Data) -> String { PKCE.base64url(d) }

    /// JWKS for the public key (parses the PKCS#1 DER that Security exports).
    var jwks: String {
        let der = [UInt8](SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil)! as Data)
        var i = 0
        func len() -> Int {
            let first = Int(der[i]); i += 1
            if first < 0x80 { return first }
            var l = 0; for _ in 0..<(first & 0x7f) { l = (l << 8) | Int(der[i]); i += 1 }; return l
        }
        precondition(der[i] == 0x30); i += 1; _ = len()
        func integer() -> Data { precondition(der[i] == 0x02); i += 1; let l = len(); defer { i += l }; var b = Array(der[i..<(i + l)]); while b.first == 0 { b.removeFirst() }; return Data(b) }
        let n = integer(), e = integer()
        return #"{"keys":[{"kty":"RSA","kid":"\#(kid)","use":"sig","alg":"RS256","n":"\#(Self.b64(n))","e":"\#(Self.b64(e))"}]}"#
    }

    func token(_ claims: [String: Any], kid: String? = nil, alg: String = "RS256", tamper: Bool = false) -> String {
        let h = Self.b64(try! JSONSerialization.data(withJSONObject: ["alg": alg, "kid": kid ?? self.kid, "typ": "JWT"]))
        var p = Self.b64(try! JSONSerialization.data(withJSONObject: claims))
        let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((h + "." + p).utf8) as CFData, nil)! as Data
        if tamper { p = Self.b64(try! JSONSerialization.data(withJSONObject: claims.merging(["email": "attacker@example.com"]) { $1 })) }
        return h + "." + p + "." + Self.b64(sig)
    }
}

enum SIWCFixture {
    static let discovery = #"{"issuer":"https://auth.openai.com","authorization_endpoint":"https://auth.openai.com/api/accounts/authorize","token_endpoint":"https://auth.openai.com/api/accounts/oauth/token","jwks_uri":"https://auth.openai.com/.well-known/jwks.json","revocation_endpoint":"https://auth.openai.com/api/accounts/oauth/revoke"}"#
    static let tokenPath = "/api/accounts/oauth/token"
    static let revokePath = "/api/accounts/oauth/revoke"
    static let allScopes = SIWC.scopes.joined(separator: " ")
    static let models = #"{"models":[{"slug":"gpt-fast","display_name":"Fast","visibility":"list"},{"slug":"gpt-hidden","display_name":"Hidden","visibility":"hide"},{"slug":"gpt-deep","display_name":"Deep","visibility":"list"}]}"#

    static func claims(aud: Any = "oaiapp_123", nonce: String? = nil, exp: TimeInterval = Date().timeIntervalSince1970 + 3600,
                       iss: String = "https://auth.openai.com", sub: String = "user-1") -> [String: Any] {
        var c: [String: Any] = ["iss": iss, "aud": aud, "sub": sub, "exp": exp, "iat": Date().timeIntervalSince1970,
                                "email": "me@example.com", "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"]]
        if let nonce { c["nonce"] = nonce }
        return c
    }

    static func tokens(_ signer: TestSigner, nonce: String?, scope: String = allScopes, access: String = "AT1", refresh: String = "RT1", idToken: Bool = true) -> (Int, Data) {
        var o: [String: Any] = ["access_token": access, "refresh_token": refresh, "token_type": "Bearer", "expires_in": 3600, "scope": scope]
        if idToken { o["id_token"] = signer.token(claims(nonce: nonce)) }
        return (200, try! JSONSerialization.data(withJSONObject: o))
    }

    static func install(_ signer: TestSigner) {
        RouteStub.routes["/.well-known/openid-configuration"] = RouteStub.json(discovery)
        RouteStub.routes["/.well-known/jwks.json"] = RouteStub.json(signer.jwks)
        RouteStub.routes["/v1/models"] = RouteStub.json(models)
    }

    static func sse(_ events: [String]) -> (Int, Data) {
        (200, Data(events.map { "event: x\ndata: \($0)\n\n" }.joined().utf8))
    }
}

// MARK: - Sign in with ChatGPT protocol

final class SIWCProtocolTests: XCTestCase {
    override func setUp() { RouteStub.reset() }

    func testAuthorizationURLRegistersOnceThenReuses() throws {
        let d = try SIWCDiscovery.parse(try JSONDecoder().decode(JSONValue.self, from: Data(SIWCFixture.discovery.utf8)))
        let pkce = PKCE.make()
        let first = ChatGPTAuth.authorizationURL(d, registeredClientID: nil, hostID: "urn:uuid:abc", redirect: URL(string: "http://127.0.0.1:5555/auth/callback")!,
                                                 state: "S", nonce: "N", pkce: pkce, loginHint: nil, reconsent: false)
        let q = query(first)
        XCTAssertEqual(first.host, "auth.openai.com")
        XCTAssertEqual(q["client_id"], "dynamic_agent_client")
        XCTAssertEqual(q["agent_name_hint"], "Wren")
        XCTAssertEqual(q["ext_agent_host_id"], "urn:uuid:abc")
        XCTAssertEqual(q["scope"], "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        XCTAssertEqual(q["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["code_challenge"], pkce.challenge)
        XCTAssertEqual(q["redirect_uri"], "http://127.0.0.1:5555/auth/callback")
        XCTAssertNil(q["client_secret"]); XCTAssertNil(q["api_key"])
        let again = query(ChatGPTAuth.authorizationURL(d, registeredClientID: "oaiapp_123", hostID: "urn:uuid:abc", redirect: URL(string: "http://127.0.0.1:1/auth/callback")!,
                                                       state: "S", nonce: "N", pkce: pkce, loginHint: "me@example.com", reconsent: true))
        XCTAssertEqual(again["client_id"], "oaiapp_123")
        XCTAssertNil(again["agent_name_hint"], "no second registration")
        XCTAssertEqual(again["login_hint"], "me@example.com")
        XCTAssertEqual(again["prompt"], "consent")
    }

    func testDiscoveryMustBelongToIssuer() {
        let bad = #"{"issuer":"https://auth.openai.com","authorization_endpoint":"https://evil.example/authorize","token_endpoint":"https://auth.openai.com/t","jwks_uri":"https://auth.openai.com/j"}"#
        XCTAssertThrowsError(try SIWCDiscovery.parse(try JSONDecoder().decode(JSONValue.self, from: Data(bad.utf8))))
        XCTAssertThrowsError(try SIWCDiscovery.parse(.object(["issuer": .string("https://evil.example")])))
    }

    func testCallbackValidation() {
        let u: (String) -> URL = { URL(string: "http://127.0.0.1:1/auth/callback?" + $0)! }
        XCTAssertEqual(try ChatGPTAuth.parseCallback(u("code=C&state=S&client_id=oaiapp_1"), expectedState: "S", registeredClientID: nil).clientID, "oaiapp_1")
        XCTAssertEqual(try ChatGPTAuth.parseCallback(u("code=C&state=S"), expectedState: "S", registeredClientID: "oaiapp_9").clientID, "oaiapp_9")
        XCTAssertThrowsError(try ChatGPTAuth.parseCallback(u("code=C&state=X&client_id=oaiapp_1"), expectedState: "S", registeredClientID: nil)) { XCTAssertEqual($0 as? OAuthError, .stateMismatch) }
        XCTAssertThrowsError(try ChatGPTAuth.parseCallback(u("state=S&error=access_denied"), expectedState: "S", registeredClientID: nil)) { XCTAssertEqual($0 as? ChatGPTError, .signInCancelled) }
        XCTAssertThrowsError(try ChatGPTAuth.parseCallback(u("code=C&state=S"), expectedState: "S", registeredClientID: nil)) { XCTAssertEqual($0 as? ChatGPTError, .registrationIncomplete) }
        XCTAssertThrowsError(try ChatGPTAuth.parseCallback(u("code=C&state=S&client_id=dynamic_agent_client"), expectedState: "S", registeredClientID: nil))
        XCTAssertThrowsError(try ChatGPTAuth.parseCallback(u("code=C&state=S&client_id=oaiapp_other"), expectedState: "S", registeredClientID: "oaiapp_1"))
        XCTAssertThrowsError(try ChatGPTAuth.parseCallback(u("code=C&state=S&state=S&client_id=oaiapp_1"), expectedState: "S", registeredClientID: nil))
    }

    func testIDTokenVerification() async throws {
        let signer = TestSigner()
        SIWCFixture.install(signer)
        let auth = ChatGPTAuth(session: stub())
        let ok = try await auth.verifyIDToken(signer.token(SIWCFixture.claims(nonce: "N")), clientID: "oaiapp_123", nonce: "N")
        XCTAssertEqual(ok.subject, "user-1"); XCTAssertEqual(ok.email, "me@example.com"); XCTAssertEqual(ok.planType, "plus")
        let bad: [(String, String)] = [
            (signer.token(SIWCFixture.claims(aud: "oaiapp_other", nonce: "N")), "wrong audience"),
            (signer.token(SIWCFixture.claims(nonce: "N", iss: "https://evil.example")), "wrong issuer"),
            (signer.token(SIWCFixture.claims(nonce: "N", exp: Date().timeIntervalSince1970 - 3600)), "expired"),
            (signer.token(SIWCFixture.claims(nonce: "other")), "nonce mismatch"),
            (signer.token(SIWCFixture.claims(nonce: "N"), tamper: true), "tampered payload"),
            (signer.token(SIWCFixture.claims(nonce: "N"), kid: "unknown"), "unknown key"),
            (signer.token(SIWCFixture.claims(nonce: "N"), alg: "none"), "alg none"),
            (signer.token(SIWCFixture.claims(aud: ["oaiapp_123", "x"], nonce: "N")), "multiple audiences without azp"),
            ("not.a.jwt", "garbage"),
        ]
        for (t, why) in bad {
            do { _ = try await auth.verifyIDToken(t, clientID: "oaiapp_123", nonce: "N"); XCTFail(why) }
            catch { XCTAssertEqual(error as? ChatGPTError, .identityNotVerified, why) }
        }
    }

    func testErrorMapping() {
        func e(_ status: Int?, _ code: String?, refresh: Bool = false) -> ChatGPTError {
            ChatGPTError.from(status: status, body: code.map { Data(#"{"error":{"code":"\#($0)","message":"m"}}"#.utf8) }, duringRefresh: refresh)
        }
        XCTAssertEqual(e(429, "subscription_sharing_usage_limit_exceeded"), .usageLimitReached)
        XCTAssertEqual(e(403, "subscription_sharing_user_not_eligible"), .notEligible)
        XCTAssertEqual(e(403, "chatpass_v2_scope_not_authorized"), .planNotAuthorized)
        XCTAssertEqual(e(403, nil), .planNotAuthorized, "missing scope")
        guard case .temporarilyUnavailable = e(503, "subscription_sharing_usage_unavailable") else { return XCTFail() }
        guard case .temporarilyUnavailable = e(503, "subscription_sharing_user_unavailable") else { return XCTFail() }
        guard case .reauthorizationRequired = e(401, "subscription_sharing_invalid_user") else { return XCTFail() }
        guard case .reauthorizationRequired = e(401, nil) else { return XCTFail() }
        guard case .unsupportedCapability = e(400, "subscription_sharing_unsupported_capability") else { return XCTFail() }
        guard case .reauthorizationRequired = ChatGPTError.from(status: 400, body: Data(#"{"error":"refresh_token_reused"}"#.utf8), duringRefresh: true) else { return XCTFail() }
        XCTAssertEqual(ChatGPTError.from(status: 401, body: Data(#"{"error":"invalid_client"}"#.utf8)), .clientRejected)
        guard case .temporarilyUnavailable = e(500, nil) else { return XCTFail() }
        // Error codes from untrusted bodies are bounded.
        XCTAssertNil(ChatGPTError.errorCode(Data(#"{"error":"<script>"}"#.utf8)))
        // States the user sees.
        XCTAssertEqual(ChatGPTAccountState.from(.usageLimitReached), .usageLimitReached)
        XCTAssertEqual(ChatGPTAccountState.from(.planNotAuthorized).title, "Account connected, plan usage not authorized")
        XCTAssertEqual(ChatGPTAccountState.from(.reauthorizationRequired("x")).title, "Reauthorization required")
        XCTAssertEqual(ChatGPTAccountState.from(.temporarilyUnavailable("x")).title, "Temporarily unavailable")
        XCTAssertEqual(ChatGPTAccountState.notConnected.title, "Not connected")
        XCTAssertEqual(ChatGPTAccountState.planEnabled.title, "Connected and ChatGPT plan usage enabled")
        XCTAssertEqual(ChatGPTAccountState.planEnabled.connectorState(email: "me@example.com"), .connected(account: "me@example.com · Using ChatGPT plan"))
    }

    func testSSEParsingAndStreamState() throws {
        var p = SSEParser()
        XCTAssertNil(p.feed(": keep-alive"))
        XCTAssertNil(p.feed("event: response.output_text.delta\r"))
        XCTAssertNil(p.feed(#"data: {"type":"response.output_text.delta","#))
        XCTAssertNil(p.feed(#"data: "delta":"Hi"}"#))
        XCTAssertEqual(p.feed(""), "{\"type\":\"response.output_text.delta\",\n\"delta\":\"Hi\"}")
        var s = ResponseStreamState()
        XCTAssertEqual(try s.apply(#"{"type":"response.output_text.delta","delta":"Hel"}"#), "Hel")
        XCTAssertEqual(try s.apply(#"{"type":"response.output_text.delta","delta":"lo"}"#), "lo")
        XCTAssertNil(try s.apply(#"{"type":"response.created"}"#))
        XCTAssertFalse(s.completed, "deltas alone are not success")
        _ = try s.apply(#"{"type":"response.completed","response":{"model":"gpt-fast-2026"}}"#)
        XCTAssertTrue(s.completed); XCTAssertEqual(s.text, "Hello"); XCTAssertEqual(s.reportedModel, "gpt-fast-2026")
        var f = ResponseStreamState()
        XCTAssertThrowsError(try f.apply(#"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#)) { XCTAssertEqual($0 as? ChatGPTError, .usageLimitReached) }
        XCTAssertThrowsError(try f.apply(#"{"type":"response.incomplete"}"#)) { XCTAssertEqual($0 as? ChatGPTError, .incomplete(partial: "")) }
        XCTAssertThrowsError(try f.apply("{not json"))
    }

    func testModelParsingAndRequestBody() throws {
        XCTAssertEqual(try ChatGPTPlanClient.parseModels(Data(SIWCFixture.models.utf8)).map(\.slug), ["gpt-fast", "gpt-deep"], "only listed models, never hardcoded")
        XCTAssertThrowsError(try ChatGPTPlanClient.parseModels(Data(#"{"data":[]}"#.utf8)))
        XCTAssertThrowsError(try ChatGPTPlanClient.parseModels(Data(#"{"models":[{"slug":"","display_name":"x","visibility":"list"}]}"#.utf8)))
        let body = try JSONDecoder().decode(JSONValue.self, from: ChatGPTPlanClient.requestBody(model: "gpt-fast", input: "Hi", instructions: nil))
        XCTAssertEqual(body["store"], .bool(false)); XCTAssertEqual(body["stream"], .bool(true))
        XCTAssertEqual(body["model"]?.string, "gpt-fast")
        XCTAssertEqual(body["input"]?.array.first?["role"]?.string, "user")
    }
}

// MARK: - ChatGPT connector, end to end through the loopback redirect

@MainActor
final class ChatGPTConnectorTests: XCTestCase {
    var signer: TestSigner!
    var store: InMemoryCredentialStore!
    var grants: [Permission: Bool] = [:]
    override func setUp() async throws {
        RouteStub.reset(); signer = TestSigner(); store = InMemoryCredentialStore(); grants = [:]
        SIWCFixture.install(signer)
    }

    func make(now: @escaping @Sendable () -> Date = { Date() }) -> ChatGPTConnector {
        let c = ChatGPTConnector(store: store, statusStore: MemoryStatusStore(), session: stub(), handoffEnabled: false, selectedModel: nil,
                                 destination: { "Safari" }, now: now)
        c.grant = { [weak self] p, on in self?.grants[p] = on }
        return c
    }

    /// Runs a full sign-in; `callback` builds the provider's redirect query from the authorize URL.
    func signIn(_ c: ChatGPTConnector, reconsent: Bool = false, callback: @escaping ([String: String]) -> String) async -> URL? {
        var opened: URL?
        await c.connect(reconsent: reconsent) { url in
            opened = url
            let q = query(url)
            redirect(to: URL(string: q["redirect_uri"]!)!, callback(q))
        }
        return opened
    }

    func connected() async -> ChatGPTConnector {
        let c = make()
        var nonce = ""
        RouteStub.routes[SIWCFixture.tokenPath] = (0, Data())
        _ = await signIn(c) { q in
            nonce = q["nonce"]!
            RouteStub.routes[SIWCFixture.tokenPath] = SIWCFixture.tokens(self.signer, nonce: nonce)
            return "code=C1&state=\(q["state"]!)&client_id=oaiapp_123"
        }
        return c
    }

    func testSignInAuthorizesPlanAndDiscoversModels() async throws {
        let c = make()
        XCTAssertEqual(c.account, .notConnected); XCTAssertEqual(c.state.label, "Available to connect")
        let opened = await signIn(c) { q in
            RouteStub.routes[SIWCFixture.tokenPath] = SIWCFixture.tokens(self.signer, nonce: q["nonce"]!)
            return "code=C1&state=\(q["state"]!)&client_id=oaiapp_123&scope=x"
        }
        XCTAssertEqual(opened?.path, "/api/accounts/authorize")
        XCTAssertEqual(c.account, .planEnabled, "\(c.account)")
        XCTAssertEqual(c.state, .connected(account: "me@example.com · Using ChatGPT plan"))
        XCTAssertEqual(c.models.map(\.slug), ["gpt-fast", "gpt-deep"])
        XCTAssertEqual(c.selectedModel, "gpt-fast")
        XCTAssertEqual(c.planType, "plus")
        XCTAssertEqual(grants[.externalAI], true)
        XCTAssertEqual(store.readString(ChatGPTConnector.registrationKey), "oaiapp_123")
        XCTAssertTrue(store.readString(ChatGPTConnector.hostKey)!.hasPrefix("urn:uuid:"))
        let exchange = RouteStub.requests.first { $0.0.url?.path == SIWCFixture.tokenPath }!
        let f = form(exchange.1)
        XCTAssertEqual(f["grant_type"], "authorization_code")
        XCTAssertEqual(f["client_id"], "oaiapp_123")
        XCTAssertEqual(f["resource"], "https://api.openai.com/v1")
        XCTAssertNotNil(f["code_verifier"]); XCTAssertNil(f["client_secret"])
        let models = RouteStub.requests.first { $0.0.url?.path == "/v1/models" }!
        XCTAssertEqual(models.0.value(forHTTPHeaderField: "Authorization"), "Bearer AT1")
        XCTAssertEqual(Set(RouteStub.hosts), ["auth.openai.com", "api.openai.com"], "no other hosts contacted")
    }

    func testPlanUsageNotGranted() async {
        let c = make()
        _ = await signIn(c) { q in
            RouteStub.routes[SIWCFixture.tokenPath] = SIWCFixture.tokens(self.signer, nonce: q["nonce"]!, scope: "openid profile email offline_access")
            return "code=C1&state=\(q["state"]!)&client_id=oaiapp_123"
        }
        XCTAssertEqual(c.account.title, "Account connected, plan usage not authorized")
        guard case .missingPermissions = c.state else { return XCTFail("\(c.state)") }
        XCTAssertEqual(c.state.label, "Missing permissions")
        XCTAssertNotEqual(grants[.externalAI], true)
        XCTAssertFalse(RouteStub.requests.contains { $0.0.url?.path == "/v1/models" }, "no plan calls without the plan permission")
        do { _ = try await c.respond(model: "gpt-fast", input: "x", origin: .user(.popover)); XCTFail() }
        catch { XCTAssertEqual(error as? ChatGPTError, .planNotAuthorized) }
    }

    func testDeniedSignInStoresNothing() async {
        let c = make()
        _ = await signIn(c) { q in "error=access_denied&state=\(q["state"]!)" }
        XCTAssertEqual(c.account, .notConnected)
        XCTAssertNil(c.connection)
        XCTAssertEqual(c.status.lastError, ChatGPTError.signInCancelled.errorDescription)
    }

    func testForgedIdentityIsRejected() async {
        let c = make()
        _ = await signIn(c) { q in
            RouteStub.routes[SIWCFixture.tokenPath] = SIWCFixture.tokens(self.signer, nonce: "not-the-nonce")
            return "code=C1&state=\(q["state"]!)&client_id=oaiapp_123"
        }
        XCTAssertNil(c.connection, "tokens kept only after the identity verifies")
        XCTAssertEqual(c.account, .notConnected)
    }

    func testStreamedInferenceAndAttribution() async throws {
        let c = await connected()
        RouteStub.routes["/v1/responses"] = SIWCFixture.sse([
            #"{"type":"response.created"}"#,
            #"{"type":"response.output_text.delta","delta":"Ten "}"#,
            #"{"type":"response.output_text.delta","delta":"names"}"#,
            #"{"type":"response.completed","response":{"model":"gpt-fast-2026"}}"#])
        RouteStub.headers["/v1/responses"] = ["Content-Type": "text/event-stream; charset=utf-8"]
        let r = try await c.respond(model: "gpt-fast", input: "Brainstorm", origin: .user(.popover))
        XCTAssertEqual(r.text, "Ten names")
        XCTAssertEqual(r.requestedModel, "gpt-fast"); XCTAssertEqual(r.reportedModel, "gpt-fast-2026")
        let sent = RouteStub.requests.last!
        XCTAssertEqual(sent.0.value(forHTTPHeaderField: "Authorization"), "Bearer AT1")
        let body = try JSONDecoder().decode(JSONValue.self, from: sent.1!)
        XCTAssertEqual(body["store"], .bool(false)); XCTAssertEqual(body["model"]?.string, "gpt-fast")
    }

    func testBackgroundUseIsRefused() async {
        let c = await connected()
        let before = RouteStub.requests.count
        do { _ = try await c.respond(model: "gpt-fast", input: "x", origin: .system("briefing")); XCTFail() }
        catch { XCTAssertEqual(error as? ChatGPTError, .backgroundUseNotAllowed) }
        XCTAssertEqual(RouteStub.requests.count, before, "nothing sent")
    }

    func testUsageLimitFromStreamAndFromStatus() async throws {
        let c = await connected()
        RouteStub.routes["/v1/responses"] = SIWCFixture.sse([#"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#])
        do { _ = try await c.respond(model: "gpt-fast", input: "x", origin: .user(.popover)); XCTFail() }
        catch { XCTAssertEqual(error as? ChatGPTError, .usageLimitReached) }
        XCTAssertEqual(c.account, .usageLimitReached)
        XCTAssertEqual(c.state.label, "Usage limit reached")
        XCTAssertTrue(c.state.detail!.contains("Manage usage"))
        // Never falls back to anything else: exactly one request was made.
        XCTAssertEqual(RouteStub.requests.filter { $0.0.url?.path == "/v1/responses" }.count, 1)

        RouteStub.routes["/v1/responses"] = RouteStub.json(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}"#, 429)
        do { _ = try await c.respond(model: "gpt-fast", input: "x", origin: .user(.popover)); XCTFail() }
        catch { XCTAssertEqual(error as? ChatGPTError, .usageLimitReached) }

        RouteStub.routes["/v1/responses"] = SIWCFixture.sse([#"{"type":"response.output_text.delta","delta":"ok"}"#, #"{"type":"response.completed","response":{}}"#])
        _ = try await c.respond(model: "gpt-fast", input: "x", origin: .user(.popover))
        XCTAssertEqual(c.account, .planEnabled, "a successful request clears the limit")
    }

    func testInterruptedAndIncompleteKeepPartialText() async {
        let c = await connected()
        RouteStub.routes["/v1/responses"] = SIWCFixture.sse([#"{"type":"response.output_text.delta","delta":"Part"}"#])
        do { _ = try await c.respond(model: "gpt-fast", input: "x", origin: .user(.popover)); XCTFail() }
        catch { XCTAssertEqual(error as? ChatGPTError, .interrupted(partial: "Part"), "no response.completed means not a success") }
        RouteStub.routes["/v1/responses"] = SIWCFixture.sse([#"{"type":"response.output_text.delta","delta":"Half"}"#, #"{"type":"response.incomplete"}"#])
        do { _ = try await c.respond(model: "gpt-fast", input: "x", origin: .user(.popover)); XCTFail() }
        catch { XCTAssertEqual(error as? ChatGPTError, .incomplete(partial: "Half")) }
        XCTAssertEqual(c.account, .planEnabled, "a cut-off answer doesn't change the account state")
    }

    func testExpiredTokenRefreshesAndRotates() async throws {
        let c = await connected()
        var conn = c.connection!; conn.expiresAt = Date().addingTimeInterval(-10)
        try store.writeJSON(ChatGPTConnector.connectionKey, conn)
        RouteStub.routes[SIWCFixture.tokenPath] = SIWCFixture.tokens(signer, nonce: nil, access: "AT2", refresh: "RT2")
        RouteStub.routes["/v1/responses"] = SIWCFixture.sse([#"{"type":"response.completed","response":{}}"#])
        _ = try await c.respond(model: "gpt-fast", input: "x", origin: .user(.popover))
        let refresh = form(RouteStub.requests.last { $0.0.url?.path == SIWCFixture.tokenPath }!.1)
        XCTAssertEqual(refresh["grant_type"], "refresh_token"); XCTAssertEqual(refresh["refresh_token"], "RT1"); XCTAssertEqual(refresh["client_id"], "oaiapp_123")
        XCTAssertEqual(RouteStub.requests.last!.0.value(forHTTPHeaderField: "Authorization"), "Bearer AT2")
        XCTAssertEqual(c.connection?.refreshToken, "RT2", "rotated refresh token saved")
    }

    func testUnauthorizedRetriesOnceAfterRefresh() async throws {
        let c = await connected()
        RouteStub.routes[SIWCFixture.tokenPath] = SIWCFixture.tokens(signer, nonce: nil, access: "AT2", refresh: "RT2", idToken: false)
        RouteStub.sequences["/v1/responses"] = [RouteStub.json(#"{"error":{"code":"invalid_token"}}"#, 401),
                                               SIWCFixture.sse([#"{"type":"response.output_text.delta","delta":"ok"}"#, #"{"type":"response.completed","response":{}}"#])]
        let r = try await c.respond(model: "gpt-fast", input: "x", origin: .user(.popover))
        XCTAssertEqual(r.text, "ok")
        let calls = RouteStub.requests.filter { $0.0.url?.path == "/v1/responses" }
        XCTAssertEqual(calls.map { $0.0.value(forHTTPHeaderField: "Authorization") }, ["Bearer AT1", "Bearer AT2"])
    }

    func testRefreshFailureRequiresReauthorization() async throws {
        let c = await connected()
        var conn = c.connection!; conn.expiresAt = Date().addingTimeInterval(-10)
        try store.writeJSON(ChatGPTConnector.connectionKey, conn)
        RouteStub.routes[SIWCFixture.tokenPath] = RouteStub.json(#"{"error":"refresh_token_reused"}"#, 400)
        await c.refresh()
        XCTAssertEqual(c.account.title, "Reauthorization required")
        guard case .reauthorizationRequired = c.state else { return XCTFail() }
        XCTAssertNil(c.connection?.accessToken); XCTAssertNil(c.connection?.refreshToken)
        XCTAssertEqual(c.email, "me@example.com", "who to reconnect is kept, not the tokens")
        XCTAssertEqual(grants[.externalAI], false)
    }

    func testReconnectWithSameAccount() async throws {
        let c = await connected()
        RouteStub.routes[SIWCFixture.tokenPath] = RouteStub.json(#"{"error":"invalid_grant"}"#, 400)
        var conn = c.connection!; conn.expiresAt = Date().addingTimeInterval(-10)
        try store.writeJSON(ChatGPTConnector.connectionKey, conn)
        await c.refresh()
        guard case .reauthorizationRequired = c.account else { return XCTFail("\(c.account)") }
        let opened = await signIn(c) { q in
            RouteStub.routes[SIWCFixture.tokenPath] = SIWCFixture.tokens(self.signer, nonce: q["nonce"]!, access: "AT9")
            return "code=C2&state=\(q["state"]!)"
        }
        let q = query(opened!)
        XCTAssertEqual(q["client_id"], "oaiapp_123", "reuses the registration"); XCTAssertNil(q["agent_name_hint"])
        XCTAssertEqual(q["login_hint"], "me@example.com")
        XCTAssertEqual(c.account, .planEnabled)
        XCTAssertEqual(c.connection?.accessToken, "AT9")
    }

    func testNetworkErrorIsTemporary() async {
        let c = await connected()
        RouteStub.failures["/v1/models"] = .notConnectedToInternet
        await c.refresh()
        guard case .temporarilyUnavailable = c.account else { return XCTFail("\(c.account)") }
        XCTAssertNotNil(c.connection?.accessToken, "a network error never deletes the connection")
    }

    func testDisconnectRevokesAndRemovesTokens() async throws {
        let c = await connected()
        c.handoffEnabled = true
        RouteStub.routes[SIWCFixture.revokePath] = (200, Data())
        await c.disconnect()
        let f = form(RouteStub.requests.last { $0.0.url?.path == SIWCFixture.revokePath }!.1)
        XCTAssertEqual(f["token"], "RT1"); XCTAssertEqual(f["token_type_hint"], "refresh_token"); XCTAssertEqual(f["client_id"], "oaiapp_123")
        XCTAssertNil(c.connection); XCTAssertNil(c.disconnectNote)
        XCTAssertEqual(c.account, .notConnected); XCTAssertTrue(c.models.isEmpty)
        XCTAssertFalse(c.handoffEnabled)
        XCTAssertEqual(grants[.externalAI], false); XCTAssertEqual(grants[.chatgptHandoff], false)
        XCTAssertEqual(store.readString(ChatGPTConnector.registrationKey), "oaiapp_123", "registration kept for a later reconnect")

        let c2 = await connected()
        RouteStub.routes[SIWCFixture.revokePath] = (503, Data())
        await c2.disconnect()
        XCTAssertNil(c2.connection, "local tokens removed even when OpenAI can't confirm")
        XCTAssertNotNil(c2.disconnectNote)
    }

    func testTokensNeverReachStatusOrState() async throws {
        let c = await connected()
        let status = String(decoding: try JSONEncoder().encode(c.status), as: UTF8.self)
        for secret in ["AT1", "RT1", c.connection!.idToken] {
            XCTAssertFalse(status.contains(secret)); XCTAssertFalse("\(c.state)".contains(secret)); XCTAssertFalse(c.account.title.contains(secret))
        }
    }
}

// MARK: - Notion public OAuth through the maintainers' relay

@MainActor
final class NotionMCPTests: XCTestCase {
    var store: InMemoryCredentialStore!
    override func setUp() async throws { RouteStub.reset(); store = InMemoryCredentialStore() }

    static let metadata = #"{"issuer":"https://mcp.notion.com","authorization_endpoint":"https://mcp.notion.com/authorize","token_endpoint":"https://mcp.notion.com/token","registration_endpoint":"https://mcp.notion.com/register","revocation_endpoint":"https://mcp.notion.com/token","code_challenge_methods_supported":["S256"]}"#

    func make() -> NotionConnector {
        RouteStub.routes["/.well-known/oauth-authorization-server"] = RouteStub.json(Self.metadata)
        RouteStub.routes["/register"] = RouteStub.json(#"{"client_id":"wren-client-1","token_endpoint_auth_method":"none"}"#)
        let c = NotionConnector(store: store, statusStore: MemoryStatusStore(), session: stub())
        c.signInTimeout = 3
        return c
    }

    /// MCP replies: initialize (JSON) then a tool result (as server-sent events, like Notion sends).
    func stubMCP(tool: String) {
        RouteStub.headers["/mcp"] = ["Content-Type": "text/event-stream", "Mcp-Session-Id": "S1"]
        RouteStub.sequences["/mcp"] = [
            (200, Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\"}}\n\n".utf8)),
            (202, Data()),
            (200, Data("event: message\ndata: \(tool)\n\n".utf8)),
        ]
    }
    static func toolResult(id: Int, _ text: String, isError: Bool = false) -> String {
        let inner = try! JSONEncoder().encode(JSONValue.object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(isError)]))
        return #"{"jsonrpc":"2.0","id":\#(id),"result":\#(String(decoding: inner, as: UTF8.self))}"#
    }

    func connect(_ c: NotionConnector, _ answer: @escaping ([String: String]) -> String?) async {
        await c.connect { url in
            let q = query(url)
            if let reply = answer(q) { redirect(to: URL(string: q["redirect_uri"]!)!, reply) }
        }
    }

    func testConnectRegistersItselfAndVerifiesWithARealCall() async throws {
        let c = make()
        RouteStub.routes["/token"] = RouteStub.json(#"{"access_token":"NT1","refresh_token":"NR1","expires_in":3600,"token_type":"bearer"}"#)
        stubMCP(tool: Self.toolResult(id: 2, #"{"workspace":{"id":"w1","name":"Acme Notes"},"user":{"name":"Sam","email":"sam@example.com"}}"#))
        var asked: [String: String] = [:]
        await connect(c) { q in asked = q; return "code=NC&state=\(q["state"]!)&iss=https%3A%2F%2Fmcp.notion.com" }
        XCTAssertEqual(c.state, .connected(account: "Acme Notes"), "\(c.state) \(c.lastConnectError ?? "")")
        XCTAssertEqual(c.workspace, "Acme Notes")
        // Registration: public client, exactly this loopback address.
        let reg = try JSONDecoder().decode(JSONValue.self, from: RouteStub.requests.first { $0.0.url?.path == "/register" }!.1!)
        XCTAssertEqual(reg["token_endpoint_auth_method"]?.string, "none")
        XCTAssertEqual(reg["redirect_uris"]?.array.first?.string, asked["redirect_uri"])
        XCTAssertTrue(asked["redirect_uri"]!.hasPrefix("http://127.0.0.1:"))
        XCTAssertEqual(asked["client_id"], "wren-client-1"); XCTAssertEqual(asked["code_challenge_method"], "S256")
        XCTAssertEqual(asked["resource"], "https://mcp.notion.com/mcp")
        let tok = form(RouteStub.requests.first { $0.0.url?.path == "/token" }!.1)
        XCTAssertEqual(tok["code"], "NC"); XCTAssertNotNil(tok["code_verifier"]); XCTAssertNil(tok["client_secret"])
        let mcpCalls = RouteStub.requests.filter { $0.0.url?.path == "/mcp" }
        XCTAssertEqual(mcpCalls.last!.0.value(forHTTPHeaderField: "Authorization"), "Bearer NT1")
        XCTAssertEqual(mcpCalls.last!.0.value(forHTTPHeaderField: "Mcp-Session-Id"), "S1")
        XCTAssertTrue(String(decoding: mcpCalls.last!.1!, as: UTF8.self).contains("notion-get-self"))
        XCTAssertEqual(Set(RouteStub.hosts), ["mcp.notion.com"], "only Notion's server; no Wren server")
    }

    func testSearchFetchAndCreateUseNotionTools() async throws {
        let c = make()
        try store.writeJSON(NotionConnector.key, NotionMCPConnection(clientID: "x", redirectURI: "http://127.0.0.1:1/notion/callback", accessToken: "NT1",
                                                                     refreshToken: "NR1", expiresAt: Date().addingTimeInterval(3600), workspace: "W", user: nil, savedAt: Date()))
        stubMCP(tool: Self.toolResult(id: 2, #"{"results":[{"id":"p1","title":"Project decisions","url":"https://www.notion.so/p1","type":"page"},{"id":"p2","title":"Ideas","url":"https://www.notion.so/p2"}],"type":"workspace_search"}"#))
        let pages = try await c.client.searchPages("decisions")
        XCTAssertEqual(pages.map(\.title), ["Project decisions", "Ideas"])
        let fetched = ###"{"id":"p1","title":"Project decisions","content":"## Decision\n- Use SwiftData"}"###
        RouteStub.routes["/mcp"] = (200, Data("event: message\ndata: \(Self.toolResult(id: 3, fetched))\n\n".utf8))
        let text = try await c.client.pageText("p1")
        XCTAssertEqual(text, "# Project decisions\n\n## Decision\n- Use SwiftData")
        RouteStub.routes["/mcp"] = (200, Data("event: message\ndata: \(Self.toolResult(id: 4, #"{"pages":[{"id":"new1","url":"https://www.notion.so/new1","title":"Ideas"}]}"#))\n\n".utf8))
        let made = try await c.client.createPage(parentID: "p1", title: "Ideas", body: "line 1")
        XCTAssertEqual(made.id, "new1")
        let sent = try JSONDecoder().decode(JSONValue.self, from: RouteStub.requests.last!.1!)
        XCTAssertEqual(sent["params"]?["name"]?.string, "notion-create-pages")
        XCTAssertEqual(sent["params"]?["arguments"]?["parent"]?["page_id"]?.string, "p1")
        // A tool error is an error, never a result.
        RouteStub.routes["/mcp"] = (200, Data("event: message\ndata: \(Self.toolResult(id: 5, "Page not found", isError: true))\n\n".utf8))
        do { _ = try await c.client.pageText("nope"); XCTFail() } catch {}
    }

    func testDeniedCancelledAndBadStateLeaveNothingBehind() async {
        let c = make()
        await connect(c) { q in "error=access_denied&state=\(q["state"]!)" }
        XCTAssertEqual(c.state, .available); XCTAssertNotNil(c.lastConnectError); XCTAssertNil(c.connection)
        await connect(c) { _ in nil }   // the browser never comes back
        XCTAssertEqual(c.state, .available); XCTAssertNil(c.connection)
        await connect(c) { q in "code=NC&state=\(q["state"]!)&iss=https%3A%2F%2Fevil.example" }
        XCTAssertNil(c.connection, "a response from another issuer is refused")
    }

    func testExpiryRefreshRevocationAndDisconnect() async throws {
        let c = make()
        try store.writeJSON(NotionConnector.key, NotionMCPConnection(clientID: "cid", redirectURI: "http://127.0.0.1:1/notion/callback", accessToken: "old",
                                                                     refreshToken: "NR1", expiresAt: Date().addingTimeInterval(-5), workspace: "W", user: nil, savedAt: Date()))
        RouteStub.routes["/token"] = RouteStub.json(#"{"access_token":"new","refresh_token":"NR2","expires_in":3600}"#)
        stubMCP(tool: Self.toolResult(id: 2, #"{"workspace":{"name":"W"}}"#))
        await c.refresh()
        XCTAssertEqual(c.state, .connected(account: "W"))
        let refresh = form(RouteStub.requests.first { $0.0.url?.path == "/token" }!.1)
        XCTAssertEqual(refresh["grant_type"], "refresh_token"); XCTAssertEqual(refresh["client_id"], "cid")
        XCTAssertEqual(c.connection?.refreshToken, "NR2")
        // Refresh token expired (30 days unused / 180 days): reconnect.
        var conn = c.connection!; conn.expiresAt = Date().addingTimeInterval(-5)
        try store.writeJSON(NotionConnector.key, conn)
        RouteStub.routes["/token"] = RouteStub.json(#"{"error":"invalid_grant"}"#, 400)
        await c.refresh()
        guard case .reauthorizationRequired = c.state else { return XCTFail("\(c.state)") }
        // Network trouble is temporary and keeps the sign-in.
        conn.expiresAt = Date().addingTimeInterval(3600); try store.writeJSON(NotionConnector.key, conn)
        RouteStub.failures["/mcp"] = .notConnectedToInternet
        await c.refresh()
        guard case .temporarilyUnavailable = c.state else { return XCTFail("\(c.state)") }
        XCTAssertNotNil(c.connection)
        // Disconnect: revocation attempted, sign-in removed; unconfirmed revocation is said plainly.
        RouteStub.routes["/token"] = (503, Data())
        await c.disconnect()
        XCTAssertNil(c.connection); XCTAssertEqual(c.state, .disconnected); XCTAssertNotNil(c.disconnectNote)
    }
}

// MARK: - Maintainer configuration and Google scopes

@MainActor
final class ProviderConfigTests: XCTestCase {
    override func setUp() { RouteStub.reset() }
    let google = GoogleOAuthConfig(clientID: "1234567890-abcdefghijklmnopqrstuvwxyz.apps.googleusercontent.com")

    func testReadsOnlyValidInjectedValues() {
        XCTAssertEqual(ProviderConfig.from([:]), ProviderConfig())
        XCTAssertNil(ProviderConfig.from(["WrenGoogleClientID": "$(WREN_GOOGLE_CLIENT_ID)"]).google, "unsubstituted placeholder")
        XCTAssertNil(ProviderConfig.from(["WrenGoogleClientID": "nonsense"]).google)
        let full = ProviderConfig.from(["WrenGoogleClientID": google.clientID, "WrenGoogleStatus": "unverified"])
        XCTAssertEqual(full.google, google)
        XCTAssertEqual(full.googleStatus, .unverified)
        XCTAssertTrue(full.googleStatus.userNotice!.contains("Advanced"), "users are told how to pass Google's unverified-app screen")
        XCTAssertEqual(ProviderConfig.from([:]).googleStatus, .testing, "honest default")
        XCTAssertNil(ProviderConfig.from(["WrenGoogleStatus": "verified"]).googleStatus.userNotice)
    }

    func testMissingProviderIsAMaintainerBlockerNotAUserTask() async {
        let store = InMemoryCredentialStore()
        let g = GoogleConnector(.gmail, account: GoogleAccount(config: nil, store: store, session: stub()), statusStore: MemoryStatusStore())
        let n = NotionConnector(store: store, statusStore: MemoryStatusStore(), session: stub())
        XCTAssertEqual(n.state, .available, "Notion needs no maintainer setup")
        for s in [g.state] {
            guard case .notAvailableInBuild = s else { return XCTFail("\(s)") }
            XCTAssertEqual(s.label, "Maintainer setup required"); XCTAssertEqual(s.bucket, .unavailable)
            let text = s.detail!.lowercased()
            XCTAssertTrue(text.contains("nothing for you to set up"))
            for forbidden in ["client id", "secret", "api key", "token", "google cloud", "environment"] { XCTAssertFalse(text.contains(forbidden), forbidden) }
        }
        var opened = false
        await g.connect { _ in opened = true }
        XCTAssertFalse(opened); XCTAssertTrue(RouteStub.requests.isEmpty)
    }

    func testCatalogNeverAsksForDeveloperCredentials() {
        for d in ConnectorCatalog.all {
            let text = [d.summary, d.privacy, d.cleanup, d.auth.label].joined(separator: " ").lowercased()
            for forbidden in ["paste", "client id", "client secret", "integration token", "google cloud", "environment variable", "sk-"] {
                XCTAssertFalse(text.contains(forbidden), "\(d.id): \(forbidden)")
            }
        }
        XCTAssertFalse(ConnectorID.allCases.map(\.rawValue).contains("openaiAPI"), "no API-key connector")
        if case let .googleOAuth(scopes) = ConnectorCatalog.descriptor(.gmail).auth { XCTAssertEqual(scopes, [ConnectorCatalog.gmailScope]) } else { XCTFail() }
        if case let .googleOAuth(scopes) = ConnectorCatalog.descriptor(.googleCalendar).auth { XCTAssertEqual(scopes, [ConnectorCatalog.calendarScope]) } else { XCTFail() }
    }

    // MARK: Connect Google: one sign-in for Gmail and Calendar

    static let both = "\(ConnectorCatalog.gmailScope) \(ConnectorCatalog.calendarScope)"
    func googleStack(_ store: InMemoryCredentialStore = InMemoryCredentialStore()) -> (GoogleAccount, GoogleConnector, GoogleConnector) {
        let a = GoogleAccount(config: google, store: store, session: stub())
        a.signInTimeout = 3
        let status = MemoryStatusStore()
        return (a, GoogleConnector(.gmail, account: a, statusStore: status), GoogleConnector(.googleCalendar, account: a, statusStore: status))
    }
    func tokenResponse(scope: String, access: String = "A", refresh: String? = "R") -> (Int, Data) {
        RouteStub.json(#"{"access_token":"\#(access)",\#(refresh.map { "\"refresh_token\":\"\($0)\"," } ?? "")"expires_in":3600,"scope":"\#(scope)","token_type":"Bearer"}"#)
    }
    func stubReads() {
        RouteStub.routes["/gmail/v1/users/me/profile"] = RouteStub.json(#"{"emailAddress":"me@example.com"}"#)
        RouteStub.routes["/calendar/v3/calendars/primary"] = RouteStub.json(#"{"id":"me@example.com","summary":"me@example.com"}"#)
    }
    /// Google's consent: the browser comes back to Wren's loopback with this query.
    func consent(_ a: GoogleAccount, _ answer: @escaping ([String: String]) -> String?) async throws {
        try await a.connect(scopes: [ConnectorCatalog.gmailScope, ConnectorCatalog.calendarScope]) { url in
            let q = query(url)
            if let reply = answer(q) { redirect(to: URL(string: q["redirect_uri"]!)!, reply) }
        }
    }

    func testOneConsentConnectsGmailAndCalendar() async throws {
        let (a, gmail, cal) = googleStack()
        stubReads()
        RouteStub.routes["/token"] = tokenResponse(scope: Self.both)
        var asked: [String: String] = [:]
        try await consent(a) { q in asked = q; return "state=\(q["state"]!)&code=GC&scope=x" }
        XCTAssertEqual(Set(asked["scope"]!.split(separator: " ").map(String.init)), [ConnectorCatalog.gmailScope, ConnectorCatalog.calendarScope],
                       "only the two read-only scopes")
        XCTAssertEqual(asked["include_granted_scopes"], "true"); XCTAssertEqual(asked["code_challenge_method"], "S256")
        XCTAssertNil(asked["client_secret"])
        XCTAssertFalse(String(decoding: RouteStub.requests.first { $0.0.url?.path == "/token" }!.1!, as: UTF8.self).contains("client_secret"))
        XCTAssertEqual(a.email, "me@example.com", "identity from a real authorized read")
        await gmail.refresh(); await cal.refresh()
        XCTAssertEqual(gmail.state, .connected(account: "me@example.com"))
        XCTAssertEqual(cal.state, .connected(account: "me@example.com"))
        // Real reads use the shared token.
        RouteStub.routes["/gmail/v1/users/me/messages"] = RouteStub.json(#"{"messages":[]}"#)
        _ = try await gmail.gmail.messages(matching: "from:recruiter", limit: 5)
        XCTAssertEqual(RouteStub.requests.last!.0.value(forHTTPHeaderField: "Authorization"), "Bearer A")
        XCTAssertTrue(RouteStub.requests.allSatisfy { $0.0.httpMethod == "GET" || $0.0.url?.path == "/token" }, "read-only")
    }

    func testOnlyWhatGoogleGrantedIsTurnedOn() async throws {
        let (a, gmail, cal) = googleStack()
        stubReads()
        RouteStub.routes["/token"] = tokenResponse(scope: ConnectorCatalog.calendarScope)   // user unticked Gmail
        try await consent(a) { q in "state=\(q["state"]!)&code=GC" }
        await gmail.refresh(); await cal.refresh()
        XCTAssertEqual(cal.state, .connected(account: "me@example.com"))
        guard case let .missingPermissions(m) = gmail.state else { return XCTFail("\(gmail.state)") }
        XCTAssertTrue(m.contains("didn't allow Wren to read your email"))
        XCTAssertFalse(RouteStub.requests.contains { $0.0.url?.path == "/gmail/v1/users/me/profile" }, "no Gmail call without the Gmail permission")
        // Adding Gmail later asks again for both, keeping Calendar.
        RouteStub.routes["/token"] = tokenResponse(scope: Self.both, access: "A2")
        var asked = ""
        try await a.connect(scopes: [ConnectorCatalog.gmailScope]) { url in
            let q = query(url); asked = q["scope"]!
            redirect(to: URL(string: q["redirect_uri"]!)!, "state=\(q["state"]!)&code=GC2")
        }
        XCTAssertTrue(asked.contains(ConnectorCatalog.calendarScope) && asked.contains(ConnectorCatalog.gmailScope))
        await gmail.refresh()
        XCTAssertEqual(gmail.state, .connected(account: "me@example.com"))
    }

    func testCancelDenyAndNothingGrantedLeaveNothingBehind() async throws {
        let (a, gmail, _) = googleStack()
        stubReads()
        // Cancelled: the browser never comes back.
        do { try await consent(a) { _ in nil }; XCTFail() } catch { XCTAssertEqual(error as? OAuthError, .timedOut) }
        XCTAssertFalse(a.isSignedIn)
        // Denied on Google's screen.
        do { try await consent(a) { q in "state=\(q["state"]!)&error=access_denied" }; XCTFail() } catch { XCTAssertEqual(error as? OAuthError, .denied) }
        XCTAssertFalse(a.isSignedIn)
        // Every permission unticked.
        RouteStub.routes["/token"] = tokenResponse(scope: "openid")
        do { try await consent(a) { q in "state=\(q["state"]!)&code=GC" }; XCTFail() } catch { guard case .scopeNotGranted = error as? OAuthError else { return XCTFail("\(error)") } }
        XCTAssertFalse(a.isSignedIn)
        await gmail.refresh()
        XCTAssertEqual(gmail.state, .available)
        // A failed reconnect keeps an existing sign-in.
        RouteStub.routes["/token"] = tokenResponse(scope: Self.both)
        try await consent(a) { q in "state=\(q["state"]!)&code=GC" }
        do { try await consent(a) { q in "state=\(q["state"]!)&error=access_denied" }; XCTFail() } catch {}
        XCTAssertTrue(a.isSignedIn, "a cancelled reconnect doesn't disconnect")
    }

    func testExpiryRefreshRevocationAndDisconnect() async throws {
        let store = InMemoryCredentialStore()
        let (a, gmail, cal) = googleStack(store)
        stubReads()
        try a.session.save(OAuthTokens(accessToken: "old", refreshToken: "R", expiresAt: Date().addingTimeInterval(-5), scope: Self.both, account: "me@example.com"))
        RouteStub.routes["/token"] = RouteStub.json(#"{"access_token":"new","expires_in":3600,"token_type":"Bearer"}"#)
        await gmail.refresh()
        XCTAssertEqual(gmail.state, .connected(account: "me@example.com"))
        XCTAssertEqual(a.session.tokens?.accessToken, "new"); XCTAssertEqual(a.grantedScopes.count, 2, "scopes kept across refresh")
        // Revoked at Google: refresh fails → reconnect needed.
        try a.session.save(OAuthTokens(accessToken: "x", refreshToken: "R", expiresAt: Date().addingTimeInterval(-5), scope: Self.both, account: nil))
        RouteStub.routes["/token"] = RouteStub.json(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#, 400)
        await cal.refresh()
        guard case .reauthorizationRequired = cal.state else { return XCTFail("\(cal.state)") }
        // Network error: temporary, sign-in kept.
        try a.session.save(OAuthTokens(accessToken: "A", refreshToken: "R", expiresAt: Date().addingTimeInterval(3600), scope: Self.both, account: nil))
        RouteStub.failures["/gmail/v1/users/me/profile"] = .notConnectedToInternet
        await gmail.refresh()
        guard case .temporarilyUnavailable = gmail.state else { return XCTFail() }
        XCTAssertTrue(a.isSignedIn)
        // Disconnect revokes at Google and removes it for both.
        RouteStub.routes["/revoke"] = (200, Data())
        await gmail.disconnect(); await cal.refresh()
        XCTAssertEqual(form(RouteStub.requests.last { $0.0.url?.path == "/revoke" }!.1)["token"], "R")
        XCTAssertFalse(a.isSignedIn); XCTAssertNil(a.disconnectNote)
        XCTAssertEqual(cal.state, .available)
        XCTAssertNil(store.readString(GoogleSession.accountKey))
    }

    func testEarlierPerConnectorSignInIsAdopted() throws {
        let store = InMemoryCredentialStore()
        try store.writeJSON("google.googleCalendar.tokens", OAuthTokens(accessToken: "A", refreshToken: "R", expiresAt: .distantFuture, scope: ConnectorCatalog.calendarScope, account: "me@example.com"))
        let a = GoogleAccount(config: google, store: store, session: stub())
        XCTAssertEqual(a.email, "me@example.com"); XCTAssertEqual(a.grantedScopes, [ConnectorCatalog.calendarScope])
        XCTAssertNil(store.readString("google.googleCalendar.tokens"))
    }

    func testLoopbackVerdicts() {
        let u: (String) -> URL = { URL(string: "http://127.0.0.1:9/" + $0)! }
        XCTAssertEqual(LoopbackReceiver.verdict(u("auth/callback?code=c&state=S"), path: "/auth/callback", expectedState: "S"), .accept)
        XCTAssertEqual(LoopbackReceiver.verdict(u("auth/callback?code=c&state=X"), path: "/auth/callback", expectedState: "S"), .badState)
        XCTAssertEqual(LoopbackReceiver.verdict(u("auth/callback?state=S&state=S"), path: "/auth/callback", expectedState: "S"), .badState)
        XCTAssertEqual(LoopbackReceiver.verdict(u("favicon.ico"), path: "/auth/callback", expectedState: "S"), .notFound)
        XCTAssertEqual(LoopbackReceiver.verdict(u("other?state=S"), path: "/auth/callback", expectedState: "S"), .notFound)
    }
}

/// Opt-in: `WREN_LIVE_SIWC=1 swift test --filter SIWCLiveTests`. Reads only OpenAI's public metadata.
final class SIWCLiveTests: XCTestCase {
    func testLiveDiscoveryAndSigningKeys() async throws {
        guard ProcessInfo.processInfo.environment["WREN_LIVE_SIWC"] != nil else { throw XCTSkip("live test") }
        let auth = ChatGPTAuth()
        let d = try await auth.discovery()
        XCTAssertEqual(d.tokenEndpoint.absoluteString, "https://auth.openai.com/api/accounts/oauth/token")
        XCTAssertNotNil(d.revocationEndpoint)
        let (data, _) = try await URLSession.shared.data(from: d.jwksURI)
        let kids = try JSONDecoder().decode(JSONValue.self, from: data)["keys"]!.array.compactMap { $0["kid"]?.string }
        XCTAssertFalse(kids.isEmpty)
        for kid in kids { _ = try await auth.publicKey(kid) }
    }
}
