import XCTest
@testable import WrenCore

/// Serves canned responses so tests never touch the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requestedHosts: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestedHosts.append(request.url?.host ?? "")
        guard let (code, data) = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class OllamaTests: XCTestCase {
    func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: c)
    }
    override func setUp() { StubProtocol.handler = nil; StubProtocol.requestedHosts = [] }

    // P3-13
    func testRejectsNonLocalHosts() {
        for s in ["https://api.openai.com", "http://192.168.1.5:11434", "http://example.com", "ftp://127.0.0.1"] {
            XCTAssertThrowsError(try OllamaClient(baseURL: URL(string: s)!), s)
        }
        for s in ["http://127.0.0.1:11434", "http://localhost:11434", "http://[::1]:11434"] {
            XCTAssertNoThrow(try OllamaClient(baseURL: URL(string: s)!), s)
        }
    }

    func testModelsFiltersEmbeddingOnly() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"models":[{"name":"nomic-embed-text:latest","capabilities":["embedding"]},{"name":"qwen2.5:3b","capabilities":["completion","tools"]},{"name":"old:1b"}]}"#.utf8)) }
        let models = try await OllamaClient(session: session()).models()
        XCTAssertEqual(models.filter(\.canChat).map(\.name), ["qwen2.5:3b", "old:1b"])
    }

    // P3-12
    func testUnreachableBecomesUnavailable() async throws {
        let cal = calendar("Asia/Kolkata")
        let p = IntentProcessor(client: try OllamaClient(session: session()), model: "qwen2.5:3b", calendar: cal)
        guard case .unavailable = await p.interpret("submit form friday", now: .now) else { return XCTFail() }
    }

    func testEndToEndWithStubbedModel() async throws {
        StubProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/api/chat")
            return (200, Data(#"{"message":{"role":"assistant","content":"{\"kind\":\"commitment\",\"title\":\"Submit the scholarship form\",\"priority\":\"normal\",\"deadline_phrase\":\"by Friday\"}"}}"#.utf8))
        }
        let cal = calendar("Asia/Kolkata")
        let p = IntentProcessor(client: try OllamaClient(session: session()), model: "qwen2.5:3b", calendar: cal)
        guard case let .interpreted(i, model) = await p.interpret("Submit the scholarship form by Friday.", now: at(cal, 2026, 10, 8, 15)) else { return XCTFail() }
        XCTAssertEqual(model, "qwen2.5:3b")
        XCTAssertEqual(i.deadline, at(cal, 2026, 10, 9))
        XCTAssertEqual(StubProtocol.requestedHosts, ["127.0.0.1"])
    }

    func testGarbageFromModelIsInvalid() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"message":{"role":"assistant","content":"I think you should rm -rf"}}"#.utf8)) }
        let p = IntentProcessor(client: try OllamaClient(session: session()), model: "m", calendar: .current)
        guard case .invalid = await p.interpret("x", now: .now) else { return XCTFail() }
    }

    /// Optional: runs against the real local Ollama when WREN_LIVE_OLLAMA=<model>.
    func testLiveOllama() async throws {
        guard let model = ProcessInfo.processInfo.environment["WREN_LIVE_OLLAMA"] else { throw XCTSkip("set WREN_LIVE_OLLAMA=<model>") }
        let p = IntentProcessor(client: try OllamaClient(), model: model)
        let out = await p.interpret("I need to submit the scholarship form by Friday.", now: .now)
        guard case let .interpreted(i, _) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(i.kind, .commitment)
        XCTAssertNotNil(i.deadline)
    }
}

/// P3-14: the core library can't spawn processes.
final class NoShellTests: XCTestCase {
    func testCoreHasNoProcessExecution() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/WrenCore").standardized
        // Every source file, subfolders included.
        let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 20)
        for f in files {
            let s = try String(contentsOf: f, encoding: .utf8)
            for banned in ["NSTask", "posix_spawn", "NSAppleScript", "popen("] {
                XCTAssertFalse(s.contains(banned), "\(f.lastPathComponent) contains \(banned)")
            }
            // Whole words only: `Process(` but not `heldByAnotherProcess(`; the C call `system(…)`, not
            // the audit origin `.system("…")` or its `case system(String)`.
            XCTAssertNil(s.range(of: #"(?<!\w)Process\("#, options: .regularExpression), "\(f.lastPathComponent) creates a Process")
            XCTAssertNil(s.range(of: #"(?<![\w.])(?<!case )system\("#, options: .regularExpression), "\(f.lastPathComponent) calls system(")
        }
    }
}
