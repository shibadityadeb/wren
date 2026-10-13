import SwiftData
import XCTest
@testable import WrenCore

/// Thinking and research requests on the ChatGPT plan (mocked provider serving the documented
/// Responses stream shapes). Wren asks for high effort or web search only when the user's words
/// call for it, and records what the response reports actually ran, never what it hoped for.
extension ChatGPTConnectorTests {
    func body(_ path: String = "/v1/responses") throws -> JSONValue {
        let data = try XCTUnwrap(RouteStub.requests.last { $0.0.url?.path == path }?.1)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    func ask(_ s: String) -> AIRequest {
        guard case let .delegateToChatGPT(r) = ExecutionRouter.operation(for: s, now: Date()) else { fatalError("routing: \(s)") }
        return r
    }

    func testRequestBodyCarriesOnlyWhatWasAskedForAndTheRequiredFlags() throws {
        func decode(_ o: ResponseOptions) throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: ChatGPTPlanClient.requestBody(model: "m", input: "hi", instructions: nil, options: o))
        }
        let plain = try decode(.standard)
        XCTAssertEqual(plain["store"], .bool(false)); XCTAssertEqual(plain["stream"], .bool(true))
        XCTAssertNil(plain["reasoning"]); XCTAssertNil(plain["tools"])
        let both = try decode(ResponseOptions(reasoningEffort: "high", webSearch: true))
        XCTAssertEqual(both["reasoning"]?["effort"]?.string, "high")
        XCTAssertEqual(both["tools"], .array([.object(["type": .string("web_search")])]))
        // Fields the plan route rejects are never sent.
        for f in ["background", "conversation", "max_output_tokens", "temperature", "top_p", "metadata", "previous_response_id"] { XCTAssertNil(both[f], f) }
    }

    func testStreamEvidenceOfWebSearchEffortAndSources() throws {
        var st = ResponseStreamState()
        _ = try st.apply(#"{"type":"response.output_text.delta","delta":"Quantum physics studies…"}"#)
        _ = try st.apply(#"{"type":"response.completed","response":{"model":"gpt-x","reasoning":{"effort":"high"},"output":[{"type":"web_search_call"},{"type":"web_search_call"},{"type":"message","content":[{"type":"output_text","text":"…","annotations":[{"type":"url_citation","url":"https://example.org/qm","title":"QM intro"},{"type":"url_citation","url":"https://example.org/qm","title":"dup"},{"type":"url_citation","url":"javascript:alert(1)","title":"bad"}]}]}]}}"#)
        XCTAssertTrue(st.completed)
        XCTAssertEqual(st.reportedEffort, "high")
        XCTAssertEqual(st.webSearchCalls, 2, "the final output is authoritative")
        XCTAssertEqual(st.sources, [CitedSource(title: "QM intro", url: "https://example.org/qm")], "deduplicated, web links only")
    }

    /// The shape seen live on the plan route (2026-10-13): citations arrive as events and the
    /// completed response's `output` is empty.
    func testCitationsFromStreamEventsWhenTheCompletedOutputIsEmpty() throws {
        var st = ResponseStreamState()
        _ = try st.apply(#"{"type":"response.output_item.done","item":{"type":"web_search_call","status":"completed","action":{"type":"search","query":"q"}}}"#)
        _ = try st.apply(#"{"type":"response.output_text.annotation.added","annotation":{"type":"url_citation","url":"https://swift.org/blog/","title":"Swift.org blog","start_index":0,"end_index":5}}"#)
        _ = try st.apply(#"{"type":"response.output_item.done","item":{"type":"message","content":[{"type":"output_text","text":"…","annotations":[{"type":"url_citation","url":"https://swift.org/blog/","title":"Swift.org blog"}]}]}}"#)
        _ = try st.apply(#"{"type":"response.completed","response":{"model":"gpt-x","reasoning":{"effort":"medium"},"output":[]}}"#)
        XCTAssertEqual(st.webSearchCalls, 1)
        XCTAssertEqual(st.sources, [CitedSource(title: "Swift.org blog", url: "https://swift.org/blog/")])
        XCTAssertEqual(st.reportedEffort, "medium")
    }

    func testModelReasoningLevelsDecideTheEffortSent() throws {
        let list = Data(#"{"models":[{"slug":"a","display_name":"A","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"}]},{"slug":"b","display_name":"B","visibility":"list","supported_reasoning_levels":[]},{"slug":"c","display_name":"C","visibility":"list"}]}"#.utf8)
        let models = try ChatGPTPlanClient.parseModels(list)
        XCTAssertEqual(models[0].effort(forDeepThinking: "high"), "medium", "the strongest the model allows")
        XCTAssertNil(models[1].effort(forDeepThinking: "high"), "a model with no levels gets no reasoning setting")
        XCTAssertEqual(models[2].effort(forDeepThinking: "high"), "high", "unknown: ask, and record what the response reports")
    }

    func testThinkingRequestAsksForHighEffortAndRecordsTheReportedEffort() async throws {
        let (_, asks, _) = try await connectedHarness()
        RouteStub.routes["/v1/responses"] = SIWCFixture.sse([#"{"type":"response.output_text.delta","delta":"Weighing it up…"}"#,
                                                             #"{"type":"response.completed","response":{"model":"gpt-x","reasoning":{"effort":"high"}}}"#])
        let r = ask("Ask GPT to think deeply about whether I should change jobs")
        guard case let .started(id) = asks.start(r, channel: .voice) else { return XCTFail() }
        guard case .answered = await asks.outcome(id) else { return XCTFail() }
        XCTAssertEqual(try body()["reasoning"]?["effort"]?.string, "high")
        XCTAssertNil(try body()["tools"], "thinking isn't research: no web search offered")
        let rec = try XCTUnwrap(asks.record(id))
        XCTAssertEqual(rec.kind, .thinking); XCTAssertEqual(rec.requestedEffort, "high"); XCTAssertEqual(rec.reportedEffort, "high")
        XCTAssertFalse(rec.webSearchRequested)
    }

    func testResearchOffersWebSearchAndSaysHonestlyWhenNoneRan() async throws {
        let (_, asks, _) = try await connectedHarness()
        RouteStub.routes["/v1/responses"] = SIWCFixture.sse([#"{"type":"response.output_text.delta","delta":"From what I know…"}"#,
                                                             #"{"type":"response.completed","response":{"model":"gpt-x","output":[{"type":"message","content":[]}]}}"#])
        guard case let .started(id) = asks.start(ask("Ask GPT to research the fundamentals of quantum physics."), channel: .hotkey) else { return XCTFail() }
        guard case .answered = await asks.outcome(id) else { return XCTFail() }
        XCTAssertEqual(try body()["tools"], .array([.object(["type": .string("web_search")])]))
        let rec = try XCTUnwrap(asks.record(id))
        XCTAssertEqual(rec.kind, .research); XCTAssertTrue(rec.webSearchRequested)
        XCTAssertEqual(rec.webSearchCalls, 0, "offered but not used: recorded as such, never claimed")
        XCTAssertNil(rec.requestedEffort, "plain research doesn't raise the effort")
        XCTAssertEqual(DelegationText.notificationLine(rec), "Research: the fundamentals of quantum physics")
    }

    func testUnsupportedWebSearchFailsHonestlyThenRunsWithStandardSettingsOnlyWhenChosen() async throws {
        let (h, asks, _) = try await connectedHarness()
        RouteStub.routes["/v1/responses"] = (400, Data(#"{"error":{"code":"subscription_sharing_unsupported_capability","param":"tools[0].type","message":"x"}}"#.utf8))
        guard case let .started(id) = asks.start(ask("Ask GPT to research the latest battery chemistry"), channel: .hotkey) else { return XCTFail() }
        guard case let .unsupported(m) = await asks.outcome(id) else { return XCTFail("expected an unsupported-capability outcome") }
        XCTAssertTrue(m.contains("web search"), m)
        let rec = try XCTUnwrap(asks.record(id))
        XCTAssertEqual(rec.status, .failed); XCTAssertEqual(rec.failure, .unsupportedCapability)
        XCTAssertFalse(rec.canRetry, "the same refused body is never re-sent automatically")
        XCTAssertEqual(RouteStub.requests.filter { $0.0.url?.path == "/v1/responses" }.count, 1)
        // The user chooses to run it without web search.
        RouteStub.routes["/v1/responses"] = SIWCFixture.sse([#"{"type":"response.output_text.delta","delta":"Answer"}"#, #"{"type":"response.completed","response":{"model":"gpt-x"}}"#])
        XCTAssertEqual(asks.retryWithStandardSettings(id), .started(id))
        guard case .answered = await asks.outcome(id) else { return XCTFail() }
        XCTAssertNil(try body()["tools"]); XCTAssertNil(try body()["reasoning"])
        XCTAssertFalse(rec.webSearchRequested, "the record says what actually ran")
        XCTAssertEqual(try h.store.context.fetchCount(FetchDescriptor<DelegationRecord>()), 1)
    }

    func testUnsupportedErrorMappingNamesTheFeature() {
        XCTAssertEqual(ChatGPTError.from(status: 400, body: Data(#"{"error":{"code":"subscription_sharing_unsupported_capability","param":"reasoning.effort"}}"#.utf8)),
                       .unsupportedCapability(param: "reasoning.effort"))
        XCTAssertEqual(ChatGPTError.capability("reasoning.effort"), "reasoning effort")
        XCTAssertEqual(ChatGPTError.capability("tools"), "web search")
        XCTAssertTrue(ChatGPTError.unsupportedCapability(param: nil).errorDescription!.contains("standard settings"))
    }

    func testQueuedAndNeedsReconnectionLabels() throws {
        let r = DelegationRecord(task: "x", destination: .chatgptPlan, depth: .normal, now: Date())
        r.status = .running
        XCTAssertEqual(r.displayStatus, "Queued")
        r.startedAt = Date(); XCTAssertEqual(r.displayStatus, "Running")
        r.status = .failed; r.failure = .reauthorizationRequired
        XCTAssertEqual(r.displayStatus, "Needs reconnection")
    }
}
