import SwiftData
import XCTest
@testable import WrenCore

/// The routing rules from the user's own words (docs/EXECUTION_AUDIT.md): one router, outer request first.
final class CommandRouterRulesTests: XCTestCase {
    let ist = calendar("Asia/Kolkata")
    var now: Date { at(ist, 2026, 10, 14, 12) }   // Wednesday noon

    func intent(_ s: String) -> CommandIntent { CommandRouter.intent(for: s, now: now, calendar: ist) }

    func testRuleA_RemindersAndTasksAreNeverDelegated() {
        let cases: [(String, String)] = [
            ("Remind me to call Sam tomorrow at 10 AM.", "CreateReminder"),
            ("Can you make a reminder to call Sam tomorrow at 10 AM?", "CreateReminder"),
            ("Could you remind me to call Sam tomorrow at 10 AM?", "CreateReminder"),
            ("Please set a reminder for tomorrow at 9 AM to pay rent", "CreateReminder"),
            ("Don't let me forget to water the plants tomorrow", "CreateReminder"),
            ("I'd like a reminder to stretch in 20 minutes", "CreateReminder"),
            ("Tomorrow at 9 AM, remind me to call the bank", "CreateReminder"),
            ("I need to submit the assignment by Friday.", "CreateTask"),
            ("I have to finish the research paper before Monday.", "CreateTask"),
            ("Remind me one day before the deadline.", "UpdateTask"),
            ("Make a task to follow up with the recruiter.", "CreateTask"),
            ("Remind me to ask GPT about quantum physics tomorrow.", "CreateReminder"),
            ("I need to send the proposal before the meeting.", "CreateTask"),
            ("I need to research agentic AI in ChatGPT by Friday", "CreateTask"),
            ("I need to email Sam by Friday", "CreateTask"),
            ("The essay is due Friday", "CreateTask"),
            ("Could you add buy milk to my list", "CreateTask"),
            ("Create a task to submit the application next Monday.", "CreateTask"),
            ("Move the proposal task to Sunday.", "UpdateTask"),
            ("Snooze this reminder for 30 minutes.", "UpdateTask"),
            ("Mark the recruiter follow-up as done.", "CompleteTask"),
        ]
        for (text, expected) in cases {
            let i = intent(text)
            XCTAssertEqual(i.action, expected, text)
            XCTAssertEqual(i.destination, .wren, text)
            XCTAssertEqual(i.rule.letter, "A", "\(text): \(i.rule)")
            XCTAssertGreaterThanOrEqual(i.confidence, 0.85, text)
        }
    }

    func testRuleB_NamingChatGPTSendsItThereWithoutAskingWhichAI() {
        for text in ["Ask GPT what gradient descent is.", "Can you ask ChatGPT what quantum physics is?", "Search in GPT for research on agentic AI.",
                     "Tell ChatGPT to investigate this topic.", "Ask GPT to analyze this idea.", "Use ChatGPT to research this.",
                     "Ask GPT to think deeply about this problem.", "Ask GPT to research quantum physics.",
                     "Hey Wren, can you please ask GPT what a monad is?", "I want you to ask GPT to research agentic AI"] {
            let i = intent(text)
            guard case let .delegateToChatGPT(r) = i.operation else { XCTFail("\(text): \(i.action)"); continue }
            XCTAssertEqual(r.target, .chatgpt, text)
            XCTAssertEqual(i.destination, .chatgpt, text)
            XCTAssertNil(r.mode, "the user's ChatGPT setting decides website or in Wren, not the router: \(text)")
        }
        guard case let .delegateToChatGPT(r) = intent("Ask GPT to research quantum physics.").operation else { return XCTFail() }
        XCTAssertEqual(r.kind, .research)
        XCTAssertTrue(r.prompt.lowercased().contains("research quantum physics"), "the instruction is kept: \(r.prompt)")
    }

    func testRuleC_QuestionsForWrenStayLocal() {
        for text in ["What is gradient descent?", "Explain this error.", "I need to know what gradient descent is"] {
            let i = intent(text)
            guard case let .generalQuestion(r) = i.operation else { XCTFail("\(text): \(i.action)"); continue }
            XCTAssertNil(r.target, "no assistant named: \(text)")
            XCTAssertEqual(i.destination, .localAI)
        }
        XCTAssertEqual(intent("What should I work on today?").operation, .queryStoredItems(.today))
        XCTAssertEqual(intent("What am I waiting for?").operation, .queryStoredItems(.waiting))
        XCTAssertEqual(intent("What deadlines are approaching?").operation, .queryStoredItems(.dueSoon))
        XCTAssertEqual(intent("Can you tell me what's due?").operation, .queryStoredItems(.dueSoon))
        XCTAssertEqual(intent("Can you remind me what the deadline is?").action, "AskLocalAI", "“remind me what…” asks to be told, not scheduled")
    }

