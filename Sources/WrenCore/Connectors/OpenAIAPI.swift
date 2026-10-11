import Foundation

public struct OpenAIResult: Equatable, Sendable {
    public var text: String
    /// The model the API reports having used. Not inferred by Wren.
    public var reportedModel: String?
    public var status: String
    public var responseID: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
}

/// Optional OpenAI API client (`/v1/models`, `/v1/responses`). Separate from a ChatGPT subscription;
/// billed by OpenAI. Model names come from the account's model list, never hardcoded.
public struct OpenAIClient: Sendable {
    public var http: ConnectorHTTP
    public var key: @Sendable () throws -> String
    static let base = "https://api.openai.com/v1"

    public init(session: URLSession = .shared, key: @escaping @Sendable () throws -> String) {
        var h = ConnectorHTTP(allowedHosts: ["api.openai.com"], session: session)
        h.timeout = 120
        http = h
        self.key = key
    }

    public func models() async throws -> [String] {
        let v = try await http.json(URL(string: Self.base + "/models")!, headers: ["Authorization": "Bearer \(try key())"])
        return (v["data"]?.array.compactMap { $0["id"]?.string } ?? []).sorted()
    }

    public func respond(model: String, input: String, instructions: String?) async throws -> OpenAIResult {
        var body: [String: JSONValue] = ["model": .string(model), "input": .string(input)]
        if let instructions { body["instructions"] = .string(instructions) }
        let v = try await http.json(URL(string: Self.base + "/responses")!, method: "POST",
                                    headers: ["Authorization": "Bearer \(try key())"], body: .object(body))
        return try Self.parse(v)
    }

    public static func parse(_ v: JSONValue) throws -> OpenAIResult {
        if let e = v["error"], case .object = e { throw ConnectorError.badResponse(e["message"]?.string ?? "error") }
        let texts = v["output"]?.array.filter { $0["type"]?.string == "message" }
            .flatMap { $0["content"]?.array ?? [] }
            .filter { $0["type"]?.string == "output_text" }
            .compactMap { $0["text"]?.string } ?? []
        let status = v["status"]?.string ?? "unknown"
        guard !texts.isEmpty else { throw ConnectorError.badResponse("no text in response (status \(status))") }
        return OpenAIResult(text: texts.joined(separator: "\n\n"), reportedModel: v["model"]?.string, status: status,
                            responseID: v["id"]?.string, inputTokens: v["usage"]?["input_tokens"]?.number.map(Int.init),
                            outputTokens: v["usage"]?["output_tokens"]?.number.map(Int.init))
    }
}
