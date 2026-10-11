import CryptoKit
import Foundation
import SQLite3

public enum BackupReason: String, Codable, Sendable, CaseIterable {
    case manual, automatic, preMigration, preRestore, preReset
    public var label: String {
        switch self {
        case .manual: "Manual"
        case .automatic: "Daily"
        case .preMigration: "Before upgrade"
        case .preRestore: "Before restore"
        case .preReset: "Before reset"
        }
    }
}

/// `manifest.json` next to each backup's `Wren.store`.
public struct BackupManifest: Codable, Equatable, Sendable {
    public static let format = "wren-backup"
    public static let currentVersion = 1
    public var format: String
    public var formatVersion: Int
    public var createdAt: Date
    public var appVersion: String
    public var schemaVersion: Int
    public var reason: BackupReason
    public var storeFile: String
    public var sha256: String
    public var byteSize: Int64
    public var counts: [String: Int]
}

public struct BackupEntry: Identifiable, Sendable, Equatable {
    public var id: String { directory.lastPathComponent }
    public var directory: URL
    /// nil for backups made by Wren 0.2–0.4 (plain file copies before an upgrade, no manifest).
    public var manifest: BackupManifest?
    public var createdAt: Date
    public var isLegacy: Bool { manifest == nil }
    public var reasonLabel: String { manifest?.reason.label ?? "Before upgrade (older format)" }
}

/// What a backup holds, read after verification.
public struct BackupPreview: Sendable, Equatable {
    public var entry: BackupEntry
    public var counts: [String: Int]
    public var newestItemTitles: [String]
    /// A verified, self-contained copy that can be restored.
    public var verifiedStoreURL: URL
}

public enum BackupError: Error, LocalizedError, Equatable {
    case sourceMissing
    case sqlite(String)
    case integrity(String)
    case checksumMismatch
    case unsupportedFormat(Int)
    case notABackup
    case outsideBackupFolder
    case noPendingRestore

    public var errorDescription: String? {
        switch self {
        case .sourceMissing: "There's no database to back up yet."
        case let .sqlite(m): "Database error: \(m)"
        case let .integrity(m): "The backup is damaged (\(m))."
        case .checksumMismatch: "The backup's contents don't match its checksum; it may be damaged or modified."
        case let .unsupportedFormat(v): "This backup uses format \(v), which this version of Wren can't read."
        case .notABackup: "This folder isn't a Wren backup."
        case .outsideBackupFolder: "Refused: that path isn't inside Wren's backup folder."
        case .noPendingRestore: "No restore is waiting."
        }
    }
}

/// Consistent backups of the live SwiftData/SQLite store, using SQLite's online backup API
/// (a transactionally consistent snapshot even while Wren is writing), plus verification,
/// retention, deletion and staged restore. Never touches files outside Wren's data folder.
public struct BackupManager: Sendable {
    public let dataDirectory: URL
    public var storeURL: URL { dataDirectory.appendingPathComponent("Wren.store") }
    public var backupsDirectory: URL { dataDirectory.appendingPathComponent("Backups", isDirectory: true) }
    var restoreDirectory: URL { dataDirectory.appendingPathComponent("Restore", isDirectory: true) }

    /// Newest backups kept per reason. Older ones are pruned after each new backup.
    public static let retention: [BackupReason: Int] = [.automatic: 7, .manual: 10, .preMigration: 5, .preRestore: 5, .preReset: 5]

    public init(dataDirectory: URL) { self.dataDirectory = dataDirectory }

    // MARK: Create