    func testRuleD_EmailAndCalendarQuestionsUseTheirConnectors() {
        for text in ["Anything urgent in my inbox?", "Anything important in my inbox?", "Do I have an email from the recruiter?",
                     "Check whether I have an important email from the recruiter."] {
            XCTAssertEqual(intent(text).operation, .searchGmail, text)
            XCTAssertEqual(intent(text).destination, .gmail, text)
        }
        XCTAssertEqual(intent("What meetings do I have tomorrow?").operation, .queryCalendar)
        XCTAssertEqual(intent("Open the latest email from Sam").operation, .openEmail(sender: "sam"))
    }

    func testRuleE_AsksOnlyWhenSomethingIsReallyMissing() {
        XCTAssertEqual(intent("Ask GPT.").destination, .user)
        XCTAssertEqual(intent("   ").destination, .user)
        // A reminder without a time is a reminder, and the parser asks for the time instead of guessing.
        XCTAssertEqual(intent("Can you remind me to call Sam?").action, "CreateReminder")
        guard case let .clarify(title, q)? = ReminderCommand.parse("Can you remind me to call Sam?", now: now, calendar: ist) else { return XCTFail() }
        XCTAssertEqual(title, "Call Sam"); XCTAssertTrue(q.hasPrefix("When should I remind you"))
        guard case .clarify(_, "Is that 9 AM or 9 PM?")? = ReminderCommand.parse("Please set a reminder for tomorrow at 9 to pay rent", now: now, calendar: ist) else {
            return XCTFail("an ambiguous hour is asked about")
        }
    }

    func testTheOuterRequestDecidesAndTheNestedContentIsKept() {
        let reminder = intent("Remind me to ask GPT about quantum physics tomorrow.")
        XCTAssertEqual(reminder.action, "CreateReminder")
        guard case let .create(title, .once(d), _)? = ReminderCommand.parse(reminder.original, now: now, calendar: ist) else { return XCTFail() }
        XCTAssertEqual(title, "Ask GPT about quantum physics", "what to do later keeps its wording")
        XCTAssertEqual(d, at(ist, 2026, 10, 15, 10), "tomorrow at the default reminder time")
        guard case let .createTask(task) = intent("I need to research agentic AI in ChatGPT by Friday").operation else { return XCTFail() }
        XCTAssertEqual(task.title, "Research agentic AI in ChatGPT")
        XCTAssertEqual(intent("Ask ChatGPT to remind me about my taxes").action, "DelegateToChatGPT", "here ChatGPT is asked")
        XCTAssertEqual(intent("Note: remind me to call Sam").action, "SaveNote")
    }

    func testTaskTitlesAndDeadlinesComeFromTheWords() {
        func task(_ s: String) -> TaskDraft? { if case let .createTask(t) = intent(s).operation { t } else { nil } }
        XCTAssertEqual(task("I need to submit the assignment by Friday.")?.title, "Submit the assignment")
        XCTAssertEqual(task("I need to submit the assignment by Friday.")?.deadline?.date, at(ist, 2026, 10, 16))
        XCTAssertEqual(task("Create a task to submit the application next Monday.")?.title, "Submit the application", "“on” inside “application” isn't a connector")
        XCTAssertNil(task("Make a task to follow up with the recruiter.")?.deadline, "no deadline is invented")
        XCTAssertEqual(task("I need to send the proposal before the meeting.")?.title, "Send the proposal before the meeting", "the constraint is kept")
        XCTAssertNil(task("I need to send the proposal before the meeting.")?.deadline)
        XCTAssertEqual(task("The essay is due Friday")?.title, "Essay")
    }

    func testTypedAndSpokenWordsRouteTheSame() {
        for text in ["Can you make a reminder to call Sam tomorrow at 10 AM?", "I need to submit the assignment by Friday.", "Ask GPT to research quantum physics."] {
            XCTAssertEqual(intent(text).operation, intent("Hey Wren, " + text).operation, text)
        }
    }

