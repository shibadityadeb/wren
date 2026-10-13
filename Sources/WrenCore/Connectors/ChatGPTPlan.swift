import Foundation

public struct ChatGPTModel: Codable, Equatable, Sendable, Identifiable, Hashable {
    public var slug: String
    public var displayName: String
    /// Reasoning efforts the model list says this model accepts, when it says (`supported_reasoning_levels`).
    /// nil: the list didn't say, so Wren can't know before asking.
    public var reasoningEfforts: [String]?
    public var id: String { slug }
    public init(slug: String, displayName: String, reasoningEfforts: [String]? = nil) {
        self.slug = slug; self.displayName = displayName; self.reasoningEfforts = reasoningEfforts
    }

    /// The effort to request for "think deeply": "high" when allowed, otherwise the strongest the
    /// model lists. nil when the model lists none (it doesn't take a reasoning setting).
    public func effort(forDeepThinking wanted: String = "high") -> String? {
        guard let levels = reasoningEfforts else { return wanted }
        if levels.contains(wanted) { return wanted }
        let order = ["minimal", "low", "medium", "high"]
        return levels.filter { order.contains($0) }.max { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }
    }
}

/// What Wren asks of the model beyond the text. Each is sent only when the user's words call for it.
public struct ResponseOptions: Equatable, Sendable {
    /// `reasoning.effort`, e.g. "high". nil: the model's default.
    public var reasoningEffort: String?
    /// Offer the hosted `web_search` tool (subject to model and account/workspace policy).
    public var webSearch: Bool
    public init(reasoningEffort: String? = nil, webSearch: Bool = false) { self.reasoningEffort = reasoningEffort; self.webSearch = webSearch }
    public static let standard = ResponseOptions()
}

public struct ChatGPTReply: Equatable, Sendable {
    public var text: String
    /// The model Wren asked for.
    public var requestedModel: String
    /// The model the completed response reports, when it does.
    public var reportedModel: String?
    /// The reasoning effort the completed response reports, when it does.
    public var reportedEffort: String? = nil
    /// Web searches the response actually performed.
    public var webSearchCalls: Int = 0
    /// Sources cited in the answer.
    public var sources: [CitedSource] = []
}

/// Server-sent events: collects `data:` lines into one payload per event (blank line ends an event).
public struct SSEParser: Sendable {
    var data: [String] = []
    public init() {}

    public mutating func feed(_ rawLine: String) -> String? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("data:") {
            var v = line.dropFirst(5)
            if v.first == " " { v = v.dropFirst() }
            data.append(String(v))
        }
        return nil
    }

    public mutating func flush() -> String? {
        guard !data.isEmpty else { return nil }
        defer { data = [] }
        return data.joined(separator: "\n")
    }
}

/// Applies Responses API stream events. Success is only `response.completed`.
public struct ResponseStreamState: Sendable {
    public private(set) var text = ""
    public private(set) var completed = false
    public private(set) var reportedModel: String?
    public private(set) var reportedEffort: String?
    /// Web searches seen as finished output items (and, at completion, in the final output).
    public private(set) var webSearchCalls = 0
    public private(set) var sources: [CitedSource] = []

    public init() {}

    mutating func collectCitations(in item: JSONValue) {
        guard case let .array(content)? = item["content"] else { return }
        for part in content {
            guard case let .array(annotations)? = part["annotations"] else { continue }
            annotations.forEach { cite($0) }
        }
    }

    /// One `url_citation`, kept once, web links only.
    mutating func cite(_ a: JSONValue) {
        guard a["type"]?.string == "url_citation", let url = a["url"]?.string, url.hasPrefix("https://") || url.hasPrefix("http://"),
              url.count <= 2048, !sources.contains(where: { $0.url == url }), sources.count < 50 else { return }
        sources.append(CitedSource(title: String((a["title"]?.string ?? url).prefix(300)), url: url))
    }

    /// Returns the new text delta, if any. Throws on failure events.
    public mutating func apply(_ payload: String) throws -> String? {
        if payload == "[DONE]" { return nil }
        guard let d = payload.data(using: .utf8), let e = try? JSONDecoder().decode(JSONValue.self, from: d) else {
            throw ChatGPTError.invalidResponse("stream event")
        }
        switch e["type"]?.string {
        case "response.output_text.delta":
            guard let delta = e["delta"]?.string else { return nil }
            text += delta
            return delta
        case "response.output_text.annotation.added":
            if let a = e["annotation"] { cite(a) }
            return nil
        case "response.output_item.done":
            // Seen live on the plan route: the completed event's `output` is empty, so web searches
            // and citations are counted from the items as they finish.
            switch e["item"]?["type"]?.string {
            case "web_search_call": webSearchCalls += 1
            case "message"?: if let item = e["item"] { collectCitations(in: item) }
            default: break
            }
            return nil
        case "response.completed":
            completed = true
            let r = e["response"]
            reportedModel = r?["model"]?.string
            reportedEffort = r?["reasoning"]?["effort"]?.string
            if case let .array(output)? = r?["output"] {
                // When the final output is present it's authoritative for what ran.
                webSearchCalls = max(webSearchCalls, output.filter { $0["type"]?.string == "web_search_call" }.count)
                for item in output { collectCitations(in: item) }
            }
            return nil
        case "response.failed", "error":
            throw ChatGPTError.from(status: nil, code: ChatGPTError.errorCode(e), param: ChatGPTError.errorParam(e))
        case "response.incomplete":
            throw ChatGPTError.incomplete(partial: text)
        default:
            return nil
        }
    }
}

