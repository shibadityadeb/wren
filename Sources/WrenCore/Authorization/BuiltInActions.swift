import Foundation

public enum BuiltInAction {
    public static let complete: ActionID = "item.complete"
    public static let reopen: ActionID = "item.reopen"
    public static let drop: ActionID = "item.drop"
    public static let delete: ActionID = "item.delete"
    public static let edit: ActionID = "item.edit"
    public static let snooze: ActionID = "item.snooze"
    public static let scheduleReminder: ActionID = "reminder.schedule"
    public static let deliverReminder: ActionID = "reminder.deliver"
    public static let applyInterpretation: ActionID = "item.applyInterpretation"
    public static let createReminder: ActionID = "reminder.create"
    public static let completeOccurrence: ActionID = "reminder.completeOccurrence"
    public static let setRepeat: ActionID = "reminder.setRepeat"
    /// Parameters for `createReminder`.
    public static func createReminderParameters(text: String, title: String, when: ReminderWhen, source: CaptureSource, deadline: ParsedDate? = nil) -> [String: JSONValue] {
        CreateReminderHandler.parameters(text: text, title: title, when: when, source: source, deadline: deadline)
    }
    /// Parameters for `setRepeat` (nil stops repeating).
    public static func setRepeatParameters(_ rule: RecurrenceRule?) -> [String: JSONValue] {
        rule.map { ["repeat": CreateReminderHandler.ruleParameter($0)] } ?? [:]
    }
    /// Hour used when a moved deadline has no time ("move it to Friday"). Set by the app from settings.
    @MainActor public static var defaultReminderHour: () -> Int = { 10 }
    // Reserved for later phases: declared so policy and tests cover them, no handlers yet.
    public static let readEmail: ActionID = "email.read"
    public static let archiveEmail: ActionID = "email.archive"
    public static let markEmailRead: ActionID = "email.markRead"
    public static let sendEmail: ActionID = "email.send"
    public static let deleteEmailPermanently: ActionID = "email.deletePermanently"
    public static let delegateToExternalAI: ActionID = "ai.delegate"
    public static let readCalendar: ActionID = "calendar.read"
    public static let readNotion: ActionID = "notion.read"
    public static let createNotionPage: ActionID = "notion.createPage"
    public static let chatgptHandoff: ActionID = "chatgpt.handoff"

    public static let reservedExternal: [ActionDescriptor] = [
        .init(id: readEmail, category: .externalRead, permission: .emailRead, confirmation: .none,
              summary: "Read email", verification: "Provider returns the messages"),
        .init(id: markEmailRead, category: .externalWrite, permission: .emailModify, confirmation: .always,
              summary: "Mark an email as read in Gmail", verification: "Gmail returns the message's labels without UNREAD"),
        .init(id: archiveEmail, category: .externalWrite, permission: .emailModify, confirmation: .always,
              summary: "Archive email", verification: "Re-fetch labels; INBOX absent"),
        .init(id: sendEmail, category: .irreversible, permission: .emailSend, confirmation: .always,
              summary: "Send email", verification: "Provider returns a sent message ID"),
        .init(id: deleteEmailPermanently, category: .irreversible, permission: .emailModify, confirmation: .always,
              summary: "Permanently delete email", verification: "Message no longer retrievable"),
        .init(id: delegateToExternalAI, category: .externalWrite, permission: .externalAI, confirmation: .always,
              summary: "Send a request to ChatGPT using your plan", verification: "Complete response received; model requested and model reported"),
        .init(id: readCalendar, category: .externalRead, permission: .calendarRead, confirmation: .none,
              summary: "Read Google Calendar events", verification: "Provider returned events"),
        .init(id: readNotion, category: .externalRead, permission: .notionRead, confirmation: .none,
              summary: "Read Notion pages shared with Wren", verification: "Provider returned pages"),
        .init(id: createNotionPage, category: .externalWrite, permission: .notionWrite, confirmation: .always,
              summary: "Create a Notion page", verification: "Notion returned the new page"),
        .init(id: chatgptHandoff, category: .externalWrite, permission: .chatgptHandoff, confirmation: .always,
              summary: "Copy a prompt and open ChatGPT", verification: "Prompt copied and ChatGPT opened (not sent: you send it)"),
    ]

