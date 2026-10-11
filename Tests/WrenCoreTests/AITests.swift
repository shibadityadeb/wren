import XCTest
@testable import WrenCore

struct FakeProbe: OllamaInstallProbe {
    var installed: Bool
    func isInstalled() -> Bool { installed }
    func appURL() -> URL? { installed ? URL(fileURLWithPath: "/Applications/Ollama.app") : nil }
}

/// Routes stubbed responses by path, so one session can answer /api/version, /api/tags and /api/chat.
final class RouteStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (Int, Data)] = [:]
    nonisolated(unsafe) static var failures: [String: URLError.Code] = [:]
    nonisolated(unsafe) static var delay: TimeInterval = 0
    nonisolated(unsafe) static var hosts: [String] = []
    /// Per-path queues: each request takes the next response (falls back to `routes`).
    nonisolated(unsafe) static var sequences: [String: [(Int, Data)]] = [:]
    nonisolated(unsafe) static var requests: [(URLRequest, Data?)] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.hosts.append(request.url?.host ?? "")
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            stream.close(); body = d
        }
        Self.requests.append((request, body))
        if var q = Self.sequences[path], !q.isEmpty { let next = q.removeFirst(); Self.sequences[path] = q; Self.routes[path] = next }
        let deliver = { [self] in
            if let code = Self.failures[path] { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
            guard let (status, data) = Self.routes[path] else { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        if Self.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay, execute: deliver) } else { deliver() }
    }
    override func stopLoading() {}

    static func reset() { routes = [:]; failures = [:]; delay = 0; hosts = []; sequences = [:]; requests = [] }
    static func json(_ s: String, _ status: Int = 200) -> (Int, Data) { (status, Data(s.utf8)) }
    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [RouteStub.self]; return URLSession(configuration: c)
    }
    static func chat(_ content: String) -> (Int, Data) {
        let body = try! JSONEncoder().encode(JSONValue.object(["message": .object(["role": .string("assistant"), "content": .string(content)])]))
        return (200, body)
    }
}

