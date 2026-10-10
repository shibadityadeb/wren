import Foundation

public enum OllamaError: Error, LocalizedError, Equatable {
    case nonLocalHost(String)
    case unreachable(String)
    case http(Int)
    case badResponse(String)
    case noModelSelected
    case pullFailed(String)
    case timedOut
    case invalidModelName(String)

    public var errorDescription: String? {
        switch self {
        case let .nonLocalHost(h): "Wren only talks to a model on this Mac. “\(h)” is not a local address."
        case let .unreachable(r): "Ollama is not reachable: \(r)"
        case let .http(code): "Ollama returned HTTP \(code)."
        case let .badResponse(r): "Unexpected response from Ollama: \(r)"
        case .noModelSelected: "No language model selected."
        case let .pullFailed(m): "The model download failed: \(m)"
        case .timedOut: "The local model timed out. It may still be loading; try again in a moment."
        case let .invalidModelName(n): "“\(n)” isn't a valid Ollama model name."
        }
    }
}

public struct OllamaModel: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var size: Int64?
    public var capabilities: [String]?
    public var id: String { name }
    /// Embedding-only models cannot chat. Older Ollama versions omit capabilities; assume chat.
    public var canChat: Bool { capabilities.map { $0.contains("completion") } ?? true }
}

/// Talks only to a local Ollama server. There is no code path to any other host.
public struct OllamaClient: Sendable {
    public static let defaultURL = URL(string: "http://127.0.0.1:11434")!
    public static let allowedHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    public let baseURL: URL
    public let session: URLSession

    public init(baseURL: URL = OllamaClient.defaultURL, session: URLSession = .shared) throws {
        guard let host = baseURL.host?.lowercased(), Self.allowedHosts.contains(host),
              ["http", "https"].contains(baseURL.scheme?.lowercased() ?? "") else {
            throw OllamaError.nonLocalHost(baseURL.host ?? baseURL.absoluteString)
        }
        self.baseURL = baseURL
        self.session = session
    }

    public func version() async throws -> String {
        struct V: Decodable { var version: String }
        return try await get("api/version", as: V.self, timeout: 2).version
    }

    public func models() async throws -> [OllamaModel] {
        struct Tags: Decodable { var models: [OllamaModel] }
        return try await get("api/tags", as: Tags.self, timeout: 3).models
    }

    struct ChatRequest: Encodable {
        struct Message: Encodable { var role: String; var content: String }
        struct Options: Encodable { var temperature: Double; var num_ctx: Int }
        var model: String
        var messages: [Message]
        var stream = false
        var format: JSONValue
        var options = Options(temperature: 0, num_ctx: 4096)
        var keep_alive = "5m"
    }

    /// Returns the assistant message content, which the caller must validate.
    public func chatJSON(model: String, system: String, user: String, schema: JSONValue,
                         timeout: TimeInterval = 45) async throws -> String {
        struct Reply: Decodable { struct M: Decodable { var content: String }; var message: M }
        let body = ChatRequest(model: model, messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
                               format: schema)
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"), timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return try await send(req, as: Reply.self).message.content
    }

    static func map(_ error: Error) -> OllamaError {
        if let u = error as? URLError {
            switch u.code {
            case .timedOut: return .timedOut
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                return .unreachable("nothing is answering on the local Ollama port")
            default: return .unreachable("network error \(u.code.rawValue)")
            }
        }
        return .unreachable(error.localizedDescription)
    }

    private func get<T: Decodable>(_ path: String, as: T.Type, timeout: TimeInterval) async throws -> T {
        try await send(URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout), as: T.self)
    }

    private func send<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch {
            throw Self.map(error)
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw OllamaError.http(http.statusCode) }
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw OllamaError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
    }
}
