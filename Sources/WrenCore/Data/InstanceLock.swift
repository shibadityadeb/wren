import Foundation

/// An exclusive advisory lock on Wren's data folder (`Wren.lock`, `flock`). Only the process that
/// holds it may open the database, so two copies of Wren (an installed one and a development
/// build, a login launch and a manual open, or copies with different bundle identifiers) can never
/// modify the same store at once. The kernel releases the lock if the process dies.
public final class DataDirectoryLock: @unchecked Sendable {
    public let url: URL
    private var fd: Int32 = -1

    public enum Failure: Error, Equatable, LocalizedError {
        case heldByAnotherProcess(pid: Int32?)
        case cannotOpen(String)
        public var errorDescription: String? {
            switch self {
            case let .heldByAnotherProcess(pid): "Another copy of Wren is already using this data\(pid.map { " (process \($0))" } ?? "")."
            case let .cannotOpen(r): "Couldn't open Wren's data folder lock: \(r)"
            }
        }
    }

    private init(url: URL) { self.url = url }

    /// Takes the lock without waiting, or reports who holds it.
    public static func acquire(directory: URL) throws -> DataDirectoryLock {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let l = DataDirectoryLock(url: directory.appendingPathComponent("Wren.lock"))
        let fd = open(l.url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.cannotOpen(String(cString: strerror(errno))) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let holder = Self.readPID(fd)
            close(fd)
            throw Failure.heldByAnotherProcess(pid: holder)
        }
        // Record the holder for diagnostics only; the lock itself is what matters.
        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        l.fd = fd
        return l
    }

    static func readPID(_ fd: Int32) -> Int32? {
        var buf = [UInt8](repeating: 0, count: 32)
        let n = pread(fd, &buf, buf.count, 0)
        guard n > 0 else { return nil }
        return Int32(String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public var isHeld: Bool { fd >= 0 }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
