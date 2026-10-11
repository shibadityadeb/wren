import XCTest
@testable import WrenCore

/// Stands in for UNUserNotificationCenter: holds pending requests by identifier.
@MainActor
final class FakeReminderCenter: ReminderNotificationCenter {
    var authorized = true
    var failIDs: Set<String> = []
    var pending: [String: ReminderRequest] = [:]
    var scheduledCalls = 0, cancelledIDs: [String] = []
    func isAuthorized() async -> Bool { authorized }
    func pendingReminderIDs() async -> Set<String> { Set(pending.keys) }
    func schedule(_ r: ReminderRequest) async throws {
        scheduledCalls += 1
        if failIDs.contains(where: { r.id.contains($0) }) { throw NSError(domain: "UNErrorDomain", code: 1) }
        pending[r.id] = r
    }
    func cancel(ids: [String]) { cancelledIDs += ids; ids.forEach { pending[$0] = nil } }
    var onceDates: [Date] { pending.values.compactMap { if case let .at(d) = $0.trigger { d } else { nil } }.sorted() }
}

final class ReminderCommandTests: XCTestCase {
    let ist = calendar("Asia/Kolkata")
    var now: Date { at(ist, 2026, 10, 11, 14) }   // Sunday 2 PM

    func parse(_ s: String) -> ReminderCommand? { ReminderCommand.parse(s, now: now, calendar: ist) }

    func testTheExampleSentences() {
        XCTAssertEqual(parse("Remind me to call Sam tomorrow at 10 AM."), .create(title: "Call Sam", when: .once(at(ist, 2026, 10, 12, 10)), explanation: nil))
        XCTAssertEqual(parse("Hey Wren, remind me to call Sam tomorrow at 10 AM"), .create(title: "Call Sam", when: .once(at(ist, 2026, 10, 12, 10)), explanation: nil),
                       "the wake phrase left in a transcript is ignored")
        XCTAssertEqual(parse("Remind me to submit the report Friday evening."), .create(title: "Submit the report", when: .once(at(ist, 2026, 10, 16, 18)), explanation: nil))
        XCTAssertEqual(parse("Remind me to take a break every weekday at 3 PM."),
                       .create(title: "Take a break", when: .repeating(RecurrenceRule(weekdays: [2, 3, 4, 5, 6], hour: 15, minute: 0)), explanation: nil))
        XCTAssertEqual(parse("remind me in 30 minutes to stretch"), .create(title: "Stretch", when: .once(now.addingTimeInterval(1800)), explanation: nil))
        XCTAssertNil(parse("Buy milk tomorrow"), "not a reminder request")
    }

    func testAsksInsteadOfGuessing() {
        guard case let .clarify(title, q)? = parse("Remind me to call Sam") else { return XCTFail() }
        XCTAssertEqual(title, "Call Sam"); XCTAssertTrue(q.contains("When should I remind you to call Sam"))
        guard case let .clarify(_, q2)? = parse("Remind me to call Sam tomorrow at 3") else { return XCTFail() }
        XCTAssertEqual(q2, "Is that 3 AM or 3 PM?")
        guard case let .clarify(_, q3)? = parse("Remind me to stretch every day") else { return XCTFail() }
        XCTAssertTrue(q3.hasPrefix("At what time"))
        guard case .clarify? = parse("Remind me every weekday at 3") else { return XCTFail("meridiem ambiguous for repeats too") }
        guard case let .create(_, _, explanation)? = parse("Remind me to pay rent on Friday") else { return XCTFail() }
        XCTAssertTrue(explanation!.contains("default reminder time"), "a date-only reminder says which time it used")
    }

    func testRefusesThePast() {
        guard case let .past(title, msg)? = parse("Remind me to call Sam today at 9 AM") else { return XCTFail() }
        XCTAssertEqual(title, "Call Sam"); XCTAssertTrue(msg.contains("already passed"))
    }

