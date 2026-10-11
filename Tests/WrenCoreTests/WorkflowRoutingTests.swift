import XCTest
@testable import WrenCore

/// The phrasings from the product brief, end to end through the deterministic router. Each one must
/// land on the intended workflow (delegate to GPT, task/reminder, stored-data question, note) and
/// carry the user's complete request.
final class WorkflowRoutingTests: XCTestCase {
    let ist = calendar("Asia/Kolkata")
    var now: Date { at(ist, 2026, 10, 11, 14) }
    func route(_ s: String) -> Intent { IntentRouter.route(s, now: now, calendar: ist) }
    func gpt(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard case let .askAI(r) = route(s) else { XCTFail("\(s) → \(route(s))", file: file, line: line); return nil }
        XCTAssertEqual(r.target, .chatgpt, file: file, line: line)
        return r.prompt
    }

    // MARK: GPT delegation

    func testBriefExampleKeepsTheWholeQuery() {
        XCTAssertEqual(gpt("Hey Wren, search in GPT: explain quantum physics and give me a few useful beginner resources."),
                       "Explain quantum physics and give me a few useful beginner resources.")
    }

    func testDelegationVariations() {
        XCTAssertEqual(gpt("Hey Wren, ask GPT what quantum physics is."), "What is quantum physics?")
        XCTAssertEqual(gpt("Search in GPT for the best explanations of transformers."), "The best explanations of transformers.")
        XCTAssertEqual(gpt("Ask ChatGPT to research this topic."), "Research this topic.")
        XCTAssertEqual(gpt("Get GPT to compare these two approaches."), "Compare these two approaches.")
        XCTAssertEqual(gpt("Tell GPT to investigate this and let me know when it is finished."), "Investigate this.")
        XCTAssertEqual(gpt("Ask GPT to brainstorm names for my project."), "Brainstorm names for my project.")
        XCTAssertEqual(gpt("ask chatgpt to research rust async runtimes and tell me when it's done"), "Research rust async runtimes.")
        XCTAssertEqual(gpt("Have ChatGPT draft three subject lines for the launch email, let me know when done"),
                       "Draft three subject lines for the launch email.")
    }

    func testDelegationIsNotATaskOrNoteOrStoredQuery() {
        // Mentions "waiting" and a date, but it's addressed to GPT.
        XCTAssertNotNil(gpt("Ask GPT what I should do while waiting for the visa on Friday"))
        // A reminder that mentions GPT is still a reminder.
        XCTAssertEqual(route("Remind me to ask GPT about pricing tomorrow at 10 AM"), .reminder)
        // A note that mentions GPT is still a note.
        XCTAssertEqual(route("Note: GPT pricing changed today"), .explicitCapture("GPT pricing changed today"))
        // Talking about GPT isn't asking it.
        XCTAssertEqual(route("email the GPT team about the invoice"), .capture)
        XCTAssertEqual(route("I compared GPT and Claude yesterday"), .capture)
    }

    func testAPendingReminderQuestionDoesNotSwallowANewRequest() {
        XCTAssertFalse(ReminderFollowUp.mayAnswer("Ask GPT what to prepare for Friday's launch"))
        XCTAssertFalse(ReminderFollowUp.mayAnswer("Hey Wren, note: Friday is a holiday"))
        XCTAssertTrue(ReminderFollowUp.mayAnswer("Friday at 5 PM"))
    }

    func testEmptyDelegationIsNotSent() {
        // Nothing to send: not routed as a delegation.
        if case .askAI = route("ask GPT") { XCTFail("an empty request must not be delegated") }
        if case .askAI = route("Hey Wren, ask ChatGPT.") { XCTFail("an empty request must not be delegated") }
    }

    // MARK: Tasks and reminders

