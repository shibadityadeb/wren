import SwiftData
import XCTest
@testable import WrenCore

/// Asking ChatGPT from the capture panel: routing → connector → permissions → audit → history.
extension ChatGPTConnectorTests {
    func harness() throws -> (Harness, AskService, ChatGPTConnector) {
        let h = try Harness(now: Date(), calendar: calendar("Asia/Kolkata"))
        try h.policy.setGrant(.externalAI, granted: true)
        let c = make()
        return (h, AskService(store: h.store, broker: h.broker, chatgpt: c, clock: h.clock), c)
    }

    func connectedHarness() async throws -> (Harness, AskService, ChatGPTConnector) {
        let h = try Harness(now: Date(), calendar: calendar("Asia/Kolkata"))
        try h.policy.setGrant(.externalAI, granted: true)
        let c = await connected()
        return (h, AskService(store: h.store, broker: h.broker, chatgpt: c, clock: h.clock), c)
    }

    var quantum: AIRequest {
        guard case let .askAI(r) = IntentRouter.route("can you check on gpt what is quantum physics", now: Date()) else { fatalError("routing") }
        return r
    }

    func delegations(_ h: Harness) -> [DelegationRecord] { (try? h.store.context.fetch(FetchDescriptor<DelegationRecord>())) ?? [] }

    func testUnconnectedGivesAConnectActionAndSendsNothing() async throws {
        let (h, asks, _) = try harness()
        let o = await asks.askChatGPT(quantum, channel: .hotkey)
        XCTAssertEqual(o, .notConnected)
        XCTAssertFalse(RouteStub.requests.contains { $0.0.url?.path == "/v1/responses" })
        XCTAssertTrue(delegations(h).isEmpty, "the question isn't saved as done or as an item")
        let audit = try XCTUnwrap(h.audit().first)
        XCTAssertEqual(audit.action, BuiltInAction.delegateToExternalAI.rawValue)
        XCTAssertNotEqual(audit.status, .succeeded, "never recorded as completed")
        XCTAssertTrue(audit.detail?.hasPrefix("Not sent") == true)
        var card = AskCard(request: quantum, destination: .chatgpt); card.phase = .notConnected
        XCTAssertEqual(card.primary, .connect, "Return offers Connect ChatGPT, keeping the question")
    }