    @discardableResult
    public func createBackup(reason: BackupReason, appVersion: String, schemaVersion: Int = WrenStore.schemaVersion, now: Date = .now) throws -> BackupEntry {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { throw BackupError.sourceMissing }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HHmmss"
        var dir = backupsDirectory.appendingPathComponent("\(f.string(from: now))-\(reason.rawValue)", isDirectory: true)
        var n = 1
        while fm.fileExists(atPath: dir.path) { n += 1; dir = backupsDirectory.appendingPathComponent("\(f.string(from: now))-\(reason.rawValue)-\(n)", isDirectory: true) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("Wren.store")
        do {
            try Self.sqliteBackup(from: storeURL, to: dest)
            try Self.integrityCheck(dest)
            let manifest = BackupManifest(format: BackupManifest.format, formatVersion: BackupManifest.currentVersion, createdAt: now,
                                          appVersion: appVersion, schemaVersion: schemaVersion, reason: reason, storeFile: "Wren.store",
                                          sha256: try Self.sha256(dest), byteSize: Self.size(dest), counts: Self.counts(dest))
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
            try enc.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
            prune()
            return BackupEntry(directory: dir, manifest: manifest, createdAt: now)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    // MARK: List and prune

    public func list() -> [BackupEntry] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return dirs.compactMap { dir -> BackupEntry? in
            guard fm.fileExists(atPath: dir.appendingPathComponent("Wren.store").path) else { return nil }
            if let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")), let m = try? dec.decode(BackupManifest.self, from: data) {
                return BackupEntry(directory: dir, manifest: m, createdAt: m.createdAt)
            }
            let created = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return BackupEntry(directory: dir, manifest: nil, createdAt: created)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    public func latest(reason: BackupReason) -> BackupEntry? { list().first { $0.manifest?.reason == reason } }

    func prune() {
        let all = list()
        for (reason, keep) in Self.retention {
            for old in all.filter({ $0.manifest?.reason == reason }).dropFirst(keep) { try? delete(old) }
        }
    }

    public func delete(_ entry: BackupEntry) throws {
        let dir = entry.directory.standardizedFileURL.resolvingSymlinksInPath()
        let root = backupsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard dir.path.hasPrefix(root.path + "/"), dir.deletingLastPathComponent().path == root.path else { throw BackupError.outsideBackupFolder }
        try FileManager.default.removeItem(at: dir)
    }

    // MARK: Verify and preview

    /// Checks format, checksum and SQLite integrity, and produces a self-contained verified copy
    /// in a temporary folder. Legacy backups (store + WAL files, no manifest) are checkpointed into one file.
    public func verify(_ entry: BackupEntry) throws -> URL {
        let fm = FileManager.default
        let src = entry.directory.appendingPathComponent("Wren.store")
        guard fm.fileExists(atPath: src.path) else { throw BackupError.notABackup }
        let tmp = fm.temporaryDirectory.appendingPathComponent("wren-verify-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let out = tmp.appendingPathComponent("Wren.store")
        if let m = entry.manifest {
            guard m.format == BackupManifest.format else { throw BackupError.notABackup }
            guard m.formatVersion <= BackupManifest.currentVersion else { throw BackupError.unsupportedFormat(m.formatVersion) }
            guard try Self.sha256(src) == m.sha256 else { throw BackupError.checksumMismatch }
            try fm.copyItem(at: src, to: out)
        } else {
            // Legacy: copy the trio, then let SQLite fold the WAL in and switch to a single file.
            for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: src.path + suffix) {
                try fm.copyItem(atPath: src.path + suffix, toPath: out.path + suffix)
            }
            try Self.exec(out, "PRAGMA journal_mode=DELETE;")
        }
        try Self.integrityCheck(out)
        return out
    }

    // MARK: Staged restore

    /// Puts a verified store where the next launch will pick it up. The live store is untouched.
    public func stageRestore(verifiedStore: URL) throws {
        let fm = FileManager.default
        let pending = restoreDirectory.appendingPathComponent("pending", isDirectory: true)
        try? fm.removeItem(at: pending)
        try fm.createDirectory(at: pending, withIntermediateDirectories: true)
        try fm.copyItem(at: verifiedStore, to: pending.appendingPathComponent("Wren.store"))
        try Self.integrityCheck(pending.appendingPathComponent("Wren.store"))
    }

    public var hasPendingRestore: Bool {
        FileManager.default.fileExists(atPath: restoreDirectory.appendingPathComponent("pending/Wren.store").path)
    }

    /// Before the store is opened: moves the current store aside and puts the staged one in place.
    /// Returns the folder holding the replaced store (for rollback), or nil if nothing was pending.
    public func applyPendingRestore(now: Date = .now) throws -> URL? {
        let fm = FileManager.default
        let pendingStore = restoreDirectory.appendingPathComponent("pending/Wren.store")
        guard fm.fileExists(atPath: pendingStore.path) else { return nil }
        try Self.integrityCheck(pendingStore)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let replaced = restoreDirectory.appendingPathComponent("replaced-\(f.string(from: now))", isDirectory: true)
        try fm.createDirectory(at: replaced, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: storeURL.path + suffix) {
            try fm.moveItem(atPath: storeURL.path + suffix, toPath: replaced.appendingPathComponent("Wren.store" + suffix).path)
        }
        try fm.moveItem(at: pendingStore, to: storeURL)
        try? fm.removeItem(at: restoreDirectory.appendingPathComponent("pending"))
        return replaced
    }

    /// Puts the previous store back if the restored one couldn't be opened.
    public func rollbackRestore(replaced: URL) throws {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: storeURL.path + suffix) {
            try fm.removeItem(atPath: storeURL.path + suffix)
        }
        for suffix in ["", "-wal", "-shm"] {
            let p = replaced.appendingPathComponent("Wren.store" + suffix).path
            if fm.fileExists(atPath: p) { try fm.moveItem(atPath: p, toPath: storeURL.path + suffix) }
        }
    }

    // MARK: SQLite helpers

    static func open(_ url: URL, flags: Int32) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(db)
            throw BackupError.sqlite(msg)
        }
        sqlite3_busy_timeout(db, 5000)
        return db
    }

