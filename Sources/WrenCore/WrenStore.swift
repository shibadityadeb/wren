import Foundation
import SwiftData

public enum StoreError: Error, LocalizedError, Equatable {
    case cannotOpen(path: String, reason: String)
    case invalidTransition(from: CommitmentStatus, action: String)
    case emptyText
    case saveFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .cannotOpen(path, reason): "Could not open the Wren database at \(path): \(reason)"
        case let .invalidTransition(from, action): "Cannot \(action) an item that is \(from.rawValue)."
        case .emptyText: "Nothing to save."
        case let .saveFailed(r): "Saving failed: \(r)"
        }
    }
}

/// The single source of truth for commitments. Every mutation saves immediately
/// and appends an ActivityEvent. All status changes go through `apply`-style
/// methods here so a future Action Broker has one seam to wrap.
@MainActor
public final class WrenStore {
    public let container: ModelContainer
    public var context: ModelContext { container.mainContext }
    public let storeURL: URL?

    public static let models: [any PersistentModel.Type] = [
        Commitment.self, ActivityEvent.self, DailyRun.self,
        AuditRecord.self, PermissionGrantRecord.self, StandingRuleRecord.self, DenialRecord.self,
    ]

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wren", isDirectory: true)
    }

    /// - Parameter url: nil for an in-memory store (tests and previews).
    public init(url: URL?) throws {
        let schema = Schema(Self.models)
        let config: ModelConfiguration
        if let url {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                throw StoreError.cannotOpen(path: url.path, reason: error.localizedDescription)
            }
            config = ModelConfiguration(schema: schema, url: url)
        } else {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        }
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            throw StoreError.cannotOpen(path: url?.path ?? "memory", reason: error.localizedDescription)
        }
        container.mainContext.autosaveEnabled = false
        storeURL = url
    }

    public static func openDefault() throws -> WrenStore {
        let url = defaultDirectory.appendingPathComponent("Wren.store")
        try backupBeforeUpgrade(url, version: schemaVersion)
        return try WrenStore(url: url)
    }

    /// Bumped whenever models are added or changed.
    public static let schemaVersion = 2

    /// Copies the store (and its WAL files) once per schema version before the first open,
    /// so an upgrade can always be rolled back by hand.
    public static func backupBeforeUpgrade(_ url: URL, version: Int) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let dir = url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        let marker = dir.appendingPathComponent("schema-v\(version)")
        guard !fm.fileExists(atPath: marker.path) else { return }
        try fm.createDirectory(at: marker, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: url.path + suffix)
            if fm.fileExists(atPath: src.path) {
                try fm.copyItem(at: src, to: marker.appendingPathComponent(src.lastPathComponent))
            }
        }
    }

    /// Today's (or any day's) run record, created on first use.
    public func dailyRun(for day: String) throws -> DailyRun {
        var d = FetchDescriptor<DailyRun>(predicate: #Predicate { $0.day == day })
        d.fetchLimit = 1
        if let r = try context.fetch(d).first { return r }
        let r = DailyRun(day: day)
        context.insert(r)
        try save()
        return r
    }

    // MARK: Queries

    public func all() throws -> [Commitment] {
        try context.fetch(FetchDescriptor<Commitment>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
    }

    public func item(id: UUID) throws -> Commitment? {
        var d = FetchDescriptor<Commitment>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    /// Pending items, soonest deadline first, undated last, then by priority.
    public func pending() throws -> [Commitment] {
        let raw = CommitmentStatus.pending.rawValue
        let items = try context.fetch(FetchDescriptor<Commitment>(predicate: #Predicate { $0.statusRaw == raw }))
        return items.sorted(by: Self.pendingOrder)
    }

    public func closed(limit: Int = 30) throws -> [Commitment] {
        let raw = CommitmentStatus.pending.rawValue
        var d = FetchDescriptor<Commitment>(predicate: #Predicate { $0.statusRaw != raw },
                                            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        d.fetchLimit = limit
        return try context.fetch(d)
    }

    nonisolated static func pendingOrder(_ a: Commitment, _ b: Commitment) -> Bool {
        switch (a.deadline, b.deadline) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default:
            if a.priority != b.priority { return a.priority > b.priority }
            return a.createdAt > b.createdAt
        }
    }

    // MARK: Capture

    /// Saves raw text immediately, before any model work. This must never depend on Ollama.
    @discardableResult
    public func capture(_ text: String, source: CaptureSource, now: Date = .now) throws -> Commitment {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.emptyText }
        let c = Commitment(originalText: text, source: source, now: now)
        context.insert(c)
        log(c, .captured, at: now, note: source.rawValue)
        try save()
        return c
    }

    // MARK: Interpretation

    /// Applies an interpretation. Never overwrites manual edits or closed items.
    /// - Parameter state: `.processed` for model output; `.awaiting` when only the
    ///   deterministic rules ran (so a later model pass may still refine it).
    public func applyInterpretation(_ i: Interpretation, to c: Commitment, model: String?,
                                    reminderPolicy: ReminderPolicy, state: ProcessingState = .processed,
                                    now: Date = .now) throws {
        guard c.processing != .manual, c.status == .pending else { return }
        c.kind = i.kind
        c.title = i.title
        c.priority = i.priority
        c.deadline = i.deadline
        c.deadlineHasTime = i.deadlineHasTime
        c.processing = state
        c.processingNote = i.note
        c.modelName = model
        log(c, .interpreted, at: now, note: model.map { "via \($0)" } ?? "rules only")
        if c.reminderFromDeadline {
            c.nextReminderAt = nil
            c.reminderFromDeadline = false
        }
        if c.nextReminderAt == nil, let r = reminderPolicy.initialReminder(for: c, now: now) {
            c.nextReminderAt = r
            c.reminderFromDeadline = true
            log(c, .reminderScheduled, at: now, note: "from deadline, \(Self.stamp(r))")
        }
        try save()
    }

    public func markInterpretationFailed(_ c: Commitment, reason: String, now: Date = .now) throws {
        guard c.processing != .manual else { return }
        c.processing = .failed
        c.processingNote = String(reason.prefix(300))
        log(c, .interpretationFailed, at: now, note: c.processingNote)
        try save()
    }

    // MARK: Edits and transitions

    public struct Edit: Sendable {
        public var title: String
        public var details: String?
        public var kind: CaptureKind
        public var priority: Priority
        public var deadline: Date?
        public var deadlineHasTime: Bool
        public var nextReminderAt: Date?
        public init(title: String, details: String?, kind: CaptureKind, priority: Priority,
                    deadline: Date?, deadlineHasTime: Bool, nextReminderAt: Date?) {
            self.title = title; self.details = details; self.kind = kind; self.priority = priority
            self.deadline = deadline; self.deadlineHasTime = deadlineHasTime; self.nextReminderAt = nextReminderAt
        }
    }

    public func edit(_ c: Commitment, _ e: Edit, now: Date = .now) throws {
        let title = e.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw StoreError.emptyText }
        c.title = title
        c.details = e.details?.isEmpty == true ? nil : e.details
        c.kind = e.kind
        c.priority = e.priority
        c.deadline = e.deadline
        c.deadlineHasTime = e.deadlineHasTime
        c.processing = .manual
        log(c, .edited, at: now)
        if c.status == .pending, e.nextReminderAt != c.nextReminderAt {
            c.nextReminderAt = e.nextReminderAt
            c.reminderFromDeadline = false
            if let r = e.nextReminderAt { log(c, .reminderScheduled, at: now, note: Self.stamp(r)) }
        }
        try save()
    }

    public func complete(_ c: Commitment, now: Date = .now) throws {
        try requirePending(c, "complete")
        c.status = .completed
        c.completedAt = now
        c.nextReminderAt = nil
        log(c, .completed, at: now)
        try save()
    }

    public func drop(_ c: Commitment, now: Date = .now) throws {
        try requirePending(c, "drop")
        c.status = .dropped
        c.droppedAt = now
        c.nextReminderAt = nil
        log(c, .dropped, at: now)
        try save()
    }

    public func snooze(_ c: Commitment, until: Date, now: Date = .now) throws {
        try requirePending(c, "snooze")
        guard until > now else { throw StoreError.invalidTransition(from: c.status, action: "snooze into the past") }
        c.nextReminderAt = until
        c.reminderFromDeadline = false
        c.snoozeCount += 1
        c.deferredAt = now
        log(c, .snoozed, at: now, note: Self.stamp(until))
        try save()
    }

    public func scheduleReminder(_ c: Commitment, at date: Date, now: Date = .now) throws {
        try requirePending(c, "schedule a reminder for")
        c.nextReminderAt = date
        c.reminderFromDeadline = false
        log(c, .reminderScheduled, at: now, note: Self.stamp(date))
        try save()
    }

    public func reopen(_ c: Commitment, now: Date = .now) throws {
        guard c.status != .pending else { return }
        c.status = .pending
        c.completedAt = nil
        c.droppedAt = nil
        log(c, .reopened, at: now)
        try save()
    }

    /// Records that a reminder was handed to the notification system.
    /// Clears nextReminderAt in the same save, so a restart cannot send it twice.
    public func markReminderSent(_ c: Commitment, now: Date = .now) throws {
        c.lastReminderAt = now
        c.nextReminderAt = nil
        c.reminderFromDeadline = false
        log(c, .reminderSent, at: now)
        try save()
    }

    public func delete(_ c: Commitment) throws {
        context.delete(c)
        try save()
    }

    // MARK: Helpers

    private func requirePending(_ c: Commitment, _ action: String) throws {
        guard c.status == .pending else { throw StoreError.invalidTransition(from: c.status, action: action) }
    }

    private func log(_ c: Commitment, _ kind: EventKind, at: Date, note: String? = nil) {
        let e = ActivityEvent(kind: kind, at: at, note: note)
        context.insert(e)
        e.commitment = c
    }

    private func save() throws {
        do { try context.save() } catch {
            context.rollback()
            throw StoreError.saveFailed(error.localizedDescription)
        }
    }

    static func stamp(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}