    func testAuthorizedRequestReachesTheProviderAndReturnsTheRealAnswer() async throws {
        let (h, asks, _) = try await connectedHarness()
        RouteStub.routes["/v1/responses"] = SIWCFixture.sse([
            #"{"type":"response.output_text.delta","delta":"Quantum physics studies "}"#,
            #"{"type":"response.output_text.delta","delta":"matter at the smallest scales."}"#,
            #"{"type":"response.completed","response":{"model":"gpt-fast-2026"}}"#])
        var streamed = ""
        let o = await asks.askChatGPT(quantum, channel: .hotkey) { streamed += $0 }
        guard case let .answered(text, source, id) = o else { return XCTFail("\(o)") }
        XCTAssertEqual(text, "Quantum physics studies matter at the smallest scales.")
        XCTAssertTrue(source.contains("gpt-fast-2026"))
        let sent = try JSONDecoder().decode(JSONValue.self, from: RouteStub.requests.last { $0.0.url?.path == "/v1/responses" }!.1!)
        XCTAssertTrue(sent["input"]!.array.first!["content"]!.string!.contains("What is quantum physics?"), "the question, meaning intact")
        let rec = try XCTUnwrap(delegations(h).first { $0.id == id })
        XCTAssertEqual(rec.status, .completed); XCTAssertEqual(rec.response, text); XCTAssertEqual(rec.reportedModel, "gpt-fast-2026"); XCTAssertNotNil(rec.completedAt)
        let audit = try XCTUnwrap(h.audit().first)
        XCTAssertEqual(audit.status, .succeeded); XCTAssertEqual(audit.action, BuiltInAction.delegateToExternalAI.rawValue)
        _ = streamed
    }

    func testUsageLimitPermissionAndReconnectStates() async throws {
        let (h, asks, c) = try await connectedHarness()
        RouteStub.routes["/v1/responses"] = SIWCFixture.sse([#"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#])
        guard case .usageLimit = await asks.askChatGPT(quantum, channel: .hotkey) else { return XCTFail() }
        XCTAssertEqual(delegations(h).first?.status, .failed, "a failed request is never recorded as answered")
        XCTAssertNotEqual(h.audit().first?.status, .succeeded)

        RouteStub.routes["/v1/responses"] = RouteStub.json(#"{"error":{"code":"chatpass_v2_scope_not_authorized"}}"#, 403)
        guard case .needsPermission = await asks.askChatGPT(quantum, channel: .hotkey) else { return XCTFail() }
        // After that the connector knows plan usage isn't allowed: nothing is sent next time.
        let before = RouteStub.requests.count
        guard case .needsPermission = await asks.askChatGPT(quantum, channel: .hotkey) else { return XCTFail() }
        XCTAssertEqual(RouteStub.requests.count, before)
        _ = c
    }

    func testAuthorizationFailureAsksToReconnect() async throws {
        let (_, asks, _) = try await connectedHarness()
        RouteStub.routes["/v1/responses"] = RouteStub.json(#"{"error":{"code":"invalid_token"}}"#, 401)
        RouteStub.routes[SIWCFixture.tokenPath] = RouteStub.json(#"{"error":"invalid_grant"}"#, 400)
        guard case .reconnect = await asks.askChatGPT(quantum, channel: .hotkey) else { return XCTFail() }
    }

    func testNetworkFailureThenRetrySucceeds() async throws {
        let (_, asks, _) = try await connectedHarness()
        RouteStub.failures["/v1/responses"] = .notConnectedToInternet
        guard case let .failed(_, retryable) = await asks.askChatGPT(quantum, channel: .hotkey) else { return XCTFail() }
        XCTAssertTrue(retryable)
        var card = AskCard(request: quantum, destination: .chatgpt); card.phase = .failed("x", retryable: true)
        XCTAssertEqual(card.primary, .run(.chatgpt), "Return retries")
        RouteStub.failures = [:]
        RouteStub.routes["/v1/responses"] = SIWCFixture.sse([#"{"type":"response.output_text.delta","delta":"ok"}"#, #"{"type":"response.completed","response":{}}"#])
        guard case .answered = await asks.askChatGPT(quantum, channel: .hotkey) else { return XCTFail() }
    }

    func testNoDuplicateSubmission() async throws {
        let (_, asks, _) = try await connectedHarness()
        RouteStub.routes["/v1/responses"] = SIWCFixture.sse([#"{"type":"response.output_text.delta","delta":"ok"}"#, #"{"type":"response.completed","response":{}}"#])
        RouteStub.delay = 0.3
        let q = quantum
        async let first = asks.askChatGPT(q, channel: .hotkey)
        try await Task.sleep(nanoseconds: 50_000_000)
        let second = await asks.askChatGPT(quantum, channel: .hotkey)
        XCTAssertEqual(second, .failed("That request is already being sent.", retryable: false))
        guard case .answered = await first else { return XCTFail() }
        XCTAssertEqual(RouteStub.requests.filter { $0.0.url?.path == "/v1/responses" }.count, 1)
        // And the panel's Return key does nothing while sending or after the answer.
        var card = AskCard(request: quantum, destination: .chatgpt)
        card.phase = .sending(recordID: nil); XCTAssertNil(card.primary)
        card.phase = .answered(text: "ok", source: "s", recordID: UUID()); XCTAssertNil(card.primary)
    }

    func testPossibleSecretIsNotSentWithoutReview() async throws {
        let (_, asks, _) = try await connectedHarness()
        let r = AIRequest(prompt: "Is my key sk-abcdefghijklmnopqrstuvwxyz valid?", original: "x", target: .chatgpt)
        guard case .needsReview = await asks.askChatGPT(r, channel: .hotkey) else { return XCTFail() }
        XCTAssertFalse(RouteStub.requests.contains { $0.0.url?.path == "/v1/responses" })
    }

    func testCardChoicesForAGeneralQuestion() {
        guard case let .generalQuestion(q) = IntentRouter.route("what is quantum physics", now: Date()) else { return XCTFail() }
        var card = AskCard(request: q, destination: .choose)
        XCTAssertEqual(card.primary, .run(.chatgpt), "no local model: ChatGPT")
        card.localAvailable = true
        XCTAssertEqual(card.primary, .run(.local), "ChatGPT not connected: the local model")
        card.chatgptReady = true
        XCTAssertEqual(card.primary, .run(.chatgpt), "connected: ChatGPT answers, not the local model")
        // Merely showing or changing a card never runs anything.
        XCTAssertTrue(RouteStub.requests.isEmpty)
    }

    func testModelGuessOfAStoredQueryIsIgnoredWhenTheWordsDontSupportIt() throws {
        let interpreter = ModelCommandInterpreter(client: try OllamaClient(session: RouteStub.session()), model: "m", resolver: ContextResolver())
        let raw = #"{"intent":"question","operation":null,"target_reference":null,"target_id":null,"date_phrase":null,"days_before_deadline":null,"question":"waiting"}"#
        let o = interpreter.validate(raw, text: "can you check on gpt what is quantum physics", pool: [], ids: [:], goals: [], items: [], context: .init(), now: Date())
        guard case .generalQuestion = o else { return XCTFail("\(o): this was the reported bug") }
        let o2 = interpreter.validate(raw, text: "anything I'm still expecting from people", pool: [], ids: [:], goals: [], items: [], context: .init(), now: Date())
        guard case .resolution(.answer) = o2 else { return XCTFail("a grounded waiting question still works") }
    }
}