    /// Registers handlers for every local action.
    @MainActor
    public static func registerLocal(on broker: ActionBroker, store: WrenStore, notifier: WrenNotifier?, clock: WrenClock) {
        let defs: [(ActionDescriptor, StoreHandler.Body, StoreHandler.Check)] = [
            (.init(id: complete, category: .localReversible, permission: .manageItems, confirmation: .none,
                   summary: "Mark done", verification: "Item status is completed"),
             { s, c, _ in try s.complete(c, now: clock.now); notifier?.withdrawReminder(id: c.id); return nil },
             { c, _ in c?.status == .completed }),
            (.init(id: reopen, category: .localReversible, permission: .manageItems, confirmation: .none,
                   summary: "Reopen", verification: "Item status is pending"),
             { s, c, _ in try s.reopen(c, now: clock.now); return nil },
             { c, _ in c?.status == .pending }),
            (.init(id: drop, category: .localReversible, permission: .manageItems, confirmation: .none,
                   summary: "Drop (can be reopened)", verification: "Item status is dropped"),
             { s, c, _ in try s.drop(c, now: clock.now); notifier?.withdrawReminder(id: c.id); return nil },
             { c, _ in c?.status == .dropped }),
            (.init(id: delete, category: .localDestructive, permission: .deleteItems, confirmation: .always,
                   summary: "Delete permanently", verification: "Item no longer exists"),
             { s, c, _ in notifier?.withdrawReminder(id: c.id); try s.delete(c); return nil },
             { c, _ in c == nil }),
            (.init(id: snooze, category: .localReversible, permission: .reminders, confirmation: .none,
                   summary: "Snooze", verification: "Next reminder equals the requested time"),
             { s, c, p in
                 guard let until = p.date("until") else { throw BrokerError.badParameter("until") }
                 try s.snooze(c, until: until, now: clock.now)
                 notifier?.withdrawReminder(id: c.id)
                 return "until \(WrenStore.stamp(until))"
             },
             { c, p in c?.nextReminderAt == p.date("until") }),
            (.init(id: scheduleReminder, category: .localReversible, permission: .reminders, confirmation: .none,
                   summary: "Set a reminder", verification: "Next reminder equals the requested time"),
             { s, c, p in
                 guard let at = p.date("at") else { throw BrokerError.badParameter("at") }
                 try s.scheduleReminder(c, at: at, now: clock.now)
                 return "at \(WrenStore.stamp(at))"
             },
             { c, p in c?.nextReminderAt == p.date("at") }),
            (.init(id: edit, category: .localReversible, permission: .manageItems, confirmation: .none,
                   summary: "Edit", verification: "Stored fields equal the edit"),
             { s, c, p in try s.edit(c, try p.edit(), now: clock.now); return nil },
             { c, p in (try? p.edit()).map { c?.title == $0.title.trimmingCharacters(in: .whitespacesAndNewlines) && c?.kind == $0.kind } ?? false }),
            (.init(id: applyInterpretation, category: .localReversible, permission: .manageItems, confirmation: .none,
                   summary: "Apply the model's reading of your capture", verification: "Item kind and title match"),
             { s, c, p in
                 guard c.processing != .manual else { throw BrokerError.refused("You edited this item; Wren won't overwrite it.") }
                 let i = try p.interpretation()
                 // Deadline reminders only when the auto-remind rule is on (checked by the caller via policy).
                 let policy = p.bool("scheduleReminders") == false ? nil : p.reminderPolicy(clock)
                 try s.applyInterpretation(i, to: c, model: p.string("model"), reminderPolicy: policy,
                                           state: p.string("state").flatMap(ProcessingState.init(rawValue:)) ?? .processed, now: clock.now)
                 return nil
             },
             { c, p in (try? p.interpretation()).map { c?.kind == $0.kind && c?.title == $0.title } ?? false }),
        ]
        let occurrence: (ActionDescriptor, StoreHandler.Body, StoreHandler.Check) = (
            .init(id: completeOccurrence, category: .localReversible, permission: .manageItems, confirmation: .none,
                  summary: "Mark this time done (the reminder keeps repeating)", verification: "The next occurrence is later than now"),
            { s, c, _ in
                try s.completeOccurrence(c, calendar: clock.calendar, now: clock.now)
                notifier?.withdrawReminder(id: c.id)
                return c.nextReminderAt.map { "next \(WrenStore.stamp($0))" }
            },
            { c, _ in c.map { $0.status == .pending && ($0.recurrence == nil || ($0.nextReminderAt ?? .distantPast) > clock.now) } ?? false })
        let repeatDef: (ActionDescriptor, StoreHandler.Body, StoreHandler.Check) = (
            .init(id: setRepeat, category: .localReversible, permission: .reminders, confirmation: .none,
                  summary: "Change how often a reminder repeats", verification: "The stored repeat equals the request"),
            { s, c, p in
                let rule = CreateReminderHandler.rule(p)
                try s.setRepeat(c, rule, calendar: clock.calendar, now: clock.now)
                return rule.map { $0.label(calendar: clock.calendar) } ?? "no longer repeats"
            },
            { c, p in c?.recurrence == CreateReminderHandler.rule(p) })
        for (d, body, check) in defs + [occurrence, repeatDef] { broker.register(StoreHandler(descriptor: d, store: store, body: body, check: check)) }
        broker.register(DeliverReminderHandler(store: store, notifier: notifier, clock: clock))
        broker.register(CreateReminderHandler(store: store, clock: clock))
        registerContextual(on: broker, store: store, clock: clock)
    }
}

