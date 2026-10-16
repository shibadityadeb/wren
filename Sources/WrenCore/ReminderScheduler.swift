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
    /// The heads-up before a deadline (not the reminder itself): its notification offers Done, not Snooze.
    public var isAdvance = false
}

/// When to send the heads-up before a deadline: `days` before it, at `hour` (the default reminder time).
public struct DeadlineAdvance: Equatable, Sendable {
    public var days: Int
    public var hour: Int
    public init(days: Int = 1, hour: Int = 10) { self.days = days; self.hour = hour }
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
    /// Requests Wren's stored reminders call for right now.
    public var expected = 0
    /// Of those, how many macOS reported as pending after this reconcile.
    public var pending = 0
    /// The earliest one-off fire time among the pending requests.
    public var nextFire: Date?
    /// The last error macOS returned when scheduling (code and description), if any.
    public var lastError: String?
    public var checkedAt: Date?
    public init() {}
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
    /// The day-before heads-up for deadlines; nil when the user turned it (or deadline reminders) off.
    public var advance: () -> DeadlineAdvance?
    private var running = false
    private var again = false
    public private(set) var lastReport = ReconcileReport()

    public init(store: WrenStore, center: ReminderNotificationCenter, clock: WrenClock, pause: @escaping () -> NotificationPause? = { nil },
                advance: @escaping () -> DeadlineAdvance? = { nil }) {
        self.store = store; self.center = center; self.clock = clock; self.pause = pause; self.advance = advance
    }

    static func onceID(_ c: Commitment, _ d: Date) -> String { "\(prefix)\(c.id.uuidString).at.\(Int(d.timeIntervalSince1970.rounded()))" }
    static func advanceID(_ c: Commitment, _ d: Date) -> String { "\(prefix)\(c.id.uuidString).before.\(Int(d.timeIntervalSince1970.rounded()))" }
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
        // The heads-up the day before a deadline. Its own identifier (item and time), so it is
        // scheduled once, moves with the deadline and goes when the task is done or deleted.
        if let a = advance(), let at = ReminderPolicy.advanceReminder(for: c, now: now, advance: a, calendar: cal), let deadline = c.deadline {
            out.append(ReminderRequest(id: Self.advanceID(c, at), commitmentID: c.id, title: c.title,
                                       body: "Due \(DueText.describe(deadline, hasTime: c.deadlineHasTime, now: at, calendar: cal)).",
                                       trigger: .at(at), isAdvance: true))
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
            do { try await center.schedule(r); live.insert(r.id); report.scheduled += 1 } catch {
                report.failed.append(r.id)
                let e = error as NSError
                report.lastError = "\(e.domain) \(e.code): \(e.localizedDescription)"
            }
        }
        // What macOS really holds afterwards (an accepted add isn't proof it stayed pending).
        let after = await center.pendingReminderIDs()
        report.expected = desiredIDs.count
        report.pending = desiredIDs.intersection(after).count
        report.nextFire = desired.values.flatMap { $0 }.filter { after.contains($0.id) }
            .compactMap { if case let .at(d) = $0.trigger { d } else { nil } }.min()
        report.checkedAt = now
        // Remember what is actually scheduled, per item. Only saves when something changed. A request
        // macOS has just shown for the item's current reminder time is kept until the engine records
        // it, so Wren doesn't show the same reminder again.
        var changed = false
        for c in items {
            var ids = (desired[c.id] ?? []).map(\.id).filter(live.contains)
            ids += c.scheduledNotificationIDs.filter { !pending.contains($0) && !ids.contains($0) && isFiredCurrentOccurrence(c, $0, now: now) }
            ids.sort()
            if c.scheduledNotificationIDs != ids { c.scheduledNotificationIDs = ids; changed = true }
        }
        if changed { try? store.saveQuietly() }
        return report
    }

    /// `id` was macOS's request for the item's current reminder time, and that time has passed.
    func isFiredCurrentOccurrence(_ c: Commitment, _ id: String, now: Date) -> Bool {
        guard c.status == .pending, let next = c.nextReminderAt, next <= now else { return false }
        if id == Self.onceID(c, next) { return true }
        if let rule = c.recurrence, rule.matches(next, calendar: clock.calendar) {
            let comps = DateComponents(hour: rule.hour, minute: rule.minute, weekday: rule.isDaily ? nil : clock.calendar.component(.weekday, from: next))
            return id == Self.repeatingID(c, comps)
        }
        return false
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