final class AIReadinessTests: XCTestCase {
    override func setUp() { RouteStub.reset() }
    func diag(installed: Bool = true) throws -> AIDiagnostics {
        AIDiagnostics(client: try OllamaClient(session: RouteStub.session()), probe: FakeProbe(installed: installed))
    }
    let version = (200, Data(#"{"version":"0.40.2"}"#.utf8))
    let embeddingOnly = (200, Data(#"{"models":[{"name":"nomic-embed-text:latest","capabilities":["embedding"]}]}"#.utf8))
    let withChat = (200, Data(#"{"models":[{"name":"nomic-embed-text:latest","capabilities":["embedding"]},{"name":"qwen2.5:3b","capabilities":["completion"]}]}"#.utf8))

    func testDisabled() async throws {
        let r = await try diag().readiness(enabled: false, selected: "qwen2.5:3b")
        XCTAssertEqual(r, .disabled)
    }

    func testNotInstalledVsNotRunning() async throws {
        let a = await try diag(installed: false).readiness(enabled: true, selected: nil)
        XCTAssertEqual(a, .notInstalled)
        let b = await try diag(installed: true).readiness(enabled: true, selected: nil)
        XCTAssertEqual(b, .notRunning)
    }

    /// The exact situation on the development Mac: Ollama running with only an embedding model.
    func testRunningWithOnlyEmbeddingModelIsNoChatModel() async throws {
        RouteStub.routes = ["/api/version": version, "/api/tags": embeddingOnly]
        let report = await try diag().fullTest(enabled: true, selected: nil)
        XCTAssertEqual(report.readiness, .noChatModel)
        XCTAssertTrue(report.steps.contains { $0.detail.contains("embedding-only") })
    }

    func testSelectModelWhenNoneOrMissing() async throws {
        RouteStub.routes = ["/api/version": version, "/api/tags": withChat]
        let none = await try diag().readiness(enabled: true, selected: nil)
        XCTAssertEqual(none, .selectModel(["qwen2.5:3b"]))
        let missing = await try diag().readiness(enabled: true, selected: "llama3.2:3b")
        XCTAssertEqual(missing, .selectModel(["qwen2.5:3b"]))
    }

    func testConfiguredIsNotReadyWithoutATest() async throws {
        RouteStub.routes = ["/api/version": version, "/api/tags": withChat]
        let r = await try diag().readiness(enabled: true, selected: "qwen2.5:3b")
        XCTAssertEqual(r, .configured(model: "qwen2.5:3b", models: ["qwen2.5:3b"]))
        XCTAssertFalse(r.isReady)
    }

    func testReadyOnlyAfterSuccessfulParsedAnswer() async throws {
        RouteStub.routes = ["/api/version": version, "/api/tags": withChat, "/api/chat": RouteStub.chat(#"{"ok":true,"word":"wren"}"#)]
        let report = await try diag().fullTest(enabled: true, selected: "qwen2.5:3b")
        guard case .ready("qwen2.5:3b", _, _, _) = report.readiness else { return XCTFail("\(report.readiness)") }
        XCTAssertEqual(report.steps.map(\.outcome), [.passed, .passed, .passed, .passed, .passed])
        XCTAssertEqual(Set(RouteStub.hosts), ["127.0.0.1"], "only the local endpoint is contacted")
    }

    func testUnavailableOnTimeoutErrorAndBadOutput() async throws {
        RouteStub.routes = ["/api/version": version, "/api/tags": withChat]
        RouteStub.failures = ["/api/chat": .timedOut]
        guard case let .unavailable(_, _, reason) = await try diag().fullTest(enabled: true, selected: "qwen2.5:3b").readiness else { return XCTFail() }
        XCTAssertTrue(reason.lowercased().contains("timed out"))

        RouteStub.failures = [:]
        RouteStub.routes["/api/chat"] = (500, Data("model runner crashed".utf8))
        guard case .unavailable = await try diag().fullTest(enabled: true, selected: "qwen2.5:3b").readiness else { return XCTFail() }

        // Schema-valid but different content still counts as a working model (format is what's checked).
        RouteStub.routes["/api/chat"] = RouteStub.chat(#"{"ok":false,"word":""}"#)
        let shaped = await try diag().fullTest(enabled: true, selected: "qwen2.5:3b")
        guard case .ready = shaped.readiness else { return XCTFail("\(shaped.readiness)") }
        XCTAssertTrue(shaped.steps.last!.detail.contains("content differed"))

        RouteStub.routes["/api/chat"] = RouteStub.chat(#"{"ok":"yes"}"#)
        guard case .unavailable = await try diag().fullTest(enabled: true, selected: "qwen2.5:3b").readiness else { return XCTFail("wrong types must fail") }

        RouteStub.routes["/api/chat"] = RouteStub.chat("Sure! The answer is yes.")
        let bad = await try diag().fullTest(enabled: true, selected: "qwen2.5:3b")
        guard case .unavailable = bad.readiness else { return XCTFail() }
        XCTAssertEqual(bad.steps.last?.name, "Answer format")
        XCTAssertEqual(bad.steps.last?.outcome, .failed)
    }

    func testRecommendedModelMatchesDocs() {
        XCTAssertEqual(ModelSuggestion.recommended.first?.name, "qwen2.5:3b")
    }
}

final class ModelPullTests: XCTestCase {
    override func setUp() { RouteStub.reset() }

    func testAggregatorAddsLayersAndFinishes() throws {
        var a = PullAggregator()
        let lines = [
            #"{"status":"pulling manifest"}"#,
            #"{"status":"pulling aaa","digest":"sha256:aaa","total":1000,"completed":0}"#,
            #"{"status":"pulling bbb","digest":"sha256:bbb","total":3000,"completed":0}"#,
            #"{"status":"pulling aaa","digest":"sha256:aaa","total":1000,"completed":1000}"#,
            #"{"status":"pulling bbb","digest":"sha256:bbb","total":3000,"completed":1500}"#,
        ]
        var last: PullUpdate?
        for l in lines { last = try a.consume(l) ?? last }
        XCTAssertEqual(last?.completedBytes, 2500)
        XCTAssertEqual(last?.totalBytes, 4000)
        XCTAssertEqual(last!.fraction!, 0.625, accuracy: 0.0001)
        XCTAssertNil(try a.consume("   "))
        XCTAssertEqual(try a.consume(#"{"status":"verifying sha256 digest"}"#)?.done, false)
        XCTAssertEqual(try a.consume(#"{"status":"success"}"#)?.done, true)
    }

    func testAggregatorSurfacesErrors() {
        var a = PullAggregator()
        XCTAssertThrowsError(try a.consume(#"{"error":"pull model manifest: file does not exist"}"#)) {
            XCTAssertEqual($0 as? OllamaError, .pullFailed("pull model manifest: file does not exist"))
        }
        XCTAssertThrowsError(try a.consume("<html>proxy error</html>"))
    }

    func testModelNameValidation() {
        for ok in ["qwen2.5:3b", "llama3.2:3b", "mistral", "library/qwen2.5:1.5b-instruct-q4_K_M"] { XCTAssertTrue(OllamaClient.isValidModelName(ok), ok) }
        for bad in ["", "qwen; rm -rf ~", "http://evil.example/model", "../../etc", "Qwen 2.5", "$(whoami)", String(repeating: "a", count: 90)] {
            XCTAssertFalse(OllamaClient.isValidModelName(bad), bad)
        }
    }

    func collect(_ s: AsyncThrowingStream<PullUpdate, Error>) async -> ([PullUpdate], Error?) {
        var out: [PullUpdate] = []
        do { for try await u in s { out.append(u) } ; return (out, nil) } catch { return (out, error) }
    }

    func testStreamSuccessFailureAndTruncation() async throws {
        let client = try OllamaClient(session: RouteStub.session())
        let ok = [#"{"status":"pulling manifest"}"#, #"{"status":"pulling x","digest":"d","total":10,"completed":10}"#, #"{"status":"success"}"#].joined(separator: "\n")
        RouteStub.routes = ["/api/pull": (200, Data(ok.utf8))]
        let (u1, e1) = await collect(client.pull(model: "qwen2.5:3b"))
        XCTAssertNil(e1)
        XCTAssertEqual(u1.last?.done, true)
        XCTAssertEqual(u1.last?.fraction, 1)

        RouteStub.routes = ["/api/pull": (200, Data(#"{"error":"insufficient disk space"}"#.utf8))]
        let (_, e2) = await collect(client.pull(model: "qwen2.5:3b"))
        XCTAssertEqual(e2 as? OllamaError, .pullFailed("insufficient disk space"))

        RouteStub.routes = ["/api/pull": (200, Data(#"{"status":"pulling x","digest":"d","total":10,"completed":4}"#.utf8))]
        let (u3, e3) = await collect(client.pull(model: "qwen2.5:3b"))
        XCTAssertEqual(u3.last?.completedBytes, 4, "partial progress was reported")
        XCTAssertEqual(e3 as? OllamaError, .pullFailed("The download stopped before it finished."))

        let (_, e4) = await collect(client.pull(model: "evil; rm"))
        XCTAssertEqual(e4 as? OllamaError, .invalidModelName("evil; rm"))

        // The completion helper turns a truncated stream into an explicit failure.
        do { _ = try await client.pullToCompletion(model: "qwen2.5:3b") { _ in }; XCTFail("truncated pull must not succeed") } catch {
            XCTAssertEqual(error as? OllamaError, .pullFailed("The download stopped before it finished."))
        }
        RouteStub.routes = [:] // service went away
        let (_, e5) = await collect(client.pull(model: "qwen2.5:3b"))
        guard case .unreachable = e5 as? OllamaError else { return XCTFail("\(String(describing: e5))") }
    }

    func testCancellation() async throws {
        RouteStub.delay = 2
        RouteStub.routes = ["/api/pull": (200, Data(#"{"status":"success"}"#.utf8))]
        let client = try OllamaClient(session: RouteStub.session())
        let task = Task { () -> Error? in
            do { _ = try await client.pullToCompletion(model: "qwen2.5:3b") { _ in } ; return nil } catch { return error }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let err = await task.value
        XCTAssertTrue(err is CancellationError, "\(String(describing: err))")
    }
}

@MainActor
final class ModelCommandTests: XCTestCase {
    let cal = calendar("Asia/Kolkata")
    var now: Date { at(cal, 2026, 10, 8, 12) } // Thursday

    func setup() throws -> (Harness, ModelCommandInterpreter, api: Commitment, research: Commitment, app: Commitment) {
        let h = try Harness(now: now, calendar: cal)
        let api = try h.add("Submit the API review", deadline: at(cal, 2026, 10, 9))
        let research = try h.add("Research review with Dana")
        let app = try h.add("Scholarship application", deadline: at(cal, 2026, 10, 20))
        let m = ModelCommandInterpreter(client: try OllamaClient(session: RouteStub.session()), model: "qwen2.5:3b",
                                        resolver: ContextResolver(calendar: cal, dateOnlyReminderHour: 10))
        return (h, m, api, research, app)
    }

    func run(_ m: ModelCommandInterpreter, _ h: Harness, _ text: String, _ json: String, context: ConversationContext = .init()) throws -> ModelCommandOutcome {
        let pool = try h.store.all().filter { $0.status == .pending }
        let (_, ids) = m.candidateList(pool, context: context)
        return m.validate(json, text: text, pool: pool, ids: ids, goals: [], items: try h.store.all(), context: context, now: now)
    }

    func proposal(_ o: ModelCommandOutcome, file: StaticString = #filePath, line: UInt = #line) -> ContextProposal? {
        if case let .resolution(.proposal(p)) = o { return p }
        XCTFail("expected proposal, got \(o)", file: file, line: line); return nil
    }

    func testPoliteVariationResolvesToConversationalProposal() throws {
        let (h, m, api, _, _) = try setup()
        let text = "Could you push that API task to next Wednesday?"
        let p = try XCTUnwrap(proposal(try run(m, h, text, #"{"intent":"change_item","operation":"reschedule","target_reference":"that API task","target_id":null,"date_phrase":"next Wednesday","days_before_deadline":null,"question":null}"#)))
        XCTAssertEqual(p.request.target.id, api.id.uuidString)
        XCTAssertEqual(p.request.origin, .conversational(text))
        XCTAssertEqual(p.request.parameters.date("deadline"), at(cal, 2026, 10, 14))
        XCTAssertTrue(p.note?.contains("local model") == true)
    }

    func testPronounFromContextWithLongPhrasing() throws {
        let (h, m, _, research, _) = try setup()
        let text = "I don't think I'm going to get that done this week. Move it to Sunday."
        let p = try XCTUnwrap(proposal(try run(m, h, text, #"{"intent":"change_item","operation":"reschedule","target_reference":"it","target_id":null,"date_phrase":"Sunday","days_before_deadline":null,"question":null}"#,
                                               context: .init(recent: [research.id]))))
        XCTAssertEqual(p.request.target.id, research.id.uuidString)
        XCTAssertEqual(p.request.action, BuiltInAction.scheduleReminder, "no deadline, so a reminder")
    }

    func testInventedIdIsIgnoredAndDisagreementAsks() throws {
        let (h, m, api, research, _) = try setup()
        let invented = try run(m, h, "mark the research review complete",
                               #"{"intent":"change_item","operation":"complete","target_reference":"the research review","target_id":"deadbeef","date_phrase":null,"days_before_deadline":null,"question":null}"#)
        XCTAssertEqual(proposal(invented)?.request.target.id, research.id.uuidString, "made-up id ignored; resolver decides")

        let shortAPI = String(api.id.uuidString.prefix(8)).lowercased()
        let disagree = try run(m, h, "mark the research review complete",
                               #"{"intent":"change_item","operation":"complete","target_reference":"the research review","target_id":"\#(shortAPI)","date_phrase":null,"days_before_deadline":null,"question":null}"#)
        guard case let .resolution(.clarify(_, c, _)) = disagree else { return XCTFail("\(disagree)") }
        XCTAssertEqual(Set(c.map(\.id)), [research.id, api.id])
    }

    func testModelOnlyPickIsAskedNotAssumed() throws {
        let (h, m, _, _, app) = try setup()
        let short = String(app.id.uuidString.prefix(8)).lowercased()
        let o = try run(m, h, "drop the funding thing", #"{"intent":"change_item","operation":"drop","target_reference":"the funding thing","target_id":"\#(short)","date_phrase":null,"days_before_deadline":null,"question":null}"#)
        guard case let .resolution(.clarify(q, c, _)) = o else { return XCTFail("\(o)") }
        XCTAssertTrue(q.contains("Did you mean"))
        XCTAssertEqual(c.map(\.id), [app.id])
    }

    func testParaphrasedReferenceUsesOnlyTheUsersWords() throws {
        let (h, m, api, _, _) = try setup()
        let p = try XCTUnwrap(proposal(try run(m, h, "Let's do the API one later, shift it out to next Wednesday please",
                                               #"{"intent":"change_item","operation":"reschedule","target_reference":"API review task","target_id":null,"date_phrase":"next Wednesday","days_before_deadline":null,"question":null}"#)))
        XCTAssertEqual(p.request.target.id, api.id.uuidString)
        // A paraphrase with no word from the user's text is not trusted.
        let o = try run(m, h, "shift that one to next Wednesday", #"{"intent":"change_item","operation":"reschedule","target_reference":"scholarship","target_id":null,"date_phrase":"next Wednesday","days_before_deadline":null,"question":null}"#)
        guard case .resolution(.clarify) = o else { return XCTFail("\(o)") }
    }

    func testAmbiguousAsks() throws {
        let (h, m, _, _, _) = try setup()
        let o = try run(m, h, "mark the review done", #"{"intent":"change_item","operation":"complete","target_reference":"the review","target_id":null,"date_phrase":null,"days_before_deadline":null,"question":null}"#)
        guard case .resolution(.clarify) = o else { return XCTFail("\(o)") }
    }

    func testDatePhraseMustBeInTheText() throws {
        let (h, m, _, _, _) = try setup()
        let o = try run(m, h, "push the API task", #"{"intent":"change_item","operation":"reschedule","target_reference":"the API task","target_id":null,"date_phrase":"next friday","days_before_deadline":null,"question":null}"#)
        guard case .resolution(.needsDate) = o else { return XCTFail("invented date must be ignored: \(o)") }
    }

    func testDayBeforeDeadline() throws {
        let (h, m, api, research, app) = try setup()
        _ = api
        let p = try XCTUnwrap(proposal(try run(m, h, "Remind me about the application the day before it's due",
                                               #"{"intent":"change_item","operation":"remind","target_reference":"the application","target_id":null,"date_phrase":null,"days_before_deadline":1,"question":null}"#)))
        XCTAssertEqual(p.request.target.id, app.id.uuidString)
        XCTAssertEqual(p.request.parameters.date("at"), at(cal, 2026, 10, 19, 10))
        let noDeadline = try run(m, h, "remind me about the research review the day before it's due",
                                 #"{"intent":"change_item","operation":"remind","target_reference":"the research review","target_id":null,"date_phrase":null,"days_before_deadline":1,"question":null}"#)
        guard case let .resolution(.needsDate(msg)) = noDeadline else { return XCTFail() }
        XCTAssertTrue(msg.contains("no deadline"))
        _ = research
    }

    func testQuestionsAreAnsweredFromStoredData() throws {
        let (h, m, _, _, _) = try setup()
        let w = try h.add("Contract from legal", kind: .waiting); w.waitingOn = "Legal"
        guard case let .resolution(.answer(a)) = try run(m, h, "What am I waiting on?", #"{"intent":"question","operation":null,"target_reference":null,"target_id":null,"date_phrase":null,"days_before_deadline":null,"question":"waiting"}"#)
        else { return XCTFail() }
        XCTAssertEqual(a.lines.map(\.recordID), [w.id])
        XCTAssertTrue(a.basis.contains("stored"))
    }

    func testNewItemAndInvalidOutput() throws {
        let (h, m, _, _, _) = try setup()
        guard case .newItem = try run(m, h, "Call the plumber about the leak", #"{"intent":"new_item","operation":null,"target_reference":null,"target_id":null,"date_phrase":null,"days_before_deadline":null,"question":null}"#) else { return XCTFail() }
        guard case .invalid = try run(m, h, "x", "I think you want to delete everything") else { return XCTFail() }
        guard case .invalid = try run(m, h, "x", #"{"intent":"execute_shell","operation":null}"#) else { return XCTFail() }
    }

    /// Hard requirement: a model-assisted "remind" still needs confirmation, although the
    /// auto-remind standing rule would allow reminder scheduling for the scheduler.
    func testModelAssistedChangesAlwaysNeedConfirmation() async throws {
        let (h, m, _, _, app) = try setup()
        let p = try XCTUnwrap(proposal(try run(m, h, "Remind me about the application the day before it's due",
                                               #"{"intent":"change_item","operation":"remind","target_reference":"the application","target_id":null,"date_phrase":null,"days_before_deadline":1,"question":null}"#)))
        XCTAssertTrue(try h.policy.load().rules.contains(.autoRemindDeadlines))
        let r = await h.broker.submit(p.request)
        XCTAssertEqual(r.status, .awaitingConfirmation)
        XCTAssertNil(app.nextReminderAt)
        let ok = await h.broker.submit(p.request, confirmation: h.broker.confirm(p.request))
        XCTAssertEqual(ok.status, .succeeded)
        let replay = await h.broker.submit(p.request, confirmation: h.broker.confirm(p.request))
        XCTAssertEqual(replay.status, .succeeded, "a fresh confirmation is a new approval")
    }

    func testEndToEndThroughStubbedModel() async throws {
        RouteStub.reset()
        RouteStub.routes = ["/api/chat": RouteStub.chat(#"{"intent":"change_item","operation":"complete","target_reference":"the research review","target_id":null,"date_phrase":null,"days_before_deadline":null,"question":null}"#)]
        let (h, m, _, research, _) = try setup()
        let o = await m.interpret("Mark the research review complete", items: try h.store.all(), goals: [], context: .init(), now: now)
        XCTAssertEqual(proposal(o)?.request.target.id, research.id.uuidString)
        RouteStub.routes = [:]
        guard case .unavailable = await m.interpret("x", items: [], goals: [], context: .init(), now: now) else { return XCTFail() }
    }
}

@MainActor
final class DeterministicPhrasingTests: XCTestCase {
    let cal = calendar("Asia/Kolkata")
    var now: Date { at(cal, 2026, 10, 8, 12) }
    var r: ContextResolver { ContextResolver(calendar: cal, dateOnlyReminderHour: 10) }

    func testNaturalVariationsWithoutAModel() throws {
        let h = try Harness(now: now, calendar: cal)
        let api = try h.add("Submit the API review", deadline: at(cal, 2026, 10, 9))
        let research = try h.add("Research review with Dana")
        let app = try h.add("Scholarship application", deadline: at(cal, 2026, 10, 20))
        let all = try h.store.all()
        func target(_ t: String, _ ctx: ConversationContext = .init()) -> String? {
            if case let .proposal(p) = r.resolve(t, items: all, goals: [], context: ctx, now: now) { return p.request.target.id }
            return nil
        }
        XCTAssertEqual(target("Could you push that API task to next Wednesday?"), api.id.uuidString)
        XCTAssertEqual(target("I don't think I'm going to get that done this week. Move it to Sunday.", .init(recent: [research.id])), research.id.uuidString)
        XCTAssertEqual(target("Mark the research review complete"), research.id.uuidString)
        XCTAssertEqual(target("Remind me about the application the day before it's due"), app.id.uuidString)
        XCTAssertEqual(target("Please move the previous task to Monday", .init(recent: [app.id])), app.id.uuidString)
        XCTAssertEqual(target("Hmm, the research thing, just drop it", .init(recent: [research.id])), research.id.uuidString)
    }

    func testMoreQuestions() throws {
        let h = try Harness(now: now, calendar: cal)
        let p = try h.add("Write report"); for k in 1...3 { try h.store.snooze(p, until: now.addingTimeInterval(Double(k) * 60), now: now) }
        let done = try h.add("Pay rent"); try h.store.complete(done, now: now)
        let all = try h.store.all()
        func title(_ q: String) -> String? { if case let .answer(a) = r.resolve(q, items: all, goals: [], context: .init(), now: now) { a.title } else { nil } }
        XCTAssertEqual(title("Show me the things I keep postponing"), "Moved more than once (1)")
        XCTAssertEqual(title("What have I promised people recently?"), "Commitments from the last 14 days (2)")
        XCTAssertEqual(title("Which projects have gone quiet?"), "Nothing has gone quiet.")
        XCTAssertEqual(title("What did I finish this week?"), "Done in the last 7 days (1)")
        XCTAssertEqual(title("What's overdue?"), "Nothing is overdue.")
        // A plain capture is not mistaken for a question.
        if case .notACommand = r.resolve("Promised Sam I'd send the slides", items: all, goals: [], context: .init(), now: now) {} else { XCTFail() }
    }

    func testCueDetection() {
        XCTAssertTrue(ContextResolver.mightBeCommandOrQuestion("Could you push that to Friday"))
        XCTAssertTrue(ContextResolver.mightBeCommandOrQuestion("anything due?"))
        XCTAssertFalse(ContextResolver.mightBeCommandOrQuestion("Buy milk tomorrow"))
        XCTAssertFalse(ContextResolver.mightBeCommandOrQuestion("Submit the scholarship form by Friday"))
    }
}

/// Opt-in, runs against a real local Ollama: WREN_LIVE_OLLAMA=qwen2.5:3b swift test --filter LiveModelTests
@MainActor
final class LiveModelTests: XCTestCase {
    var model: String? { ProcessInfo.processInfo.environment["WREN_LIVE_OLLAMA"] }

    func testLiveDiagnosticsCaptureAndCommand() async throws {
        guard let model else { throw XCTSkip("set WREN_LIVE_OLLAMA=<model> to run against local Ollama") }
        let client = try OllamaClient()
        let report = await AIDiagnostics(client: client).fullTest(enabled: true, selected: model)
        guard case .ready = report.readiness else { return XCTFail("not ready: \(report.steps)") }

        let p = IntentProcessor(client: client, model: model)
        guard case let .interpreted(i, _) = await p.interpret("I need to submit the scholarship form by Friday.", now: .now) else { return XCTFail() }
        XCTAssertEqual(i.kind, .commitment)
        XCTAssertNotNil(i.deadline)
        guard case let .interpreted(idea, _) = await p.interpret("I might build an AI startup someday.", now: .now) else { return XCTFail() }
        XCTAssertNotEqual(idea.kind, .commitment)
        XCTAssertNil(idea.deadline)

        let cal = Calendar.current
        let h = try Harness(now: .now, calendar: cal)
        let api = try h.add("Submit the API review", deadline: cal.date(byAdding: .day, value: 1, to: .now))
        _ = try h.add("Buy groceries")
        let m = ModelCommandInterpreter(client: client, model: model, resolver: ContextResolver(calendar: cal))
        let o = await m.interpret("I won't manage it this week, could you push that API thing to next Wednesday?", items: try h.store.all(), goals: [], context: .init(), now: .now)
        guard case let .resolution(.proposal(prop)) = o else { return XCTFail("\(o)") }
        XCTAssertEqual(prop.request.target.id, api.id.uuidString)
        let r = await h.broker.submit(prop.request)
        XCTAssertEqual(r.status, .awaitingConfirmation)
    }
}