public enum BrokerError: Error, LocalizedError, Equatable {
    case badParameter(String), targetMissing, refused(String), notificationsUnavailable
    public var errorDescription: String? {
        switch self {
        case let .badParameter(p): "Missing or invalid parameter “\(p)”."
        case .targetMissing: "That item no longer exists."
        case let .refused(r): r
        case .notificationsUnavailable: "Notifications are not available."
        }
    }
}

/// Handler for an action on one Commitment, identified by the request's target id.
@MainActor
final class StoreHandler: ActionHandler {
    typealias Body = @MainActor (WrenStore, Commitment, [String: JSONValue]) throws -> String?
    typealias Check = @MainActor (Commitment?, [String: JSONValue]) -> Bool
    let descriptor: ActionDescriptor
    let store: WrenStore
    let body: Body
    let check: Check

    init(descriptor: ActionDescriptor, store: WrenStore, body: @escaping Body, check: @escaping Check) {
        self.descriptor = descriptor; self.store = store; self.body = body; self.check = check
    }

    func execute(_ r: ActionRequest) async throws -> HandlerOutcome {
        guard r.target.kind == "commitment", let id = UUID(uuidString: r.target.id), let c = try store.item(id: id) else {
            throw BrokerError.targetMissing
        }
        return HandlerOutcome(detail: try body(store, c, r.parameters))
    }

    func verify(_ r: ActionRequest) async -> Verification {
        let c = UUID(uuidString: r.target.id).flatMap { try? store.item(id: $0) }
        return check(c, r.parameters) ? .verified : .mismatch
    }
}

/// Hands a due reminder to macOS, then records it as sent.
@MainActor
final class DeliverReminderHandler: ActionHandler {
    let descriptor = ActionDescriptor(id: BuiltInAction.deliverReminder, category: .localReversible, permission: .notify,
                                      confirmation: .none, summary: "Show a reminder notification",
                                      verification: "macOS accepted the notification and the item records it as sent")
    let store: WrenStore
    let notifier: WrenNotifier?
    let clock: WrenClock
    init(store: WrenStore, notifier: WrenNotifier?, clock: WrenClock) { self.store = store; self.notifier = notifier; self.clock = clock }

