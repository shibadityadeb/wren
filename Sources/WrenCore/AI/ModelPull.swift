import Foundation

/// One progress update while Ollama downloads a model.
public struct PullUpdate: Sendable, Equatable {
    public var status: String
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var done: Bool
    /// 0…1 when sizes are known.
    public var fraction: Double? { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : nil }
}

/// Folds Ollama's streamed pull lines (one JSON object per line) into overall progress.
/// Layers are tracked by digest so progress across several files adds up correctly.
public struct PullAggregator: Sendable {
    var layers: [String: (completed: Int64, total: Int64)] = [:]
    public init() {}

    public mutating func consume(_ line: String) throws -> PullUpdate? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              case let .object(o)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw OllamaError.badResponse(String(trimmed.prefix(120)))
        }
        if case let .string(e)? = o["error"] { throw OllamaError.pullFailed(e) }
        let status: String = { if case let .string(s)? = o["status"] { s } else { "" } }()
        if case let .string(digest)? = o["digest"] {
            var l = layers[digest] ?? (0, 0)
            if case let .number(t)? = o["total"] { l.total = Int64(t) }
            if case let .number(c)? = o["completed"] { l.completed = Int64(c) }
            layers[digest] = l
        }
        let total = layers.values.reduce(0) { $0 + $1.total }
        let done = layers.values.reduce(0) { $0 + min($1.completed, $1.total) }
        return PullUpdate(status: status, completedBytes: done, totalBytes: total, done: status == "success")
    }
}

extension OllamaClient {
    /// Ollama model names: `name`, `name:tag`, or `namespace/name:tag`. Anything else is refused,
    /// so no arbitrary text is ever passed through.
    public static func isValidModelName(_ s: String) -> Bool {
        guard (1...80).contains(s.count) else { return false }
        return s.wholeMatch(of: /[a-z0-9][a-z0-9._-]*(\/[a-z0-9][a-z0-9._-]*)?(:[a-zA-Z0-9][a-zA-Z0-9._-]*)?/) != nil
    }

    /// Streams a model download from Ollama's local `/api/pull`. Cancelling the consuming task
    /// cancels the request. Throws if Ollama reports an error or the stream ends without "success".
    public func pull(model: String) -> AsyncThrowingStream<PullUpdate, Error> {
        AsyncThrowingStream { continuation in
            guard Self.isValidModelName(model) else {
                continuation.finish(throwing: OllamaError.invalidModelName(model)); return
            }
            let task = Task {
                do {
                    var req = URLRequest(url: baseURL.appendingPathComponent("api/pull"), timeoutInterval: 120)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONEncoder().encode(JSONValue.object(["model": .string(model), "stream": .bool(true)]))
                    let (bytes, resp) = try await session.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw OllamaError.http(http.statusCode) }
                    var agg = PullAggregator()
                    var succeeded = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let u = try agg.consume(line) {
                            continuation.yield(u)
                            if u.done { succeeded = true }
                        }
                    }
                    if succeeded { continuation.finish() } else { continuation.finish(throwing: OllamaError.pullFailed("The download stopped before it finished.")) }
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let e as OllamaError {
                    continuation.finish(throwing: e)
                } catch let e as URLError where e.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: OllamaClient.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension OllamaClient {
    /// Runs a pull to the end. Unlike iterating the stream directly (which just stops when the
    /// caller is cancelled), this always ends in one of: returns the final update (success),
    /// throws CancellationError, or throws an OllamaError.
    public func pullToCompletion(model: String, onUpdate: @Sendable (PullUpdate) async -> Void) async throws -> PullUpdate {
        var last: PullUpdate?
        for try await u in pull(model: model) {
            last = u
            await onUpdate(u)
        }
        try Task.checkCancellation()
        guard let final = last, final.done else { throw OllamaError.pullFailed("The download stopped before it finished.") }
        return final
    }
}