/// Model discovery and inference against `api.openai.com/v1` using the signed-in user's ChatGPT plan.
/// Requests carry only the user's access token. Nothing is stored server-side (`store: false`).
public struct ChatGPTPlanClient: Sendable {
    public var http: ConnectorHTTP
    /// A valid access token; `true` forces a refresh (after a 401).
    public var token: @Sendable (Bool) async throws -> String
    static let base = "https://api.openai.com/v1"

    public init(session: URLSession = .shared, token: @escaping @Sendable (Bool) async throws -> String) {
        var h = ConnectorHTTP(allowedHosts: ["api.openai.com"], session: session)
        h.timeout = 120
        http = h
        self.token = token
    }

    /// Models this connection can use (`visibility == "list"`). Never hardcoded.
    public func models() async throws -> [ChatGPTModel] {
        let (data, resp) = try await withRetryOn401 { t in
            try await http.raw(URL(string: Self.base + "/models")!, headers: ["Authorization": "Bearer \(t)", "Accept": "application/json"], timeout: 20)
        }
        guard resp.statusCode == 200 else { throw ChatGPTError.from(status: resp.statusCode, body: data) }
        return try Self.parseModels(data)
    }

    public static func parseModels(_ data: Data) throws -> [ChatGPTModel] {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: data), let list = v["models"], case let .array(items) = list else {
            throw ChatGPTError.invalidResponse("model list")
        }
        return try items.compactMap { m in
            guard m["visibility"]?.string == "list" else { return nil }
            guard let slug = m["slug"]?.string?.trimmingCharacters(in: .whitespaces), !slug.isEmpty, slug.count <= 200,
                  let name = m["display_name"]?.string?.trimmingCharacters(in: .whitespaces), !name.isEmpty, name.count <= 200 else {
                throw ChatGPTError.invalidResponse("model list")
            }
            // Optional: `supported_reasoning_levels: [{"effort": "high", …}]` or `["low", "high"]`.
            var efforts: [String]?
            if case let .array(levels)? = m["supported_reasoning_levels"] {
                efforts = levels.compactMap { $0["effort"]?.string ?? $0.string }.filter { $0.count <= 20 }
            }
            return ChatGPTModel(slug: slug, displayName: name, reasoningEfforts: efforts)
        }
    }

    /// The plan route requires `store: false` and `stream: true`; it rejects sampling and background
    /// fields, so none are sent. `reasoning` and the `web_search` tool are added only when asked for.
    public static func requestBody(model: String, input: String, instructions: String?, options: ResponseOptions = .standard) throws -> Data {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "input": .array([.object(["role": .string("user"), "content": .string(input)])]),
            "store": .bool(false),
            "stream": .bool(true),
        ]
        if let instructions { body["instructions"] = .string(instructions) }
        if let effort = options.reasoningEffort { body["reasoning"] = .object(["effort": .string(effort)]) }
        if options.webSearch { body["tools"] = .array([.object(["type": .string("web_search")])]) }
        return try JSONEncoder().encode(JSONValue.object(body))
    }

    /// Streams one answer. `onDelta` receives text as it arrives.
    public func respond(model: String, input: String, instructions: String? = nil, options: ResponseOptions = .standard,
                        onDelta: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ChatGPTReply {
        let body = try Self.requestBody(model: model, input: input, instructions: instructions, options: options)
        let (bytes, resp) = try await withRetryOn401 { t in
            try await http.stream(URL(string: Self.base + "/responses")!,
                                  headers: ["Authorization": "Bearer \(t)", "Content-Type": "application/json", "Accept": "text/event-stream"],
                                  body: body, timeout: 300)
        } status: { $0.1.statusCode }
        guard (200..<300).contains(resp.statusCode) else {
            var collected = Data()
            do { for try await b in bytes { collected.append(b); if collected.count > 65_536 { break } } } catch {}
            throw ChatGPTError.from(status: resp.statusCode, body: collected)
        }
        if let ct = resp.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(),
           !ct.isEmpty, ct != "text/event-stream" {
            throw ChatGPTError.invalidResponse("not a response stream")
        }
        var parser = SSEParser(), state = ResponseStreamState()
        var line = Data()
        func handle(_ payload: String) throws { if let d = try state.apply(payload) { onDelta(d) } }
        do {
            for try await b in bytes {
                if b == UInt8(ascii: "\n") {
                    if let p = parser.feed(String(decoding: line, as: UTF8.self)) { try handle(p) }
                    line.removeAll(keepingCapacity: true)
                } else { line.append(b) }
            }
            if !line.isEmpty, let p = parser.feed(String(decoding: line, as: UTF8.self)) { try handle(p) }
            if let p = parser.flush() { try handle(p) }
        } catch let e as ChatGPTError {
            throw e
        } catch {
            throw ChatGPTError.interrupted(partial: state.text)
        }
        guard state.completed else { throw ChatGPTError.interrupted(partial: state.text) }
        return ChatGPTReply(text: state.text, requestedModel: model, reportedModel: state.reportedModel, reportedEffort: state.reportedEffort,
                            webSearchCalls: state.webSearchCalls, sources: state.sources)
    }

    func withRetryOn401(_ op: (String) async throws -> (Data, HTTPURLResponse)) async throws -> (Data, HTTPURLResponse) {
        try await withRetryOn401(op) { $0.1.statusCode }
    }

    /// One retry with a refreshed token when the first attempt got 401.
    func withRetryOn401<R>(_ op: (String) async throws -> R, status: (R) -> Int) async throws -> R {
        do {
            let first = try await op(try await token(false))
            guard status(first) == 401 else { return first }
            return try await op(try await token(true))
        } catch let e as ChatGPTError { throw e } catch { throw ChatGPTError.fromTransport(error) }
    }
}