    static func sqliteBackup(from src: URL, to dst: URL) throws {
        // Read-write so SQLite can create the WAL index of a closed store; only reads are issued.
        let s = try open(src, flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(s) }
        let d = try open(dst, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        defer { sqlite3_close(d) }
        guard let b = sqlite3_backup_init(d, "main", s, "main") else { throw BackupError.sqlite(String(cString: sqlite3_errmsg(d))) }
        let rc = sqlite3_backup_step(b, -1)
        sqlite3_backup_finish(b)
        guard rc == SQLITE_DONE else { throw BackupError.sqlite("backup step \(rc)") }
        // A single self-contained file, not WAL.
        guard sqlite3_exec(d, "PRAGMA journal_mode=DELETE;", nil, nil, nil) == SQLITE_OK else { throw BackupError.sqlite(String(cString: sqlite3_errmsg(d))) }
    }

    static func exec(_ url: URL, _ sql: String) throws {
        let db = try open(url, flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw BackupError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    public static func integrityCheck(_ url: URL) throws {
        let db: OpaquePointer
        do { db = try open(url, flags: SQLITE_OPEN_READONLY) } catch { throw BackupError.integrity("can't be opened") }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &stmt, nil) == SQLITE_OK else {
            throw BackupError.integrity(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let txt = sqlite3_column_text(stmt, 0) else { throw BackupError.integrity("no result") }
        let result = String(cString: txt)
        guard result == "ok" else { throw BackupError.integrity(result) }
        // Must look like a Wren store.
        guard try tableExists(db, "ZCOMMITMENT") else { throw BackupError.notABackup }
    }

    static func tableExists(_ db: OpaquePointer, _ name: String) throws -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?;", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) > 0
    }

    /// Record counts read straight from the SQLite tables (works for any schema version that has them).
    public static func counts(_ url: URL) -> [String: Int] {
        guard let db = try? open(url, flags: SQLITE_OPEN_READONLY) else { return [:] }
        defer { sqlite3_close(db) }
        var out: [String: Int] = [:]
        for (key, table) in [("items", "ZCOMMITMENT"), ("goals", "ZGOAL"), ("historyEvents", "ZACTIVITYEVENT"), ("activityLog", "ZAUDITRECORD")] {
            guard (try? tableExists(db, table)) == true else { continue }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT count(*) FROM \(table);", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
                out[key] = Int(sqlite3_column_int(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }
        return out
    }

    /// Newest item titles in a store, for previews.
    public static func newestTitles(_ url: URL, limit: Int = 5) -> [String] {
        guard let db = try? open(url, flags: SQLITE_OPEN_READONLY) else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ZTITLE FROM ZCOMMITMENT ORDER BY ZCREATEDAT DESC LIMIT \(limit);", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let t = sqlite3_column_text(stmt, 0) { out.append(String(cString: t)) } }
        return out
    }

    public func preview(_ entry: BackupEntry) throws -> BackupPreview {
        let verified = try verify(entry)
        return BackupPreview(entry: entry, counts: Self.counts(verified), newestItemTitles: Self.newestTitles(verified), verifiedStoreURL: verified)
    }

    static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
