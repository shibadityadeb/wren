import Foundation

public struct ChatGPTModel: Codable, Equatable, Sendable, Identifiable, Hashable {
    public var slug: String
    public var displayName: String
    public var id: String { slug }
    public init(slug: String, displayName: String) { self.slug = slug; self.displayName = displayName }
}

public struct ChatGPTReply: Equatable, Sendable {
    public var text: String
    /// The model Wren asked for.
    public var requestedModel: String
    /// The model the completed response reports, when it does.
    public var reportedModel: String?
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

    public init() {}

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
        case "response.completed":
            completed = true
            reportedModel = e["response"]?["model"]?.string
            return nil
        case "response.failed", "error":
            throw ChatGPTError.from(status: nil, code: ChatGPTError.errorCode(e))
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
            return ChatGPTModel(slug: slug, displayName: name)
        }
    }

    public static func requestBody(model: String, input: String, instructions: String?) throws -> Data {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "input": .array([.object(["role": .string("user"), "content": .string(input)])]),
            "store": .bool(false),
            "stream": .bool(true),
        ]
        if let instructions { body["instructions"] = .string(instructions) }
        return try JSONEncoder().encode(JSONValue.object(body))
    }

    /// Streams one answer. `onDelta` receives text as it arrives.
    public func respond(model: String, input: String, instructions: String? = nil,
                        onDelta: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ChatGPTReply {
        let body = try Self.requestBody(model: model, input: input, instructions: instructions)
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
        return ChatGPTReply(text: state.text, requestedModel: model, reportedModel: state.reportedModel)
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
