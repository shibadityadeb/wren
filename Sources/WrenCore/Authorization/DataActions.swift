import Foundation

public extension BuiltInAction {
    static let markReminderSummarized: ActionID = "reminder.markSummarized"
    static let eraseAllData: ActionID = "data.eraseAll"
    static let restoreBackup: ActionID = "data.restoreBackup"
    static let deleteBackup: ActionID = "backup.delete"
    static let resetPreferences: ActionID = "settings.reset"

    static let allDataTarget = TargetRef(kind: "wren-data", id: "all", label: "All Wren data")

    /// Data management actions. All destructive ones always require confirmation.
    @MainActor
    static func registerData(on broker: ActionBroker, store: WrenStore, backups: BackupManager, appVersion: String, clock: WrenClock) {
        broker.register(ClosureHandler(
            ActionDescriptor(id: markReminderSummarized, category: .localReversible, permission: .notify, confirmation: .none,
                             summary: "Record a reminder as covered by the after-pause summary", verification: "Item records the reminder as sent"),
            execute: { r in
                guard let id = UUID(uuidString: r.target.id), let c = try store.item(id: id) else { throw BrokerError.targetMissing }
                guard ReminderPolicy.isDue(c, now: clock.now) else { throw BrokerError.refused("Not due.") }
                try store.markReminderSent(c, now: clock.now, note: "included in the summary after notifications were paused")
                return nil
            },
            verify: { r in UUID(uuidString: r.target.id).flatMap { try? store.item(id: $0) }.map { $0.lastReminderAt != nil && $0.nextReminderAt == nil } ?? false }))

        broker.register(ClosureHandler(
            ActionDescriptor(id: eraseAllData, category: .irreversible, permission: .deleteItems, confirmation: .always,
                             summary: "Remove all Wren data (items, goals, history, review, permissions reset)",
                             verification: "No items or goals remain; default permissions present"),
            execute: { r in
                guard r.target == allDataTarget else { throw BrokerError.badParameter("target") }
                try store.eraseAllUserData(keepingAuditFor: r.id, now: clock.now)
                return "erased"
            },
            verify: { _ in
                let c = store.userDataCounts()
                return c["items"] == 0 && c["goals"] == 0
            }))

        broker.register(ClosureHandler(
            ActionDescriptor(id: restoreBackup, category: .localDestructive, permission: .deleteItems, confirmation: .always,
                             summary: "Replace current data with a backup (current data is backed up first)",
                             verification: "Verified backup staged; safety backup created"),
            execute: { r in
                guard r.target.kind == "backup", let entry = backups.list().first(where: { $0.id == r.target.id }) else { throw BrokerError.targetMissing }
                let verified = try backups.verify(entry)
                try backups.createBackup(reason: .preRestore, appVersion: appVersion, now: clock.now)
                try backups.stageRestore(verifiedStore: verified)
                return "staged; restart to finish"
            },
            verify: { _ in backups.hasPendingRestore }))

        broker.register(ClosureHandler(
            ActionDescriptor(id: deleteBackup, category: .localDestructive, permission: .deleteItems, confirmation: .always,
                             summary: "Delete a backup", verification: "Backup folder no longer exists"),
            execute: { r in
                guard r.target.kind == "backup", let entry = backups.list().first(where: { $0.id == r.target.id }) else { throw BrokerError.targetMissing }
                try backups.delete(entry)
                return nil
            },
            verify: { r in !backups.list().contains { $0.id == r.target.id } }))
    }
}

/// A handler built from closures, for app-level actions (for example resetting preferences).
@MainActor
public final class BlockActionHandler: ActionHandler {
    public let descriptor: ActionDescriptor
    let run: @MainActor (ActionRequest) throws -> String?
    let check: @MainActor (ActionRequest) -> Bool
    public init(_ d: ActionDescriptor, execute: @escaping @MainActor (ActionRequest) throws -> String?, verify: @escaping @MainActor (ActionRequest) -> Bool) {
        descriptor = d; run = execute; check = verify
    }
    public func execute(_ r: ActionRequest) async throws -> HandlerOutcome { HandlerOutcome(detail: try run(r)) }
    public func verify(_ r: ActionRequest) async -> Verification { check(r) ? .verified : .mismatch }
}

public extension BackupEntry {
    var targetRef: TargetRef {
        TargetRef(kind: "backup", id: id, label: "Backup from \(createdAt.formatted(date: .abbreviated, time: .shortened))")
    }
}

/// Decides what a newly launched Wren should do when another copy is running.
public enum InstanceGuard {
    public enum Decision: Equatable { case proceed, waitForPrevious, exit }

    /// - Parameters:
    ///   - othersRunning: another Wren process with this bundle ID exists.
    ///   - isRelaunch: started by Wren itself to finish a restore or reset (`--relaunch`).
    ///   - waited: seconds already spent waiting for the previous copy to quit.
    public static func decide(othersRunning: Bool, isRelaunch: Bool, waited: TimeInterval, limit: TimeInterval = 10) -> Decision {
        guard othersRunning else { return .proceed }
        return isRelaunch && waited < limit ? .waitForPrevious : .exit
    }
}
