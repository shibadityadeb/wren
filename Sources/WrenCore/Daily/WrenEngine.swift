import Foundation
import SwiftData

/// The model-free heart of Wren: delivers due reminders and the daily briefing and
/// check-in, all from persisted data, all through the ActionBroker or the DailyRun ledger.
/// Depends on: store, clock, notifier, broker. Not on Ollama.
@MainActor
public final class WrenEngine {
    public let store: WrenStore
    public let broker: ActionBroker
    public let clock: WrenClock
    public let notifier: WrenNotifier?
    public var settings: () -> DailySettings
    public var insightSettings: () -> InsightSettings
    /// Current pause (persisted by the caller) and how to clear it when it expires.
    public var pause: () -> NotificationPause? = { nil }
    public var clearPause: () -> Void = {}
    /// Read-only highlights from connected services for the briefing (nil when none connected).
    public var externalBriefing: (() async -> ExternalBriefing?)?
    /// True when macOS holds a scheduled notification for the item's current reminder time
    /// (set by the app to `ReminderScheduler.isScheduledByMacOS`). Those are recorded, not re-sent.
    public var scheduledByMacOS: (Commitment) -> Bool = { _ in false }
    private var running = false

    public init(store: WrenStore, broker: ActionBroker, clock: WrenClock, notifier: WrenNotifier?, settings: @escaping () -> DailySettings,
                insightSettings: @escaping () -> InsightSettings = { InsightSettings() }) {
        self.store = store; self.broker = broker; self.clock = clock; self.notifier = notifier; self.settings = settings
        self.insightSettings = insightSettings
    }

    /// Every current observation, minus ones the user dismissed or resolved. For the Review pane.
    public func openInsights() -> [Insight] {
        let items = (try? store.all()) ?? [], goals = (try? store.goals()) ?? []
        return InsightEngine.compute(items: items, goals: goals, now: clock.now, calendar: clock.calendar, settings: insightSettings())
            .filter { !store.isClosed($0) }
    }

    /// Open observations not yet raised in a briefing or check-in.
    public func freshInsights() -> [Insight] { openInsights().filter { !store.wasSurfaced($0) } }

    public struct TickReport: Sendable, Equatable {
        public var remindersDelivered = 0
        public var remindersUndelivered = 0
        public var briefing: DailyEventState?
        public var checkIn: DailyEventState?
        public var paused = false
        /// Reminders folded into the one summary sent when a pause ended.
        public var summarizedAfterPause = 0
    }

    /// Safe to call any time (launch, wake, timer, clock change). Re-entrant calls are ignored.
    @discardableResult
    public func tick() async -> TickReport {
        var report = TickReport()
        guard !running else { return report }
        running = true
        defer { running = false }

        // Paused: deliver nothing, change nothing. Schedules and deadlines stay as they are,
        // and nothing is recorded as sent. Daily windows that close during the pause are
        // recorded as missed afterwards by the normal rules.
        if let p = pause() {
            if p.isActive(at: clock.now) { report.paused = true; return report }
            clearPause()
            report.summarizedAfterPause = await deliverPauseSummary(since: p.since)
        }

        // 1. Reminders, through the broker, as the scheduler under the auto-remind rule. Ones that
        // macOS showed from its schedule (possibly while Wren wasn't running) are only recorded;
        // anything not scheduled (notifications were off, or it was created while paused) is sent now.
        let canDeliver = await notifier?.canDeliver() ?? false
        if canDeliver, let due = try? ReminderPolicy.due(store.pending(), now: clock.now) {
            for c in due {
                let byMacOS = scheduledByMacOS(c)
                let r = ActionRequest(action: BuiltInAction.deliverReminder, target: c.targetRef,
                                      parameters: byMacOS ? ["byMacOS": .bool(true)] : [:], origin: .system("reminders"), createdAt: clock.now)
                let result = await broker.submit(r)
                if result.status == .succeeded { report.remindersDelivered += 1 } else { report.remindersUndelivered += 1 }
            }
        } else if let due = try? ReminderPolicy.due(store.pending(), now: clock.now) {
            report.remindersUndelivered = due.count
        }

        // 2. Daily events.
        report.briefing = await runDaily(.briefing, canDeliver: canDeliver)
        report.checkIn = await runDaily(.checkIn, canDeliver: canDeliver)
        return report
    }

