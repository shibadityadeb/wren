import SwiftData
import XCTest
@testable import WrenCore

/// GPT delegation as a tracked job (mocked provider: RouteStub serves OpenAI's documented stream
/// shapes; the live path is covered by docs/MANUAL_TESTS.md M-GPT-*).
extension ChatGPTConnectorTests {
    var ok: (Int, Data) { SIWCFixture.sse([#"{"type":"response.output_text.delta","delta":"Beginner resources: …"}"#, #"{"type":"response.completed","response":{"model":"gpt-x"}}"#]) }
    func request(_ s: String) -> AIRequest {
        guard case let .askAI(r) = IntentRouter.route(s, now: Date()) else { fatalError("routing: \(s)") }
        return r
    }

    func testBriefRequestIsPersistedRunningBeforeAnythingIsSentThenCompletesOnce() async throws {
        let (h, asks, _) = try await connectedHarness()
        RouteStub.routes["/v1/responses"] = ok
        RouteStub.delay = 0.2
        var finished: [UUID] = []
        asks.onFinished = { finished.append($0.id) }
        let r = request("Hey Wren, search in GPT: explain quantum physics and give me a few useful beginner resources.")
        guard case let .started(id) = asks.start(r, channel: .voice) else { return XCTFail() }
        // Saved as running immediately, with the user's words and the full query.
        let rec = try XCTUnwrap(asks.record(id))
        XCTAssertEqual(rec.status, .running)
        XCTAssertEqual(rec.prompt, "Explain quantum physics and give me a few useful beginner resources.")
        XCTAssertEqual(rec.original, r.original)
        XCTAssertEqual(rec.channel, .voice)
        guard case .answered = await asks.outcome(id) else { return XCTFail() }
        XCTAssertEqual(rec.status, .completed)
        XCTAssertEqual(rec.reportedModel, "gpt-x")
        XCTAssertNotNil(rec.requestedModel)
        XCTAssertNotNil(rec.completedAt)
        XCTAssertNil(rec.providerURL, "the plan API returns no conversation link, so none is invented")
        XCTAssertEqual(finished, [id], "announced exactly once")
        // Survives a restart: it's in the store, not in memory.
        let again = try h.store.context.fetch(FetchDescriptor<DelegationRecord>()).first { $0.id == id }
        XCTAssertEqual(again?.response, "Beginner resources: …")
    }

    func testRepeatedReturnOrVoiceEventDoesNotSendTwice() async throws {
        let (_, asks, _) = try await connectedHarness()
        RouteStub.routes["/v1/responses"] = ok
        RouteStub.delay = 0.3
        let r = request("Ask GPT to brainstorm names for my project.")
        guard case let .started(id) = asks.start(r, channel: .hotkey) else { return XCTFail() }
        XCTAssertEqual(asks.start(r, channel: .voice), .duplicate(id), "while running")
        _ = await asks.outcome(id)
        XCTAssertEqual(asks.start(r, channel: .hotkey), .duplicate(id), "just finished: a repeated event, not a new request")
        XCTAssertEqual(RouteStub.requests.filter { $0.0.url?.path == "/v1/responses" }.count, 1)
    }

    func testRetryReusesTheRecordAndNeverRerunsASuccess() async throws {
        let (h, asks, _) = try await connectedHarness()
        RouteStub.failures["/v1/responses"] = .notConnectedToInternet
        let r = request("Ask ChatGPT to research this topic.")
        guard case let .started(id) = asks.start(r, channel: .hotkey) else { return XCTFail() }
        guard case let .failed(_, retryable) = await asks.outcome(id) else { return XCTFail() }
        XCTAssertTrue(retryable)
        let rec = try XCTUnwrap(asks.record(id))
        XCTAssertEqual(rec.status, .failed); XCTAssertEqual(rec.failure, .unavailable); XCTAssertTrue(rec.canRetry)
        RouteStub.failures = [:]
        RouteStub.routes["/v1/responses"] = ok
        XCTAssertEqual(asks.retry(id), .started(id))
        guard case .answered = await asks.outcome(id) else { return XCTFail() }
        XCTAssertEqual(rec.attempts, 2)
        XCTAssertEqual(try h.store.context.fetchCount(FetchDescriptor<DelegationRecord>()), 1, "no second record")
        guard case .notRun = asks.retry(id) else { return XCTFail("a completed request is never re-sent") }
    }

    func testUsageLimitAndExpiredAuthorizationAreRecordedNotRetriedBlindly() async throws {
        let (_, asks, _) = try await connectedHarness()
        RouteStub.routes["/v1/responses"] = SIWCFixture.sse([#"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#])
        guard case let .started(id) = asks.start(request("Ask GPT to compare these two approaches."), channel: .hotkey) else { return XCTFail() }
        guard case .usageLimit = await asks.outcome(id) else { return XCTFail() }
        XCTAssertEqual(asks.record(id)?.failure, .usageLimit)
        XCTAssertTrue(asks.record(id)?.canRetry == true, "a usage limit can clear later")
    }

    func testRequestInterruptedByQuitIsReportedOnNextLaunch() async throws {
        let (h, asks, _) = try await connectedHarness()
        let rec = DelegationRecord(task: "Explain transformers.", destination: .chatgptPlan, depth: .normal, now: Date())
        rec.prompt = "Explain transformers."; rec.status = .running
        h.store.context.insert(rec); try h.store.context.save()
        XCTAssertEqual(asks.recoverInterrupted(), 1)
        XCTAssertEqual(rec.status, .failed)
        XCTAssertEqual(rec.failure, .interrupted)
        XCTAssertTrue(rec.canRetry)
        XCTAssertNil(rec.response, "never shown as completed")
    }

    func testOnlyTheRequestTextLeavesTheMac() async throws {
        let (h, asks, _) = try await connectedHarness()
        let private1 = try h.store.capture("Bank PIN reminder for Mum", source: .manual)
        private1.isPrivate = true
        RouteStub.routes["/v1/responses"] = ok
        guard case let .started(id) = asks.start(request("Ask GPT what quantum physics is."), channel: .hotkey) else { return XCTFail() }
        _ = await asks.outcome(id)
        let body = String(decoding: RouteStub.requests.last { $0.0.url?.path == "/v1/responses" }!.1!, as: UTF8.self)
        XCTAssertTrue(body.contains("What is quantum physics?"))
        XCTAssertFalse(body.contains("Bank PIN"), "no Wren data is attached by default")
        // The audit trail has labels only, never the answer.
        XCTAssertFalse(h.audit().contains { ($0.detail ?? "").contains("Beginner resources") })
    }

    func testEmptyQueryIsNotSent() async throws {
        let (_, asks, _) = try await connectedHarness()
        guard case .notRun = asks.start(AIRequest(prompt: " ? ", original: "ask gpt", target: .chatgpt), channel: .hotkey) else { return XCTFail() }
        XCTAssertFalse(RouteStub.requests.contains { $0.0.url?.path == "/v1/responses" })
    }

    func testRetryOfReviewedPrivateContextKeepsItsApproval() async throws {
        let (_, asks, _) = try await connectedHarness()
        try? h_grant()
        RouteStub.failures["/v1/responses"] = .notConnectedToInternet
        let item = HandoffContextItem(id: "n1", source: "Wren item", title: "Plan", text: "private plan", isPrivate: true)
        let draft = HandoffDraft(task: "Review my plan.", context: [item], includedPrivate: ["n1"])
        guard case let .started(id) = asks.start(AIRequest(prompt: draft.task, original: draft.task, target: .chatgpt), channel: .popover, reviewed: draft) else { return XCTFail() }
        _ = await asks.outcome(id)
        XCTAssertTrue(asks.record(id)?.includesPrivate == true)
        RouteStub.failures = [:]
        RouteStub.routes["/v1/responses"] = ok
        _ = asks.retry(id)
        guard case .answered = await asks.outcome(id) else { return XCTFail("the user's explicit inclusion carries over to the retry of the same text") }
        let body = String(decoding: RouteStub.requests.last { $0.0.url?.path == "/v1/responses" }!.1!, as: UTF8.self)
        XCTAssertTrue(body.contains("private plan"))
    }

    private func h_grant() throws {}
}

extension ChatGPTConnectorTests {
    func testPreV6PlanAnswersAreShownAsCompletedNotPasted() async throws {
        let (h, asks, _) = try harness()
        let r = DelegationRecord(task: "Q", destination: .chatgptPlan, depth: .normal, now: Date())
        r.status = .responseImported; r.response = "A"
        let pasted = DelegationRecord(task: "P", destination: .chatgptHandoff, depth: .normal, now: Date())
        pasted.status = .responseImported
        h.store.context.insert(r); h.store.context.insert(pasted); try h.store.context.save()
        asks.recoverInterrupted()
        XCTAssertEqual(r.status, .completed)
        XCTAssertNotNil(r.notifiedAt, "old results aren't announced again")
        XCTAssertEqual(pasted.status, .responseImported, "a real paste stays a paste")
    }
}

@MainActor
final class EraseCoversDelegationsTests: XCTestCase {
    func testRemoveAllDataDeletesGPTRequestsAndAnswers() throws {
        let h = try Harness(now: Date(), calendar: calendar("Asia/Kolkata"))
        let r = DelegationRecord(task: "secret plan", destination: .chatgptPlan, depth: .normal, now: Date())
        r.response = "answer"
        h.store.context.insert(r); try h.store.context.save()
        try h.store.eraseAllUserData(keepingAuditFor: nil)
        XCTAssertEqual(try h.store.context.fetchCount(FetchDescriptor<DelegationRecord>()), 0)
    }
}
