import Foundation

/// Secret storage. The app uses `FileCredentialStore` (private files in Wren's data folder); tests use memory.
public protocol CredentialStore: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ key: String, _ value: Data) throws
    func delete(_ key: String) throws
}

public enum CredentialError: Error, Equatable, LocalizedError {
    case keychain(OSStatus)
    case badKey(String)
    case file(String)
    public var errorDescription: String? {
        switch self {
        case let .keychain(s): "Keychain error \(s)."
        case let .badKey(k): "Invalid credential name “\(k)”."
        case let .file(m): "Couldn't save the sign-in: \(m)"
        }
    }
}

/// Connector sign-in tokens as private files: `<Wren data folder>/Credentials/<key>`, the folder
/// readable only by your macOS user (0700) and each file 0600, written atomically. No Keychain, so
/// no Keychain password prompts. Never part of Wren's database, exports or backups. Any app running
/// as your user could read these files, which is the trade-off against the Keychain.
public struct FileCredentialStore: CredentialStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    @MainActor public static var `default`: FileCredentialStore {
        FileCredentialStore(directory: WrenStore.defaultDirectory.appendingPathComponent("Credentials", isDirectory: true))
    }

    func url(_ key: String) throws -> URL {
        guard !key.isEmpty, key.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil, !key.hasPrefix(".") else {
            throw CredentialError.badKey(key)
        }
        return directory.appendingPathComponent(key)
    }

    func ensureDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    public func read(_ key: String) throws -> Data? {
        let u = try url(key)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try Data(contentsOf: u)
    }

    public func write(_ key: String, _ value: Data) throws {
        try ensureDirectory()
        let u = try url(key)
        let tmp = directory.appendingPathComponent(".\(key).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: value, attributes: [.posixPermissions: 0o600]) else {
            throw CredentialError.file("couldn't write \(key)")
        }
        do {
            _ = try FileManager.default.replaceItemAt(u, withItemAt: tmp)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw CredentialError.file(error.localizedDescription)
        }
    }

    public func delete(_ key: String) throws {
        let u = try url(key)
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
    }

    /// Removes every stored credential (used when all Wren data is erased).
    public func deleteAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    public init() {}
    public func read(_ key: String) throws -> Data? { lock.withLock { items[key] } }
    public func write(_ key: String, _ value: Data) throws { lock.withLock { items[key] = value } }
    public func delete(_ key: String) throws { _ = lock.withLock { items.removeValue(forKey: key) } }
    public var keys: [String] { lock.withLock { Array(items.keys) } }
}

public extension CredentialStore {
    func readString(_ key: String) -> String? { (try? read(key)).flatMap { $0 }.flatMap { String(data: $0, encoding: .utf8) } }
    func writeString(_ key: String, _ v: String) throws { try write(key, Data(v.utf8)) }
    func readJSON<T: Decodable>(_ key: String, as: T.Type) -> T? { (try? read(key)).flatMap { $0 }.flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
    func writeJSON<T: Encodable>(_ key: String, _ v: T) throws { try write(key, try JSONEncoder().encode(v)) }
}