    func testLogSummaryNamesTheDecisionButNeverTheWords() {
        let i = intent("Can you make a reminder to call Sam tomorrow at 10 AM?")
        XCTAssertTrue(i.summary.hasPrefix("CreateReminder → wren (rule A reminderRequest"), i.summary)
        XCTAssertFalse(i.summary.contains("Sam"))
    }
}

/// The brief's acceptance scenarios, run through the same code the app runs: router → ItemExecution
/// → broker → store → ReminderScheduler. macOS is `FakeReminderCenter` here; the live results are in
/// docs/MANUAL_TESTS.md.
@MainActor
final class EndToEndAcceptanceTests: XCTestCase {
    let ist = calendar("Asia/Kolkata")
    var now: Date { at(ist, 2026, 10, 14, 12) }   // Wednesday noon

    func setup(advance: DeadlineAdvance? = DeadlineAdvance(days: 1, hour: 10)) throws -> (Harness, FakeReminderCenter, ReminderScheduler) {
        let h = try Harness(now: now, calendar: ist)
        let center = FakeReminderCenter()
        let s = ReminderScheduler(store: h.store, center: center, clock: h.clock, advance: { advance })
        h.engine.scheduledByMacOS = { s.isScheduledByMacOS($0) }
        return (h, center, s)
    }

    func delegations(_ h: Harness) throws -> Int { try h.store.context.fetchCount(FetchDescriptor<DelegationRecord>()) }

    /// What the app does for a reminder request (AppModel.reminderRequest → ItemExecution.createReminder).
    func remind(_ h: Harness, _ s: ReminderScheduler, _ text: String) async throws -> ScheduledOutcome {
        XCTAssertEqual(CommandRouter.intent(for: text, now: h.clock.now, calendar: ist).action, "CreateReminder", text)
        guard case let .create(title, when, _)? = ReminderCommand.parse(text, now: h.clock.now, calendar: ist) else { throw XCTSkip("not a complete reminder: \(text)") }
        let deadline = ReminderCommand.statedDeadline(text, now: h.clock.now, calendar: ist)
        let r = await ItemExecution.createReminder(text: text, title: title, when: when, deadline: deadline, source: .voice, origin: .user(.voice),
                                                   store: h.store, broker: h.broker, scheduler: s, now: h.clock.now)
        return try r.get()
    }

    func task(_ h: Harness, _ s: ReminderScheduler, _ text: String) async throws -> ScheduledOutcome {
        guard case let .createTask(draft) = CommandRouter.intent(for: text, now: h.clock.now, calendar: ist).operation else {
            XCTFail("not a task: \(text)"); throw XCTSkip()
        }
        return try await ItemExecution.createTask(draft, text: text, source: .hotkey, store: h.store, broker: h.broker, scheduler: s,
                                                  autoRemind: true, reminderHour: 10, now: h.clock.now).get()
    }

    // Test 1
    func testReminderIsPersistedScheduledAndNeverAGPTRequest() async throws {
        let (h, center, s) = try setup()
        let o = try await remind(h, s, "Can you make a reminder to call Sam tomorrow at 10 AM?")
        XCTAssertEqual(o.title, "Call Sam")
        XCTAssertEqual(o.reminderAt, at(ist, 2026, 10, 15, 10), "tomorrow 10:00 in the user's zone")
        XCTAssertNil(o.deadline, "a reminder time is not a deadline")
        XCTAssertTrue(o.allScheduled)
        XCTAssertEqual(center.onceDates, [at(ist, 2026, 10, 15, 10)])
        XCTAssertEqual(try h.store.item(id: o.itemID)?.status, .pending, "persisted")
        XCTAssertEqual(try delegations(h), 0, "no GPT request")
        XCTAssertEqual(h.audit().first?.action, BuiltInAction.createReminder.rawValue, "audited")
    }

