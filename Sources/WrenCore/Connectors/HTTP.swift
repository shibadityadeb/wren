import Foundation

public enum ConnectorError: Error, Equatable, LocalizedError {
    case hostNotAllowed(String)
    case notConfigured(String)
    case unauthorized
    case forbidden(String)
    case rateLimited(retryAfter: TimeInterval?)
    case server(Int)
    case http(Int, String)
    case network(String)
    case timedOut
    case badResponse(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .hostNotAllowed(h): "Refused: \(h) isn't an allowed address for this connector."
        case let .notConfigured(s): s
        case .unauthorized: "The connection was rejected (token expired or revoked). Reconnect."
        case let .forbidden(s): "Access denied: \(s)"
        case let .rateLimited(r): "Rate limited by the service\(r.map { "; retry in \(Int($0)) s" } ?? "")."
        case let .server(c): "The service had a problem (HTTP \(c)). Try again later."
        case let .http(c, m): "HTTP \(c): \(m)"
        case let .network(m): "Network error: \(m)"
        case .timedOut: "The service didn't answer in time."
        case let .badResponse(m): "Unexpected response: \(m)"
        case .cancelled: "Cancelled."
        }
    }
}

/// HTTPS client bound to one connector's host allowlist. Never logs bodies or headers.
public struct ConnectorHTTP: Sendable {
    public let allowedHosts: Set<String>
    public let session: URLSession
    public var timeout: TimeInterval = 30

    public init(allowedHosts: Set<String>, session: URLSession = .shared) {
        self.allowedHosts = allowedHosts; self.session = session
    }

    public func check(_ url: URL) throws {
        guard url.scheme == "https", let host = url.host?.lowercased(), allowedHosts.contains(host) else {
            throw ConnectorError.hostNotAllowed(url.host ?? url.absoluteString)
        }
    }

    /// Sends the request and returns the body and status without interpreting the status.
    public func raw(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
                    timeout: TimeInterval? = nil) async throws -> (Data, HTTPURLResponse) {
        let r = try makeRequest(url, method: method, headers: headers, body: body, timeout: timeout)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: r) } catch { throw Self.mapTransport(error) }
        guard let http = resp as? HTTPURLResponse else { throw ConnectorError.badResponse("no HTTP response") }
        return (data, http)
    }

    /// Opens a streamed response. The caller reads the bytes and checks the status.
    public func stream(_ url: URL, method: String = "POST", headers: [String: String] = [:], body: Data? = nil,
                       timeout: TimeInterval? = nil) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let r = try makeRequest(url, method: method, headers: headers, body: body, timeout: timeout)
        let bytes: URLSession.AsyncBytes, resp: URLResponse
        do { (bytes, resp) = try await session.bytes(for: r) } catch { throw Self.mapTransport(error) }
        guard let http = resp as? HTTPURLResponse else { throw ConnectorError.badResponse("no HTTP response") }
        return (bytes, http)
    }

    func makeRequest(_ url: URL, method: String, headers: [String: String], body: Data?, timeout: TimeInterval?) throws -> URLRequest {
        try check(url)
        var r = URLRequest(url: url, timeoutInterval: timeout ?? self.timeout)
        r.httpMethod = method
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = body
        return r
    }

    public static func mapTransport(_ error: Error) -> ConnectorError {
        if let e = error as? ConnectorError { return e }
        if error is CancellationError { return .cancelled }
        guard let e = error as? URLError else { return .network("unknown") }
        switch e.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        default: return .network("error \(e.code.rawValue)")
        }
    }

    public func request(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
                        timeout: TimeInterval? = nil) async throws -> Data {
        let (data, http) = try await raw(url, method: method, headers: headers, body: body, timeout: timeout)
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw ConnectorError.unauthorized
        case 403: throw ConnectorError.forbidden(Self.message(data) ?? "forbidden")
        case 429: throw ConnectorError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        case 500...: throw ConnectorError.server(http.statusCode)
        default: throw ConnectorError.http(http.statusCode, Self.message(data) ?? "")
        }
    }

    public func json(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: JSONValue? = nil) async throws -> JSONValue {
        var h = headers
        var data: Data?
        if let body { data = try JSONEncoder().encode(body); h["Content-Type"] = "application/json" }
        let out = try await request(url, method: method, headers: h, body: data)
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: out) else { throw ConnectorError.badResponse(String(decoding: out.prefix(120), as: UTF8.self)) }
        return v
    }

    /// Short, non-sensitive error text from common API error shapes.
    static func message(_ data: Data) -> String? {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: data), case let .object(o) = v else { return nil }
        if case let .object(e)? = o["error"], case let .string(m)? = e["message"] { return String(m.prefix(160)) }
        if case let .string(code)? = o["error"], case let .string(m)? = o["error_description"] { return String("\(code): \(m)".prefix(160)) }
        if case let .string(m)? = o["error_description"] { return String(m.prefix(160)) }
        if case let .string(m)? = o["message"] { return String(m.prefix(160)) }
        if case let .string(m)? = o["error"] { return String(m.prefix(160)) }
        return nil
    }
}

// MARK: JSON navigation helpers

public extension JSONValue {
    subscript(_ k: String) -> JSONValue? { if case let .object(o) = self { o[k] } else { nil } }
    var string: String? { if case let .string(s) = self { s } else { nil } }
    var array: [JSONValue] { if case let .array(a) = self { a } else { [] } }
    var number: Double? { if case let .number(n) = self { n } else { nil } }
    var bool: Bool? { if case let .bool(b) = self { b } else { nil } }
}