    func testRecurrenceAcrossDaylightSaving() throws {
        let ny = calendar("America/New_York")
        let rule = RecurrenceRule(weekdays: RecurrenceRule.weekdaySet, hour: 15, minute: 0)
        // Friday 6 Mar 2026 4 PM -> Monday 9 Mar 3 PM, after clocks went forward on Sunday 8 Mar.
        let next = try XCTUnwrap(rule.next(after: at(ny, 2026, 3, 6, 16), calendar: ny))
        XCTAssertEqual(next, at(ny, 2026, 3, 9, 15))
        XCTAssertEqual(ny.component(.hour, from: next), 15, "same wall-clock time after the change")
        // A time that doesn't exist on the change day moves to the next valid time.
        let early = RecurrenceRule(weekdays: [], hour: 2, minute: 30)
        let skip = try XCTUnwrap(early.next(after: at(ny, 2026, 3, 7, 12), calendar: ny))
        XCTAssertEqual(ny.component(.day, from: skip), 8)
        XCTAssertGreaterThan(skip, at(ny, 2026, 3, 8, 1, 59))
        XCTAssertEqual(rule.label(calendar: ny), "Every weekday at 3:00 PM")
        XCTAssertEqual(rule.triggerComponents.count, 5)
        XCTAssertEqual(RecurrenceRule.find(in: "water plants every monday and thursday at 8am", calendar: ny)?.rule,
                       RecurrenceRule(weekdays: [2, 5], hour: 8, minute: 0))
        XCTAssertEqual(RecurrenceRule.find(in: "stretch every evening", calendar: ny)?.rule, RecurrenceRule(weekdays: [], hour: 18, minute: 0))
    }
}

@MainActor
final class ReminderSchedulerTests: XCTestCase {
    let ist = calendar("Asia/Kolkata")

    func setup() throws -> (Harness, FakeReminderCenter, ReminderScheduler) {
        let h = try Harness(now: at(ist, 2026, 10, 11, 14), calendar: ist)
        let center = FakeReminderCenter()
        let s = ReminderScheduler(store: h.store, center: center, clock: h.clock)
        h.engine.scheduledByMacOS = { s.isScheduledByMacOS($0) }
        return (h, center, s)
    }

    func create(_ h: Harness, _ text: String, origin: ActionOrigin = .user(.hotkey)) async throws -> (ActionResult, UUID) {
        guard case let .create(title, when, _)? = ReminderCommand.parse(text, now: h.clock.now, calendar: ist) else { throw XCTSkip("not parsed") }
        let id = UUID()
        let r = ActionRequest(action: BuiltInAction.createReminder, target: TargetRef(kind: "commitment", id: id.uuidString, label: title),
                              parameters: BuiltInAction.createReminderParameters(text: text, title: title, when: when, source: .hotkey),
                              origin: origin, createdAt: h.clock.now)
        return (await h.broker.submit(r), id)
    }

    func testCreateIsAuditedPersistedScheduledAndFiresOnceWithoutDuplicates() async throws {
        let (h, center, s) = try setup()
        let (result, id) = try await create(h, "Remind me to call Sam tomorrow at 10 AM")
        XCTAssertEqual(result.status, .succeeded, result.message ?? "")
        let c = try XCTUnwrap(try h.store.item(id: id))
        XCTAssertEqual(c.title, "Call Sam"); XCTAssertEqual(c.nextReminderAt, at(ist, 2026, 10, 12, 10))
        XCTAssertEqual(h.audit().first?.action, BuiltInAction.createReminder.rawValue)

        let r1 = await s.reconcile()
        XCTAssertEqual(r1.scheduled, 1)
        XCTAssertEqual(center.onceDates, [at(ist, 2026, 10, 12, 10)])
        XCTAssertEqual(c.scheduledNotificationIDs.count, 1, "identifier retained on the item")
        let r2 = await s.reconcile()
        XCTAssertEqual(r2.scheduled, 0); XCTAssertEqual(r2.unchanged, 1, "restart/reconcile adds no duplicate")

        // macOS shows it at 10:00 (Wren may not even be running). On the next tick Wren records it
        // and does not send a second notification.
        h.clock.set(at(ist, 2026, 10, 12, 10, 0)); center.pending = [:]
        let tick = await h.engine.tick()
        XCTAssertEqual(tick.remindersDelivered, 1)
        XCTAssertTrue(h.notifier.reminders.isEmpty, "no duplicate notification from Wren")
        XCTAssertNil(c.nextReminderAt); XCTAssertNotNil(c.lastReminderAt)
        let again = await h.engine.tick()
        XCTAssertEqual(again.remindersDelivered, 0)
    }