    func testTaskAndReminderPhrasings() {
        XCTAssertEqual(route("Remind me to call Sam tomorrow at 10 AM."), .reminder)
        XCTAssertEqual(route("Remind me every weekday at 3 PM to take a break."), .reminder)
        XCTAssertEqual(route("Move the research task to Sunday."), .itemCommand)
        XCTAssertEqual(route("Snooze this reminder for 30 minutes."), .itemCommand)
        // Deadlines stated as tasks are captured (and then read as dated commitments).
        XCTAssertEqual(route("I need to finish this report by Friday."), .capture)
        XCTAssertEqual(route("Create a task for the recruiter follow-up next Monday."), .capture)
    }

    func testTaskTitlesDropTheFraming() {
        let p = IntentProcessor(client: nil, model: nil, calendar: ist)
        let a = p.rulesOnly("I need to finish this report by Friday.", now: now)
        XCTAssertEqual(a.kind, .commitment)
        XCTAssertEqual(a.title, "Finish this report")
        XCTAssertNotNil(a.deadline)
        let b = p.rulesOnly("Create a task for the recruiter follow-up next Monday.", now: now)
        XCTAssertEqual(b.kind, .commitment)
        XCTAssertEqual(b.title, "Recruiter follow-up")
        XCTAssertEqual(ist.component(.weekday, from: b.deadline!), 2)
    }

    // MARK: Questions about Wren's own data

    func testStoredQuestionsStayLocal() {
        XCTAssertEqual(route("What am I waiting on?"), .storedQuery(.waiting))
        XCTAssertEqual(route("What's overdue?"), .storedQuery(.overdue))
    }
}

/// "I need to finish this report by Friday" end to end (minus the macOS center, which is faked here and
/// verified live in docs/MANUAL_TESTS.md M-REM-*): saved, read as a dated task, a reminder computed,
/// scheduled with the notification center, and withdrawn when the task is completed.
@MainActor
final class TaskToReminderPipelineTests: XCTestCase {
    func testStatedDeadlineBecomesAScheduledReminderAndCompletionCancelsIt() async throws {
        let ist = calendar("Asia/Kolkata")
        let now = at(ist, 2026, 10, 11, 14)   // Sunday
        let h = try Harness(now: now, calendar: ist)
        let center = FakeReminderCenter()
        let scheduler = ReminderScheduler(store: h.store, center: center, clock: h.clock)
        let text = "I need to finish this report by Friday."
        let c = try h.store.capture(text, source: .hotkey, now: now)
        let rules = IntentProcessor(client: nil, model: nil, calendar: ist).rulesOnly(text, now: now)
        let r = await h.broker.submit(ActionRequest(action: BuiltInAction.applyInterpretation, target: c.targetRef,
                                                    parameters: rules.parameters(model: nil, state: .awaiting, dateOnlyReminderHour: 10),
                                                    origin: .system("date rules"), createdAt: now))
        XCTAssertEqual(r.status, .succeeded)
        XCTAssertEqual(c.kind, .commitment)
        XCTAssertEqual(c.title, "Finish this report")
        XCTAssertEqual(c.originalText, text, "the original wording is kept")
        XCTAssertEqual(c.deadline.map { ist.component(.weekday, from: $0) }, 6, "Friday")
        XCTAssertEqual(c.nextReminderAt, at(ist, 2026, 10, 16, 10), "date-only deadline: reminder at the default hour")
        _ = await scheduler.reconcile()
        XCTAssertEqual(center.onceDates, [at(ist, 2026, 10, 16, 10)])
        XCTAssertEqual(c.scheduledNotificationIDs.count, 1, "the task, its schedule and the notification ID are linked")
        // Reconciling again (a relaunch) schedules nothing twice.
        let calls = center.scheduledCalls
        _ = await scheduler.reconcile()
        XCTAssertEqual(center.scheduledCalls, calls)
        _ = await h.broker.submit(h.request(BuiltInAction.complete, c))
        _ = await scheduler.reconcile()
        XCTAssertTrue(center.pending.isEmpty, "completing the task withdraws the scheduled notification")
    }
}