    /// Ends a pause now: one summary for anything that came due, then normal operation.
    @discardableResult
    public func resume() async -> TickReport {
        var summarized = 0
        if let p = pause() {
            clearPause()
            summarized = await deliverPauseSummary(since: p.since)
        }
        var r = await tick()
        r.summarizedAfterPause += summarized
        return r
    }

    /// Recovery policy after a pause: never a burst. Every reminder that came due is listed in a
    /// single notification; only if macOS accepts it are those reminders recorded as delivered
    /// (each through the broker, with a history note). If notifications are unavailable they stay
    /// due and show in the app.
    func deliverPauseSummary(since: Date) async -> Int {
        guard let notifier, let due = try? ReminderPolicy.due(store.pending(), now: clock.now), !due.isEmpty,
              await notifier.canDeliver() else { return 0 }
        let payloads = due.map { ReminderPayload(id: $0.id, title: $0.title, body: ReminderPayload.body(for: $0), late: true) }
        guard await notifier.deliverPauseSummary(payloads, pausedSince: since) else { return 0 }
        var n = 0
        for c in due {
            let r = ActionRequest(action: BuiltInAction.markReminderSummarized, target: c.targetRef, origin: .system("resume after pause"), createdAt: clock.now)
            if await broker.submit(r).status == .succeeded { n += 1 }
        }
        return n
    }

    /// When the app should call tick() next.
    public func nextWake() -> Date {
        if let p = pause(), p.isActive(at: clock.now) {
            return min(p.until ?? clock.now.addingTimeInterval(3600), clock.now.addingTimeInterval(3600))
        }
        let items = (try? store.pending()) ?? []
        let reminder = ReminderPolicy.nextWake(items, now: clock.now, cap: 60)
        let daily = DailySchedule.nextBoundary(after: clock.now, settings: settings(), calendar: clock.calendar)
        return min(reminder, daily)
    }

    private func runDaily(_ e: DailyEvent, canDeliver: Bool) async -> DailyEventState? {
        let now = clock.now, cal = clock.calendar, s = settings()
        guard let run = try? store.dailyRun(for: cal.dayKey(for: now)) else { return nil }
        let state = e == .briefing ? run.briefing : run.checkIn
        let decision = DailySchedule.decide(e, state: state, now: now, settings: s, calendar: cal)
        func set(_ st: DailyEventState) {
            if e == .briefing { run.briefing = st; run.briefingAt = now } else { run.checkIn = st; run.checkInAt = now }
            try? store.context.save()
        }
        switch decision {
        case .wait, .done: return state
        case .markMissed: set(.missed); return .missed
        case .markDisabled: set(.disabled); return .disabled
        case .run:
            let items = (try? store.all()) ?? []
            let fresh = freshInsights()
            var briefing = Briefing.build(from: items, now: now, calendar: cal, insights: fresh)
            if e == .briefing, let provider = externalBriefing { briefing.external = await provider() }
            let checkIn = CheckIn.build(from: items, now: now, calendar: cal, insights: fresh)
            let empty = e == .briefing ? briefing.isEmpty : checkIn.isEmpty
            if empty && !s.sendEmptySummaries { set(.skippedEmpty); return .skippedEmpty }
            // Record first (at-most-once), then deliver.
            set(.sent)
            guard canDeliver, let notifier else { set(.undelivered); return .undelivered }
            let ok: Bool
            switch e {
            case .briefing: ok = await notifier.deliverBriefing(briefing)
            case .checkIn: ok = await notifier.deliverCheckIn(checkIn)
            }
            if !ok { set(.undelivered); return .undelivered }
            // Each observation is raised once per unchanged situation.
            try? store.markSurfaced(e == .briefing ? briefing.surfacedInsights : checkIn.decisions, now: now)
            return .sent
        }
    }

    /// The user finished or dismissed today's check-in; it won't be asked again today.
    public func closeCheckIn(_ outcome: DailyEventState) {
        guard outcome == .completed || outcome == .dismissed,
              let run = try? store.dailyRun(for: clock.calendar.dayKey(for: clock.now)) else { return }
        run.checkIn = outcome
        run.checkInAt = clock.now
        try? store.context.save()
    }

    public func todayRun() -> DailyRun? { try? store.dailyRun(for: clock.calendar.dayKey(for: clock.now)) }
}