    func testRescheduleSnoozeCompleteAndDeleteLeaveNoStaleRequests() async throws {
        let (h, center, s) = try setup()
        let (_, id) = try await create(h, "Remind me to call Sam tomorrow at 10 AM")
        let c = try XCTUnwrap(try h.store.item(id: id))
        await s.reconcile()
        // Snooze to 11:00: old request gone, new one in.
        _ = await h.broker.submit(h.request(BuiltInAction.snooze, c, params: ["until": .number(at(ist, 2026, 10, 12, 11).timeIntervalSince1970)]))
        await s.reconcile()
        XCTAssertEqual(center.onceDates, [at(ist, 2026, 10, 12, 11)])
        // Move the deadline: the reminder moves with it.
        _ = await h.broker.submit(h.request(BuiltInAction.reschedule, c, params: ["deadline": .number(at(ist, 2026, 10, 18, 12).timeIntervalSince1970), "hasTime": .bool(true)]))
        await s.reconcile()
        XCTAssertEqual(center.onceDates, [at(ist, 2026, 10, 18, 12)])
        // Complete: nothing left.
        _ = await h.broker.submit(h.request(BuiltInAction.complete, c))
        await s.reconcile()
        XCTAssertTrue(center.pending.isEmpty)
        // Reopen with a new reminder, then delete.
        _ = await h.broker.submit(h.request(BuiltInAction.reopen, c))
        _ = await h.broker.submit(h.request(BuiltInAction.scheduleReminder, c, params: ["at": .number(at(ist, 2026, 10, 20, 9).timeIntervalSince1970)]))
        await s.reconcile()
        XCTAssertEqual(center.onceDates, [at(ist, 2026, 10, 20, 9)])
        try h.store.delete(c)
        await s.reconcile()
        XCTAssertTrue(center.pending.isEmpty, "deleted item's notification cancelled")
    }

