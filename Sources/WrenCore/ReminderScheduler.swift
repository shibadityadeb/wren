import Foundation

/// One notification request Wren wants macOS to hold.
public struct ReminderRequest: Equatable, Sendable {
    public enum Trigger: Equatable, Sendable {
        /// Fires once at this instant.
        case at(Date)
        /// Fires every time the local wall clock matches (hour, minute, optional weekday).
        case repeating(DateComponents)
    }
    public var id: String
    public var commitmentID: UUID
    public var title: String
    public var body: String
    public var trigger: Trigger
}

/// The slice of macOS notifications the scheduler needs (UserNotifications in the app, a fake in tests).
@MainActor
public protocol ReminderNotificationCenter: AnyObject {
    func isAuthorized() async -> Bool
    /// Identifiers of pending (not yet delivered) requests that start with `ReminderScheduler.prefix`.
    func pendingReminderIDs() async -> Set<String>
    func schedule(_ r: ReminderRequest) async throws
    func cancel(ids: [String])
}

public struct ReconcileReport: Equatable, Sendable {
    public var authorized = true
    public var scheduled = 0
    public var cancelled = 0
    public var unchanged = 0
    public var failed: [String] = []
    public var paused = false
}

/// Keeps macOS's pending notifications equal to what Wren's stored reminders say, so reminders
/// arrive whether or not Wren is running, never twice, and never after an item is done or deleted.
/// Request identifiers encode the item and its schedule; a changed time is a new identifier, so a
/// stale request is always recognisable and removed.
@MainActor
public final class ReminderScheduler {
    public static let prefix = "wren.reminder."
    let store: WrenStore
    let center: ReminderNotificationCenter
    let clock: WrenClock
    let pause: () -> NotificationPause?
    private var running = false
    private var again = false
    public private(set) var lastReport = ReconcileReport()

    public init(store: WrenStore, center: ReminderNotificationCenter, clock: WrenClock, pause: @escaping () -> NotificationPause? = { nil }) {
        self.store = store; self.center = center; self.clock = clock; self.pause = pause
    }

    static func onceID(_ c: Commitment, _ d: Date) -> String { "\(prefix)\(c.id.uuidString).at.\(Int(d.timeIntervalSince1970.rounded()))" }
    static func repeatingID(_ c: Commitment, _ comps: DateComponents) -> String {
        "\(prefix)\(c.id.uuidString).rep.\(comps.weekday.map(String.init) ?? "d").\(String(format: "%02d%02d", comps.hour ?? 0, comps.minute ?? 0))"
    }

    /// What should be pending for one item right now.
    public func requests(for c: Commitment, now: Date) -> [ReminderRequest] {
        guard c.status == .pending else { return [] }
        let cal = clock.calendar
        var out: [ReminderRequest] = []
        if let rule = c.recurrence {
            for comps in rule.triggerComponents {
                out.append(ReminderRequest(id: Self.repeatingID(c, comps), commitmentID: c.id, title: c.title,
                                           body: rule.label(calendar: cal), trigger: .repeating(comps)))
            }
            // A snoozed occurrence fires once at the snooze time, in addition to the series.
            if let next = c.nextReminderAt, next > now, !rule.matches(next, calendar: cal) {
                out.append(ReminderRequest(id: Self.onceID(c, next), commitmentID: c.id, title: c.title,
                                           body: "Snoozed. " + rule.label(calendar: cal), trigger: .at(next)))
            }
        } else if let next = c.nextReminderAt, next > now {
            out.append(ReminderRequest(id: Self.onceID(c, next), commitmentID: c.id, title: c.title,
                                       body: ReminderPayload.body(for: c), trigger: .at(next)))
        }
        // Paused: nothing that would fire during the pause. Repeating ones return when it ends.
        if let p = pause(), p.isActive(at: now) {
            out = out.filter { r in
                guard case let .at(d) = r.trigger, let until = p.until else { return false }
                return d >= until
            }
        }
        return out
    }

    /// Brings macOS in line with the store. Safe to call often; overlapping calls coalesce.
    @discardableResult
    public func reconcile() async -> ReconcileReport {
        if running { again = true; return lastReport }
        running = true
        defer { running = false }
        var report = ReconcileReport()
        repeat {
            again = false
            report = await reconcileOnce()
        } while again
        lastReport = report
        return report
    }

    private func reconcileOnce() async -> ReconcileReport {
        var report = ReconcileReport()
        let now = clock.now
        report.paused = pause()?.isActive(at: now) ?? false
        let items = (try? store.all()) ?? []
        report.authorized = await center.isAuthorized()
        let pending = await center.pendingReminderIDs()
        var desired: [UUID: [ReminderRequest]] = [:]
        if report.authorized {
            for c in items { let r = requests(for: c, now: now); if !r.isEmpty { desired[c.id] = r } }
        }
        let desiredIDs = Set(desired.values.flatMap { $0.map(\.id) })
        let stale = pending.subtracting(desiredIDs)
        if !stale.isEmpty { center.cancel(ids: Array(stale)); report.cancelled = stale.count }

        var live = pending.intersection(desiredIDs)
        report.unchanged = live.count
        for r in desired.values.flatMap({ $0 }) where !pending.contains(r.id) {
            do { try await center.schedule(r); live.insert(r.id); report.scheduled += 1 } catch { report.failed.append(r.id) }
        }
        // Remember what is actually scheduled, per item. Only saves when something changed.
        var changed = false
        for c in items {
            let ids = (desired[c.id] ?? []).map(\.id).filter(live.contains).sorted()
            if c.scheduledNotificationIDs != ids { c.scheduledNotificationIDs = ids; changed = true }
        }
        if changed { try? store.saveQuietly() }
        return report
    }

    /// True when macOS holds a request for the item's current reminder time, so it has shown (or will
    /// show) it without Wren and Wren must not deliver it again.
    public func isScheduledByMacOS(_ c: Commitment) -> Bool {
        guard let next = c.nextReminderAt else { return false }
        let ids = Set(c.scheduledNotificationIDs)
        if ids.contains(Self.onceID(c, next)) { return true }
        if let rule = c.recurrence, rule.matches(next, calendar: clock.calendar) {
            let comps = DateComponents(hour: rule.hour, minute: rule.minute, weekday: rule.isDaily ? nil : clock.calendar.component(.weekday, from: next))
            return ids.contains(Self.repeatingID(c, comps))
        }
        return false
    }
}
