import Foundation

/// The truthful state of local AI. "Ready" is only ever set after a real model request succeeded.
public enum AIReadiness: Equatable, Sendable {
    /// The user turned the language model off.
    case disabled
    case checking
    /// No Ollama app or command-line tool found, and nothing answers on the local port.
    case notInstalled
    /// Ollama is installed but its local service isn't answering.
    case notRunning
    /// Ollama answers but has no model that can chat (embedding models don't count).
    case noChatModel
    /// Chat models exist but none is selected (or the selected one was removed).
    case selectModel([String])
    /// A model is selected and installed but hasn't answered a request yet this session.
    case configured(model: String, models: [String])
    /// The selected model answered a real request and the answer parsed.
    case ready(model: String, models: [String], verifiedAt: Date, latencyMs: Int)
    /// A configured model failed to respond or returned something unusable.
    case unavailable(model: String, models: [String], reason: String)

    public var title: String {
        switch self {
        case .disabled: "Local AI is off"
        case .checking: "Checking local AI…"
        case .notInstalled: "Setup required"
        case .notRunning: "Start Ollama"
        case .noChatModel: "Download a model"
        case .selectModel: "Select a model"
        case let .configured(m, _): "\(m) selected, not yet tested"
        case let .ready(m, _, _, _): "Ready: \(m)"
        case let .unavailable(m, _, _): "\(m) is temporarily unavailable"
        }
    }

    public var detail: String {
        switch self {
        case .disabled: "Wren reads dates with built-in rules and saves everything. Turn local AI on for better titles, classification and commands."
        case .checking: ""
        case .notInstalled: "Wren's AI runs on this Mac through Ollama, a free app. It isn't installed. Nothing you type leaves your Mac."
        case .notRunning: "Ollama is installed but its local service isn't answering on 127.0.0.1:11434."
        case .noChatModel: "Ollama is running but has no chat model. Embedding-only models can't understand requests."
        case .selectModel: "Choose which installed model Wren should use."
        case .configured: "Run “Test local AI” to confirm it answers. Wren also confirms it the first time it uses it."
        case let .ready(_, _, at, ms): "Answered a test request at \(at.formatted(date: .omitted, time: .shortened)) in \(ms) ms."
        case let .unavailable(_, _, r): r
        }
    }

    /// Wren may try the model (and will update the state from the result).
    public var usableModel: String? {
        switch self {
        case let .configured(m, _), let .ready(m, _, _, _): m
        default: nil
        }
    }
    public var isReady: Bool { if case .ready = self { true } else { false } }
    public var installedModels: [String] {
        switch self {
        case let .selectModel(m): m
        case let .configured(_, m), let .ready(_, m, _, _), let .unavailable(_, m, _): m
        default: []
        }
    }
}

/// Where Ollama can be installed. File checks only; nothing is executed.
public protocol OllamaInstallProbe: Sendable {
    func isInstalled() -> Bool
    /// The Ollama app bundle, if present (Wren can ask macOS to open it).
    func appURL() -> URL?
}