    func execute(_ r: ActionRequest) async throws -> HandlerOutcome {
        guard let id = UUID(uuidString: r.target.id), let c = try store.item(id: id) else { throw BrokerError.targetMissing }
        guard ReminderPolicy.isDue(c, now: clock.now) else { throw BrokerError.refused("Not due.") }
        // macOS already held a scheduled notification for exactly this time: record it, don't repeat it.
        if r.parameters.bool("byMacOS") == true {
            let at = c.nextReminderAt ?? clock.now
            try store.markReminderSent(c, now: clock.now, note: "shown by macOS at \(WrenStore.stamp(at))", calendar: clock.calendar)
            return HandlerOutcome(detail: "scheduled notification shown by macOS")
        }
        guard let notifier else { throw BrokerError.notificationsUnavailable }
        let late = (c.nextReminderAt.map { clock.now.timeIntervalSince($0) } ?? 0) > 5 * 60
        guard await notifier.deliverReminder(ReminderPayload(id: c.id, title: c.title, body: ReminderPayload.body(for: c), late: late)) else {
            throw BrokerError.notificationsUnavailable
        }
        try store.markReminderSent(c, now: clock.now, calendar: clock.calendar)
        return HandlerOutcome(detail: late ? "late delivery" : nil)
    }

    func verify(_ r: ActionRequest) async -> Verification {
        guard let id = UUID(uuidString: r.target.id), let c = try? store.item(id: id), let last = c.lastReminderAt else { return .mismatch }
        // One-off: nothing left to send. Repeating: moved on to a later occurrence.
        return c.nextReminderAt == nil || c.nextReminderAt! > last ? .verified : .mismatch
    }
}

/// Creates a reminder the user asked for in so many words ("remind me to … tomorrow at 10").
/// The target id is the new item's id, chosen before it exists, so the audit entry points at it.
@MainActor
final class CreateReminderHandler: ActionHandler {
    let descriptor = ActionDescriptor(id: BuiltInAction.createReminder, category: .localReversible, permission: .reminders,
                                      confirmation: .none, summary: "Create a reminder",
                                      verification: "The item exists and its next reminder equals the requested time")
    let store: WrenStore
    let clock: WrenClock
    init(store: WrenStore, clock: WrenClock) { self.store = store; self.clock = clock }

    static func when(_ p: [String: JSONValue]) -> ReminderWhen? {
        if let d = p.date("at") { return .once(d) }
        return rule(p).map { .repeating($0) }
    }

    nonisolated static func rule(_ p: [String: JSONValue]) -> RecurrenceRule? {
        guard case let .object(o)? = p["repeat"], case let .number(h)? = o["hour"], case let .number(m)? = o["minute"] else { return nil }
        let days: [Int] = { if case let .array(a)? = o["weekdays"] { return a.compactMap { if case let .number(n) = $0 { Int(n) } else { nil } } }; return [] }()
        return RecurrenceRule(weekdays: days, hour: Int(h), minute: Int(m))
    }

    nonisolated static func ruleParameter(_ r: RecurrenceRule) -> JSONValue {
        .object(["weekdays": .array(r.weekdays.map { .number(Double($0)) }), "hour": .number(Double(r.hour)), "minute": .number(Double(r.minute))])
    }

    nonisolated static func parameters(text: String, title: String, when: ReminderWhen, source: CaptureSource, deadline: ParsedDate? = nil) -> [String: JSONValue] {
        var p: [String: JSONValue] = ["text": .string(text), "title": .string(title), "source": .string(source.rawValue)]
        if let deadline {
            p["deadline"] = .number(deadline.date.timeIntervalSince1970)
            p["deadlineHasTime"] = .bool(deadline.hasTime)
        }
        switch when {
        case let .once(d): p["at"] = .number(d.timeIntervalSince1970)
        case let .repeating(r): p["repeat"] = ruleParameter(r)
        }
        return p
    }

    func execute(_ r: ActionRequest) async throws -> HandlerOutcome {
        guard r.target.kind == "commitment", let id = UUID(uuidString: r.target.id) else { throw BrokerError.badParameter("target") }
        guard try store.item(id: id) == nil else { throw BrokerError.refused("That reminder already exists.") }
        guard let text = r.parameters.string("text"), let title = r.parameters.string("title"), !title.isEmpty else { throw BrokerError.badParameter("title") }
        guard let when = Self.when(r.parameters) else { throw BrokerError.badParameter("when") }
        let source = r.parameters.string("source").flatMap(CaptureSource.init(rawValue:)) ?? .hotkey
        let deadline = r.parameters.date("deadline").map { ParsedDate(date: $0, hasTime: r.parameters.bool("deadlineHasTime") ?? false, isApproximate: false, phrase: "") }
        let c = try store.createReminder(text: text, title: title, when: when, source: source, id: id, deadline: deadline, calendar: clock.calendar, now: clock.now)
        switch when {
        case let .once(d): return HandlerOutcome(detail: "for \(WrenStore.stamp(d))")
        case let .repeating(rule): return HandlerOutcome(detail: rule.label(calendar: clock.calendar) + (c.nextReminderAt.map { ", first \(WrenStore.stamp($0))" } ?? ""))
        }
    }

