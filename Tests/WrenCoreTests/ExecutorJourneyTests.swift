import XCTest
@testable import WrenCore

/// The brief's task and reminder sentences, end to end: router → subsystem → store → macOS
/// schedule (FakeReminderCenter stands in for UNUserNotificationCenter).
extension ReminderSchedulerTests {
    func testRemindMeEveryWeekdayWithoutASubjectAsksWhatToRemindAbout() {
        let now = at(ist, 2026, 10, 13, 14)
        XCTAssertEqual(ExecutionRouter.operation(for: "Remind me every weekday at 3 PM.", now: now, calendar: ist).name, "CreateReminder")
        guard case let .clarify(_, question)? = ReminderCommand.parse("Remind me every weekday at 3 PM.", now: now, calendar: ist) else {
            return XCTFail("a reminder with no subject must be clarified, not guessed: \(String(describing: ReminderCommand.parse("Remind me every weekday at 3 PM.", now: now, calendar: ist)))")
        }
        XCTAssertFalse(question.isEmpty)
    }

    func testRepeatingWeekdayReminderIsScheduledAsRepeatingWallClockTriggers() async throws {
        let (h, center, s) = try setup()
        let (result, id) = try await create(h, "Remind me to stretch every weekday at 3 PM")
        XCTAssertEqual(result.status, .succeeded, result.message ?? "")
        let r = await s.reconcile()
        XCTAssertEqual(r.scheduled, 5, "one repeating request per weekday")
        XCTAssertEqual(Set(center.pending.values.compactMap { if case let .repeating(c) = $0.trigger { c.hour } else { nil } }), [15])
        XCTAssertEqual(try h.store.item(id: id)?.scheduledNotificationIDs.count, 5)
        let again = await s.reconcile()
        XCTAssertEqual(again.scheduled, 0, "a restart adds nothing")
    }

    func testMoveThatReminderToSundayTargetsTheRecentItemAndNeedsConfirmation() async throws {
        let (h, center, s) = try setup()
        let (_, id) = try await create(h, "Remind me to call Sam tomorrow at 10 AM")
        await s.reconcile()
        XCTAssertEqual(ExecutionRouter.operation(for: "Move that reminder to Sunday.", now: h.clock.now, calendar: ist).name, "ChangeItem")
        let resolver = ContextResolver(calendar: ist)
        let res = resolver.resolve("Move that reminder to Sunday.", items: try h.store.all(), goals: [], context: ConversationContext(selected: nil, recent: [id]), now: h.clock.now)
        guard case let .proposal(p) = res else { return XCTFail("\(res)") }
        XCTAssertEqual(p.request.action, BuiltInAction.reschedule)
        // Unconfirmed: nothing changes.
        let refused = await h.broker.submit(p.request)
        XCTAssertNotEqual(refused.status, .succeeded)
        // Confirmed: moved, persisted and the macOS request replaced (not duplicated).
        let done = await h.broker.submit(p.request, confirmation: h.broker.confirm(p.request))
        XCTAssertEqual(done.status, .succeeded, done.message ?? "")
        await s.reconcile()
        let sunday = ist.component(.weekday, from: try XCTUnwrap(center.onceDates.first))
        XCTAssertEqual(sunday, 1, "Sunday")
        XCTAssertEqual(center.pending.count, 1)
    }

    func testINeedToFinishTheReportByFridayBecomesADatedTask() throws {
        let now = at(ist, 2026, 10, 13, 14)   // a Tuesday
        XCTAssertEqual(ExecutionRouter.operation(for: "I need to finish the report by Friday.", now: now, calendar: ist).name, "CreateTask")
        let i = IntentProcessor(client: nil, model: nil, calendar: ist).rulesOnly("I need to finish the report by Friday.", now: now)
        XCTAssertEqual(i.kind, .commitment)
        XCTAssertEqual(i.title, "Finish the report")
        XCTAssertEqual(ist.component(.weekday, from: try XCTUnwrap(i.deadline)), 6, "Friday")
    }
}

extension ReminderSchedulerTests {
    func testAnsweringWhatToRemindAboutKeepsTheScheduleButANewDatedRequestIsntSwallowed() {
        let now = at(ist, 2026, 10, 13, 14)
        let merged = ReminderFollowUp.subjectAnswer("to stretch", pending: "Remind me every weekday at 3 PM.", now: now, calendar: ist)
        XCTAssertEqual(merged.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }, "remind me to stretch every weekday at 3 PM")
        guard case let .create(title, .repeating(rule), _)? = ReminderCommand.parse(merged ?? "", now: now, calendar: ist) else {
            return XCTFail("merged answer must be a repeating reminder")
        }
        XCTAssertEqual(title, "Stretch")
        XCTAssertEqual(rule.weekdays.count, 5)
        XCTAssertEqual(ReminderFollowUp.subjectAnswer("water the plants", pending: "remind me tomorrow at 9 AM", now: now, calendar: ist), "remind me to water the plants tomorrow at 9 AM")
        // Seen live: a new sentence with its own date isn't the answer.
        XCTAssertNil(ReminderFollowUp.subjectAnswer("I need to send the invoice by Monday.", pending: "Remind me every weekday at 3 PM.", now: now, calendar: ist))
        XCTAssertNil(ReminderFollowUp.subjectAnswer("ask GPT what to stretch", pending: "Remind me every weekday at 3 PM.", now: now, calendar: ist))
    }
}

extension ReminderSchedulerTests {
    func testAnOwnRequestAfterWhatToRemindAboutIsntMergedIntoTheSchedule() {
        let now = at(ist, 2026, 10, 13, 14)
        for answer in ["create a task to buy milk", "what's due today?", "mark the report as done"] {
            XCTAssertNil(ReminderFollowUp.subjectAnswer(answer, pending: "Remind me every weekday at 3 PM.", now: now, calendar: ist), answer)
        }
    }
}
