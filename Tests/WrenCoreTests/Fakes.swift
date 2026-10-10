import Foundation
@testable import WrenCore

@MainActor
final class FakeNotifier: WrenNotifier {
    var allowed = true
    var acceptsDelivery = true
    var reminders: [ReminderPayload] = []
    var briefings: [Briefing] = []
    var checkIns: [CheckIn] = []
    var withdrawn: [UUID] = []
    func canDeliver() async -> Bool { allowed }
    func deliverReminder(_ p: ReminderPayload) async -> Bool { guard acceptsDelivery else { return false }; reminders.append(p); return true }
    func deliverBriefing(_ b: Briefing) async -> Bool { guard acceptsDelivery else { return false }; briefings.append(b); return true }
    func deliverCheckIn(_ c: CheckIn) async -> Bool { guard acceptsDelivery else { return false }; checkIns.append(c); return true }
    func withdrawReminder(id: UUID) { withdrawn.append(id) }
}

@MainActor
final class FakeLoginService: LoginItemService {
    var status: LoginItemStatus = .disabled
    var failWith: String?
    var needsApproval = false
    var registerCalls = 0, unregisterCalls = 0
    struct Failure: LocalizedError { let errorDescription: String? }
    func register() throws {
        registerCalls += 1
        if let f = failWith { throw Failure(errorDescription: f) }
        status = needsApproval ? .requiresApproval : .enabled
    }
    func unregister() throws {
        unregisterCalls += 1
        if let f = failWith { throw Failure(errorDescription: f) }
        status = .disabled
    }
}

/// A full core stack on a store (in-memory or file) with a fixed clock.
@MainActor
struct Harness {
    let store: WrenStore
    let clock: FixedClock
    let notifier: FakeNotifier
    let policy: SwiftDataPolicyStore
    let broker: ActionBroker
    let engine: WrenEngine
    var daily = DailySettings()

    init(url: URL? = nil, now: Date, calendar: Calendar, notifier: FakeNotifier = FakeNotifier(), daily: DailySettings = DailySettings()) throws {
        store = try WrenStore(url: url)
        clock = FixedClock(now, calendar: calendar)
        self.notifier = notifier
        policy = try SwiftDataPolicyStore(context: store.context, clock: clock)
        broker = ActionBroker(context: store.context, policyStore: policy, clock: clock)
        BuiltInAction.registerLocal(on: broker, store: store, notifier: notifier, clock: clock)
        let d = daily
        engine = WrenEngine(store: store, broker: broker, clock: clock, notifier: notifier, settings: { d })
        self.daily = daily
    }

    func add(_ title: String, kind: CaptureKind = .commitment, deadline: Date? = nil, hasTime: Bool = false,
             priority: Priority = .normal, created: Date? = nil) throws -> Commitment {
        let c = try store.capture(title, source: .hotkey, now: created ?? clock.now)
        c.kind = kind; c.deadline = deadline; c.deadlineHasTime = hasTime; c.priority = priority; c.processing = .manual
        try store.context.save()
        return c
    }

    func request(_ a: ActionID, _ c: Commitment, origin: ActionOrigin = .user(.popover), params: [String: JSONValue] = [:]) -> ActionRequest {
        ActionRequest(action: a, target: c.targetRef, parameters: params, origin: origin, createdAt: clock.now)
    }

    func audit() -> [AuditRecord] { broker.recentAudit(limit: 500) }
}

func tempStoreURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("wren-\(UUID().uuidString)/Wren.store")
}