    func verify(_ r: ActionRequest) async -> Verification {
        guard let id = UUID(uuidString: r.target.id), let c = try? store.item(id: id), let when = Self.when(r.parameters) else { return .mismatch }
        switch when {
        case let .once(d): return c.nextReminderAt == d && c.status == .pending ? .verified : .mismatch
        case let .repeating(rule): return c.recurrence == rule && c.nextReminderAt != nil ? .verified : .mismatch
        }
    }
}

// MARK: Parameter helpers

extension Dictionary where Key == String, Value == JSONValue {
    func date(_ k: String) -> Date? { if case let .number(n)? = self[k] { Date(timeIntervalSince1970: n) } else { nil } }
    func string(_ k: String) -> String? { if case let .string(s)? = self[k] { s } else { nil } }
    func bool(_ k: String) -> Bool? { if case let .bool(b)? = self[k] { b } else { nil } }

    func edit() throws -> WrenStore.Edit {
        guard let title = string("title") else { throw BrokerError.badParameter("title") }
        return WrenStore.Edit(title: title, details: string("details"),
                              kind: string("kind").flatMap(CaptureKind.init(rawValue:)) ?? .unsorted,
                              priority: string("priority").flatMap { Int($0) }.flatMap(Priority.init(rawValue:)) ?? .normal,
                              deadline: date("deadline"), deadlineHasTime: bool("deadlineHasTime") ?? false,
                              nextReminderAt: date("nextReminderAt"))
    }

    func interpretation() throws -> Interpretation {
        guard let k = string("kind").flatMap(CaptureKind.init(rawValue:)) else { throw BrokerError.badParameter("kind") }
        guard let title = string("title"), !title.isEmpty else { throw BrokerError.badParameter("title") }
        return Interpretation(kind: k, title: title,
                              priority: string("priority").flatMap { Int($0) }.flatMap(Priority.init(rawValue:)) ?? .normal,
                              deadline: date("deadline"), deadlineHasTime: bool("deadlineHasTime") ?? false, note: string("note"))
    }

    func reminderPolicy(_ clock: WrenClock) -> ReminderPolicy {
        var hour = 10
        if case let .number(n)? = self["dateOnlyReminderHour"] { hour = Int(n) }
        return ReminderPolicy(dateOnlyReminderHour: hour, calendar: clock.calendar)
    }
}

public extension WrenStore.Edit {
    var parameters: [String: JSONValue] {
        [
            "title": .string(title), "details": details.map(JSONValue.string) ?? .null, "kind": .string(kind.rawValue),
            "priority": .string(String(priority.rawValue)),
            "deadline": deadline.map { .number($0.timeIntervalSince1970) } ?? .null,
            "deadlineHasTime": .bool(deadlineHasTime),
            "nextReminderAt": nextReminderAt.map { .number($0.timeIntervalSince1970) } ?? .null,
        ]
    }
}

public extension Interpretation {
    func parameters(model: String?, state: ProcessingState, dateOnlyReminderHour: Int, scheduleReminders: Bool = true) -> [String: JSONValue] {
        [
            "scheduleReminders": .bool(scheduleReminders),
            "kind": .string(kind.rawValue), "title": .string(title), "priority": .string(String(priority.rawValue)),
            "deadline": deadline.map { .number($0.timeIntervalSince1970) } ?? .null, "deadlineHasTime": .bool(deadlineHasTime),
            "note": note.map(JSONValue.string) ?? .null, "model": model.map(JSONValue.string) ?? .null,
            "state": .string(state.rawValue), "dateOnlyReminderHour": .number(Double(dateOnlyReminderHour)),
        ]
    }
}

public extension Commitment {
    var targetRef: TargetRef { TargetRef(kind: "commitment", id: id.uuidString, label: title) }
}
