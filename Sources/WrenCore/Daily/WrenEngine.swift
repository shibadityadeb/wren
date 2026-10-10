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
    private var running = false

    public init(store: WrenStore, broker: ActionBroker, clock: WrenClock, notifier: WrenNotifier?, settings: @escaping () -> DailySettings) {
        self.store = store; self.broker = broker; self.clock = clock; self.notifier = notifier; self.settings = settings
    }

    public struct TickReport: Sendable, Equatable {
        public var remindersDelivered = 0
        public var remindersUndelivered = 0
        public var briefing: DailyEventState?
        public var checkIn: DailyEventState?
    }

    /// Safe to call any time (launch, wake, timer, clock change). Re-entrant calls are ignored.
    @discardableResult
    public func tick() async -> TickReport {
        var report = TickReport()
        guard !running else { return report }
        running = true
        defer { running = false }

        // 1. Reminders, through the broker, as the scheduler under the auto-remind rule.
        let canDeliver = await notifier?.canDeliver() ?? false
        if canDeliver, let due = try? ReminderPolicy.due(store.pending(), now: clock.now) {
            for c in due {
                let r = ActionRequest(action: BuiltInAction.deliverReminder, target: c.targetRef, origin: .system("reminders"), createdAt: clock.now)
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

    /// When the app should call tick() next.
    public func nextWake() -> Date {
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
            let empty: Bool
            switch e {
            case .briefing: empty = Briefing.build(from: items, now: now, calendar: cal).isEmpty
            case .checkIn: empty = CheckIn.build(from: items, now: now, calendar: cal).isEmpty
            }
            if empty && !s.sendEmptySummaries { set(.skippedEmpty); return .skippedEmpty }
            // Record first (at-most-once), then deliver.
            set(.sent)
            guard canDeliver, let notifier else { set(.undelivered); return .undelivered }
            let ok: Bool
            switch e {
            case .briefing: ok = await notifier.deliverBriefing(Briefing.build(from: items, now: now, calendar: cal))
            case .checkIn: ok = await notifier.deliverCheckIn(CheckIn.build(from: items, now: now, calendar: cal))
            }
            if !ok { set(.undelivered); return .undelivered }
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