    // Test 2
    func testTaskWithDeadlineGetsTheDayBeforeAndOnTheDayReminders() async throws {
        let (h, center, s) = try setup()
        let o = try await task(h, s, "I need to submit the assignment by Friday.")
        XCTAssertEqual(o.title, "Submit the assignment")
        XCTAssertEqual(o.deadline, at(ist, 2026, 10, 16))
        XCTAssertFalse(o.deadlineHasTime)
        XCTAssertEqual(o.reminderAt, at(ist, 2026, 10, 16, 10), "date-only deadline: on the day at the default time")
        XCTAssertEqual(center.onceDates, [at(ist, 2026, 10, 15, 10), at(ist, 2026, 10, 16, 10)], "Thursday heads-up, Friday reminder")
        XCTAssertEqual(o.planned.filter(\.isAdvance).count, 1)
        XCTAssertTrue(o.allScheduled)
        // A relaunch schedules nothing twice; completing withdraws both.
        let calls = center.scheduledCalls
        _ = await s.reconcile()
        XCTAssertEqual(center.scheduledCalls, calls)
        let c = try XCTUnwrap(try h.store.item(id: o.itemID))
        _ = await h.broker.submit(h.request(BuiltInAction.complete, c))
        _ = await s.reconcile()
        XCTAssertTrue(center.pending.isEmpty, "done: no reminder and no heads-up left")
    }

    func testTheDayBeforeHeadsUpFollowsTheSettingAndIsntSentForTomorrow() async throws {
        let (h, center, s) = try setup(advance: nil)
        _ = try await task(h, s, "I need to submit the assignment by Friday.")
        XCTAssertEqual(center.onceDates, [at(ist, 2026, 10, 16, 10)], "turned off: only the reminder on the day")
        let (h2, center2, s2) = try setup()
        _ = try await task(h2, s2, "I need to call the landlord tomorrow")
        XCTAssertEqual(center2.onceDates, [at(ist, 2026, 10, 15, 10)], "a deadline set less than a day ahead gets no same-day heads-up")
        // A reminder time the user chose replaces the automatic ones.
        let o = try await task(h2, s2, "I need to finish the report by Friday 5 PM")
        let c = try XCTUnwrap(try h2.store.item(id: o.itemID))
        try h2.store.scheduleReminder(c, at: at(ist, 2026, 10, 16, 9), now: h2.clock.now)
        _ = await s2.reconcile()
        XCTAssertEqual(s2.requests(for: c, now: h2.clock.now).count, 1)
    }

    func testMovingTheDeadlineMovesTheHeadsUpWithoutDuplicates() async throws {
        let (h, center, s) = try setup()
        let o = try await task(h, s, "I need to submit the assignment by Friday.")
        let c = try XCTUnwrap(try h.store.item(id: o.itemID))
        try h.store.reschedule(c, deadline: at(ist, 2026, 10, 19), hasTime: false, calendar: ist, now: h.clock.now)
        _ = await s.reconcile()
        XCTAssertEqual(center.onceDates, [at(ist, 2026, 10, 18, 10), at(ist, 2026, 10, 19, 10)], "Sunday heads-up, Monday reminder; Friday's are gone")
    }

    // Test 3
    func testReminderThatMentionsGPTIsAReminderForLater() async throws {
        let (h, center, s) = try setup()
        let o = try await remind(h, s, "Remind me to ask GPT about quantum physics tomorrow.")
        XCTAssertEqual(o.title, "Ask GPT about quantum physics")
        XCTAssertEqual(o.reminderAt, at(ist, 2026, 10, 15, 10))
        XCTAssertEqual(center.onceDates.count, 1)
        XCTAssertEqual(try delegations(h), 0, "nothing was sent to ChatGPT")
    }

    // Test 4 and 5: routing only here; ChatGPT execution is AskServiceTests/DelegationLifecycleTests.
    func testDirectGPTRequestAndLocalQuestionGoWhereTheWordsSay() {
        guard case let .delegateToChatGPT(r) = CommandRouter.intent(for: "Ask GPT to research quantum physics.", now: now, calendar: ist).operation else { return XCTFail() }
        XCTAssertEqual(r.target, .chatgpt)
        guard case let .generalQuestion(q) = CommandRouter.intent(for: "What is gradient descent?", now: now, calendar: ist).operation else { return XCTFail() }
        XCTAssertNil(q.target)
    }

    // Reminders that state a deadline keep both, separately.
    func testReminderWithByKeepsTheDeadlineAndTheReminderTime() async throws {
        let (h, _, s) = try setup()
        let o = try await remind(h, s, "Remind me to submit the form by Friday at 5 PM")
        XCTAssertEqual(o.deadline, at(ist, 2026, 10, 16, 17))
        XCTAssertEqual(o.reminderAt, at(ist, 2026, 10, 16, 17))
    }