    func testRepeatingReminderUsesRepeatingTriggersAndKeepsGoing() async throws {
        let (h, center, s) = try setup()
        let (result, id) = try await create(h, "Remind me to take a break every weekday at 3 PM")
        XCTAssertEqual(result.status, .succeeded)
        let c = try XCTUnwrap(try h.store.item(id: id))
        XCTAssertEqual(c.nextReminderAt, at(ist, 2026, 10, 12, 15), "Monday 3 PM (today is Sunday)")
        await s.reconcile()
        let comps = center.pending.values.compactMap { if case let .repeating(c) = $0.trigger { c } else { nil } }
        XCTAssertEqual(Set(comps.compactMap(\.weekday)), [2, 3, 4, 5, 6])
        XCTAssertTrue(comps.allSatisfy { $0.hour == 15 && $0.minute == 0 })

        h.clock.set(at(ist, 2026, 10, 12, 15, 1))
        _ = await h.engine.tick()
        XCTAssertTrue(h.notifier.reminders.isEmpty, "macOS showed it from the repeating schedule")
        XCTAssertEqual(c.nextReminderAt, at(ist, 2026, 10, 13, 15), "moved on to Tuesday")
        // "Done" on a repeating one finishes today, not the series.
        _ = await h.broker.submit(h.request(BuiltInAction.completeOccurrence, c))
        XCTAssertEqual(c.status, .pending)
        // Snoozing one occurrence adds a one-off request beside the series.
        _ = await h.broker.submit(h.request(BuiltInAction.snooze, c, params: ["until": .number(at(ist, 2026, 10, 12, 15, 31).timeIntervalSince1970)]))
        await s.reconcile()
        XCTAssertEqual(center.onceDates, [at(ist, 2026, 10, 12, 15, 31)])
        XCTAssertEqual(center.pending.count, 6)
        // Completing the item in Wren ends the series.
        _ = await h.broker.submit(h.request(BuiltInAction.complete, c))
        await s.reconcile()
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testDeniedPermissionAndSchedulingErrorsAreReportedAndFallBackToInAppDelivery() async throws {
        let (h, center, s) = try setup()
        center.authorized = false
        let (_, id) = try await create(h, "Remind me to call Sam tomorrow at 10 AM")
        let c = try XCTUnwrap(try h.store.item(id: id))
        let r = await s.reconcile()
        XCTAssertFalse(r.authorized); XCTAssertTrue(center.pending.isEmpty); XCTAssertTrue(c.scheduledNotificationIDs.isEmpty)
        XCTAssertFalse(s.isScheduledByMacOS(c))
        // Permission granted later: next reconcile schedules it.
        center.authorized = true
        center.failIDs = [id.uuidString]
        let r2 = await s.reconcile()
        XCTAssertEqual(r2.failed.count, 1); XCTAssertTrue(c.scheduledNotificationIDs.isEmpty, "a failed request isn't recorded as scheduled")
        // Not scheduled by macOS, so Wren delivers it itself when it's due and running.
        h.clock.set(at(ist, 2026, 10, 12, 10, 0))
        _ = await h.engine.tick()
        XCTAssertEqual(h.notifier.reminders.map(\.id), [id])
    }

    func testPauseHoldsBackRequestsAndResumeRestoresThem() async throws {
        let h = try Harness(now: at(ist, 2026, 10, 11, 14), calendar: ist)
        let center = FakeReminderCenter()
        var pause: NotificationPause? = NotificationPause(since: h.clock.now, until: at(ist, 2026, 10, 11, 23, 59))
        let s = ReminderScheduler(store: h.store, center: center, clock: h.clock, pause: { pause })
        let c = try h.add("Call Sam"); c.nextReminderAt = at(ist, 2026, 10, 11, 18)
        let d = try h.add("Pay rent"); d.nextReminderAt = at(ist, 2026, 10, 12, 9)
        try h.store.context.save()
        await s.reconcile()
        XCTAssertEqual(center.onceDates, [at(ist, 2026, 10, 12, 9)], "only what fires after the pause")
        pause = nil
        await s.reconcile()
        XCTAssertEqual(center.onceDates, [at(ist, 2026, 10, 11, 18), at(ist, 2026, 10, 12, 9)])
    }

    func testModelSuggestionsAndContentCannotCreateRemindersOnTheirOwn() async throws {
        let (h, _, _) = try setup()
        let (fromModel, id1) = try await create(h, "Remind me to call Sam tomorrow at 10 AM", origin: .model("qwen"))
        XCTAssertNotEqual(fromModel.status, .succeeded); XCTAssertNil(try h.store.item(id: id1))
        let (fromEmail, id2) = try await create(h, "Remind me to wire money tomorrow at 10 AM", origin: .untrustedContent("email"))
        XCTAssertNotEqual(fromEmail.status, .succeeded); XCTAssertNil(try h.store.item(id: id2))
    }

    func testSnoozeAndMoveCommands() throws {
        let h = try Harness(now: at(ist, 2026, 10, 11, 14), calendar: ist)
        let api = try h.add("Fix the API rate limits", deadline: at(ist, 2026, 10, 12, 10), hasTime: true)
        api.nextReminderAt = at(ist, 2026, 10, 12, 10); api.lastReminderAt = at(ist, 2026, 10, 11, 13)
        try h.store.context.save()
        let resolver = ContextResolver(calendar: ist)
        guard case let .proposal(p) = resolver.resolve("Snooze the current reminder for 30 minutes.", items: try h.store.all(), goals: [], context: .init(), now: h.clock.now) else { return XCTFail() }
        XCTAssertEqual(p.request.action, BuiltInAction.snooze)
        XCTAssertEqual(p.request.parameters.date("until"), at(ist, 2026, 10, 11, 14, 30))
        guard case let .proposal(m) = resolver.resolve("Move my API reminder to Sunday at noon.", items: try h.store.all(), goals: [], context: .init(), now: h.clock.now) else { return XCTFail() }
        XCTAssertEqual(m.request.action, BuiltInAction.reschedule)
        XCTAssertEqual(m.request.origin, .conversational("Move my API reminder to Sunday at noon."), "inferred target: needs a confirmation")
        guard case .needsDate = resolver.resolve("snooze it", items: try h.store.all(), goals: [], context: .init(), now: h.clock.now) else { return XCTFail() }
    }

    func testTimeZoneChangeKeepsRepeatingWallClockTime() throws {
        let h = try Harness(now: at(ist, 2026, 10, 11, 14), calendar: ist)
        let c = try h.store.createReminder(text: "x", title: "Break", when: .repeating(RecurrenceRule(weekdays: [], hour: 15, minute: 0)),
                                           source: .hotkey, calendar: ist, now: h.clock.now)
        XCTAssertEqual(c.nextReminderAt, at(ist, 2026, 10, 11, 15))
        let london = calendar("Europe/London")
        try h.store.refreshRecurrences(calendar: london, now: h.clock.now)
        XCTAssertEqual(c.nextReminderAt, at(london, 2026, 10, 11, 15), "3 PM where you are now")
    }
}

final class DataDirectoryLockTests: XCTestCase {
    func testOnlyOneHolderAtATime() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wren-lock-\(UUID())")
        let first = try DataDirectoryLock.acquire(directory: dir)
        XCTAssertThrowsError(try DataDirectoryLock.acquire(directory: dir)) {
            XCTAssertEqual($0 as? DataDirectoryLock.Failure, .heldByAnotherProcess(pid: getpid()))
        }
        first.release()
        let second = try DataDirectoryLock.acquire(directory: dir)
        XCTAssertTrue(second.isHeld)
    }
}