public struct FileSystemOllamaProbe: OllamaInstallProbe {
    public init() {}
    static var appPaths: [String] { ["/Applications/Ollama.app", NSHomeDirectory() + "/Applications/Ollama.app"] }
    static let cliPaths = ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"]
    public func appURL() -> URL? {
        Self.appPaths.first { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    public func isInstalled() -> Bool {
        appURL() != nil || Self.cliPaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

public struct ModelSuggestion: Sendable, Equatable, Identifiable {
    public var name: String
    public var approxBytes: Int64
    public var note: String
    public var id: String { name }

    /// Recommended first: matches the project docs and suits 8 GB of RAM.
    public static let recommended: [ModelSuggestion] = [
        .init(name: "qwen2.5:3b", approxBytes: 1_900_000_000, note: "Recommended for Macs with 8 GB of memory."),
        .init(name: "llama3.2:3b", approxBytes: 2_000_000_000, note: "Similar size; an alternative if Qwen doesn't suit you."),
        .init(name: "qwen2.5:1.5b", approxBytes: 990_000_000, note: "Smaller and faster, but understands less."),
    ]
}

public struct DiagnosticStep: Sendable, Equatable, Identifiable {
    public enum Outcome: String, Sendable { case passed, failed, skipped }
    public var name: String
    public var outcome: Outcome
    public var detail: String
    public var id: String { name }
}

public struct DiagnosticReport: Sendable, Equatable {
    public var steps: [DiagnosticStep]
    public var readiness: AIReadiness
}

/// Checks local AI step by step. Talks only to the loopback Ollama endpoint.
public struct AIDiagnostics: Sendable {
    public var client: OllamaClient
    public var probe: OllamaInstallProbe
    public var clock: @Sendable () -> Date

    public init(client: OllamaClient, probe: OllamaInstallProbe = FileSystemOllamaProbe(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client; self.probe = probe; self.clock = clock
    }

    /// Cheap check (no model loaded): service, installed models, selection.
    public func readiness(enabled: Bool, selected: String?) async -> AIReadiness {
        await run(enabled: enabled, selected: selected, test: false).readiness
    }

    /// Full test including a small, harmless request to the selected model.
    public func fullTest(enabled: Bool, selected: String?) async -> DiagnosticReport {
        await run(enabled: enabled, selected: selected, test: true)
    }

    static let testSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["ok": .object(["type": .string("boolean")]), "word": .object(["type": .string("string")])]),
        "required": .array([.string("ok"), .string("word")]),
    ])

    func run(enabled: Bool, selected: String?, test: Bool) async -> DiagnosticReport {
        var steps: [DiagnosticStep] = []
        guard enabled else { return DiagnosticReport(steps: [], readiness: .disabled) }

        let version: String
        do { version = try await client.version() } catch {
            let installed = probe.isInstalled()
            steps.append(.init(name: "Ollama service", outcome: .failed,
                               detail: installed ? "Installed, but not answering on 127.0.0.1:11434." : "Ollama isn't installed."))
            return DiagnosticReport(steps: steps, readiness: installed ? .notRunning : .notInstalled)
        }
        steps.append(.init(name: "Ollama service", outcome: .passed, detail: "Running, version \(version)."))

        let all: [OllamaModel]
        do { all = try await client.models() } catch {
            steps.append(.init(name: "Installed models", outcome: .failed, detail: (error as? LocalizedError)?.errorDescription ?? "\(error)"))
            return DiagnosticReport(steps: steps, readiness: .notRunning)
        }
        let chat = all.filter(\.canChat).map(\.name)
        let skipped = all.count - chat.count
        steps.append(.init(name: "Installed models", outcome: chat.isEmpty ? .failed : .passed,
                           detail: chat.isEmpty ? "No chat model\(skipped > 0 ? " (\(skipped) embedding-only model\(skipped == 1 ? "" : "s") can't be used)" : "")."
                                                : "\(chat.joined(separator: ", "))\(skipped > 0 ? " (+\(skipped) embedding-only, not usable)" : "")"))
        guard !chat.isEmpty else { return DiagnosticReport(steps: steps, readiness: .noChatModel) }
        guard let model = selected, chat.contains(model) else {
            steps.append(.init(name: "Selected model", outcome: .failed, detail: selected.map { "“\($0)” is no longer installed." } ?? "No model selected."))
            return DiagnosticReport(steps: steps, readiness: .selectModel(chat))
        }
        steps.append(.init(name: "Selected model", outcome: .passed, detail: model))
        guard test else { return DiagnosticReport(steps: steps, readiness: .configured(model: model, models: chat)) }

        let start = clock()
        let raw: String
        do {
            raw = try await client.chatJSON(model: model, system: "You are a health check. Reply with JSON only.",
                                            user: "Reply with {\"ok\": true, \"word\": \"wren\"}.", schema: Self.testSchema, timeout: 90)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            steps.append(.init(name: "Test request", outcome: .failed, detail: reason))
            return DiagnosticReport(steps: steps, readiness: .unavailable(model: model, models: chat, reason: "The model didn't answer: \(reason)"))
        }
        let ms = Int(clock().timeIntervalSince(start) * 1000)
        steps.append(.init(name: "Test request", outcome: .passed, detail: "Answered in \(ms) ms."))
        guard let data = raw.data(using: .utf8), case let .object(o)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .bool(true)? = o["ok"] else {
            steps.append(.init(name: "Answer format", outcome: .failed, detail: "The answer wasn't the expected JSON: \(raw.prefix(80))"))
            return DiagnosticReport(steps: steps, readiness: .unavailable(model: model, models: chat, reason: "The model answered, but not in a usable format."))
        }
        steps.append(.init(name: "Answer format", outcome: .passed, detail: "Valid structured JSON."))
        return DiagnosticReport(steps: steps, readiness: .ready(model: model, models: chat, verifiedAt: clock(), latencyMs: ms))
    }

    public static func freeDiskBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
}