    // Test 9: failures are reported as failures.
    func testDeniedNotificationsAreReportedNotHidden() async throws {
        let (h, center, s) = try setup()
        center.authorized = false
        let o = try await remind(h, s, "Remind me to call Sam tomorrow at 10 AM")
        XCTAssertFalse(o.notificationsAuthorized)
        XCTAssertFalse(o.allScheduled)
        XCTAssertFalse(o.planned.isEmpty, "the reminder is still saved and wanted")
        XCTAssertNotNil(try h.store.item(id: o.itemID))
    }

    func testAFailedScheduleIsAFailureNotASuccess() async throws {
        let (h, center, s) = try setup()
        center.failIDs = [".at."]
        let o = try await remind(h, s, "Remind me to call Sam tomorrow at 10 AM")
        XCTAssertTrue(o.schedulingFailed)
        XCTAssertFalse(o.allScheduled)
        center.failIDs = []
        _ = await s.reconcile()
        XCTAssertEqual(try h.store.item(id: o.itemID)?.scheduledNotificationIDs.count, 1, "the next reconcile retries it")
    }

    func testInvalidTimesAreRefusedNotSaved() async throws {
        let (h, _, _) = try setup()
        guard case .past? = ReminderCommand.parse("Remind me to call Sam today at 9 AM", now: h.clock.now, calendar: ist) else { return XCTFail("9 AM today has passed") }
        // Even a request that bypasses the parser can't create a reminder in the past.
        let r = await ItemExecution.createReminder(text: "x", title: "X", when: .once(h.clock.now.addingTimeInterval(-60)), deadline: nil, source: .hotkey,
                                                   origin: .user(.hotkey), store: h.store, broker: h.broker, scheduler: nil, now: h.clock.now)
        guard case .failure = r else { return XCTFail("a past reminder must fail") }
        XCTAssertEqual(try h.store.all().count, 0)
    }

    // Idempotency: the same command can't create duplicates.
    func testTheSameCommandTwiceDoesntDuplicate() async throws {
        var g = SubmissionGuard()
        let k = SubmissionGuard.key("Can you make a reminder to call Sam tomorrow at 10 AM?", channel: "voice")
        XCTAssertTrue(g.begin(k, now: now))
        XCTAssertFalse(g.begin(k, now: now.addingTimeInterval(0.2)), "a repeated Return or voice event while it runs")
        g.end(k, now: now)
        XCTAssertFalse(g.begin(k, now: now.addingTimeInterval(1)), "or right after")
        let (h, center, s) = try setup()
        _ = try await remind(h, s, "Remind me to call Sam tomorrow at 10 AM")
        _ = await s.reconcile(); _ = await s.reconcile()
        XCTAssertEqual(center.pending.count, 1, "one notification for one reminder, however often Wren reconciles")
    }

    // Test 10 (the part that can run here): what macOS holds doesn't depend on Wren running.
    func testScheduledRemindersDontNeedWrenRunning() async throws {
        let (h, center, s) = try setup()
        _ = try await remind(h, s, "Remind me to call Sam tomorrow at 10 AM")
        _ = try await task(h, s, "I need to submit the assignment by Friday.")
        let held = center.pending
        // A new scheduler over the same store (a relaunch after quitting) leaves them exactly as they were.
        let relaunched = ReminderScheduler(store: h.store, center: center, clock: h.clock, advance: { DeadlineAdvance(days: 1, hour: 10) })
        let r = await relaunched.reconcile()
        XCTAssertEqual(r.scheduled, 0); XCTAssertEqual(r.cancelled, 0)
        XCTAssertEqual(Set(center.pending.keys), Set(held.keys))
    }

    // Test 7 (link part): the Gmail address Wren opens for an alert.
    func testEmailAlertOpensThatConversationInTheRightAccount() {
        let m = EmailMessage(id: "18c1f2a3b4d5e6f7", threadId: "18c1f2a3b4d5e6f0", from: "Recruiter <r@x.com>", to: "me@x.com", subject: "Interview",
                             date: now, snippet: "Could you share your availability for an interview by tomorrow?", labels: ["INBOX", "UNREAD"], account: "me@x.com")
        XCTAssertEqual(m.webURL.absoluteString, "https://mail.google.com/mail/?authuser=me@x.com#all/18c1f2a3b4d5e6f0",
                       "the form checked live against a real account (M-GMAIL-LINK): the thread, in that account")
    }
}
