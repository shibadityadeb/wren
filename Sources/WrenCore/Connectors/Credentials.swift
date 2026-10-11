import Foundation
import Security

/// Secret storage. Production uses the macOS Keychain; tests use memory.
public protocol CredentialStore: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ key: String, _ value: Data) throws
    func delete(_ key: String) throws
}

public enum CredentialError: Error, Equatable, LocalizedError {
    case keychain(OSStatus)
    public var errorDescription: String? {
        switch self { case let .keychain(s): "Keychain error \(s)." }
    }
}

/// Generic-password items under one service name, accessible only when the Mac is unlocked,
/// never synced to iCloud.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    public init(service: String = "com.shibadityadeb.wren.connectors") { self.service = service }

    func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    public func read(_ key: String) throws -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess else { throw CredentialError.keychain(s) }
        return out as? Data
    }

    public func write(_ key: String, _ value: Data) throws {
        let attrs: [String: Any] = [kSecValueData as String: value,
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var s = SecItemUpdate(query(key) as CFDictionary, attrs as CFDictionary)
        if s == errSecItemNotFound {
            s = SecItemAdd(query(key).merging(attrs) { $1 } as CFDictionary, nil)
        }
        guard s == errSecSuccess else { throw CredentialError.keychain(s) }
    }

    public func delete(_ key: String) throws {
        let s = SecItemDelete(query(key) as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw CredentialError.keychain(s) }
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
