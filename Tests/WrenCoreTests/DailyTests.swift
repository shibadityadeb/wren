import XCTest
@testable import WrenCore

@MainActor
final class BriefingContentTests: XCTestCase {
    let cal = calendar("Asia/Kolkata")
    var now: Date { at(cal, 2026, 10, 8, 11) } // Thursday 11:00

    func testEmpty() throws {
        let h = try Harness(now: now, calendar: cal)
        _ = try h.add("Someday idea", kind: .idea)
        _ = try h.add("Undated thing")
        let b = Briefing.build(from: try h.store.all(), now: now, calendar: cal)
        XCTAssertTrue(b.isEmpty)
    }

    func testSectionsAndOrdering() throws {
        let h = try Harness(now: now, calendar: cal)
        _ = try h.add("Overdue low", deadline: at(cal, 2026, 10, 6), priority: .low)
        _ = try h.add("Overdue high", deadline: at(cal, 2026, 10, 7), priority: .high)
        _ = try h.add("Overdue this morning", deadline: at(cal, 2026, 10, 8, 9), hasTime: true)
        _ = try h.add("Due today", deadline: at(cal, 2026, 10, 8))
        _ = try h.add("Due tonight", deadline: at(cal, 2026, 10, 8, 20), hasTime: true)
        _ = try h.add("Friday", deadline: at(cal, 2026, 10, 9))
        _ = try h.add("Sunday", deadline: at(cal, 2026, 10, 11))
        _ = try h.add("Next month", deadline: at(cal, 2026, 11, 20))
        _ = try h.add("Recruiter reply", kind: .waiting, created: at(cal, 2026, 10, 1))
        _ = try h.add("Fresh waiting", kind: .waiting, created: at(cal, 2026, 10, 8, 8))
        _ = try h.add("Idea", kind: .idea, deadline: at(cal, 2026, 10, 6))
        let done = try h.add("Done already", deadline: at(cal, 2026, 10, 7)); try h.store.complete(done, now: now)
        let r = try h.add("Undated with reminder"); try h.store.scheduleReminder(r, at: at(cal, 2026, 10, 8, 15), now: now)

        let b = Briefing.build(from: try h.store.all(), now: now, calendar: cal)
        // Priority first, then earliest deadline.
        XCTAssertEqual(b.overdue.map(\.title), ["Overdue high", "Overdue this morning", "Overdue low"])
        XCTAssertEqual(Set(b.dueToday.map(\.title)), ["Due today", "Due tonight"])
        XCTAssertEqual(b.upcoming.map(\.title), ["Friday", "Sunday"])
        XCTAssertEqual(b.waiting.map(\.title), ["Recruiter reply"])
        XCTAssertEqual(b.remindersToday.map(\.title), ["Undated with reminder"])
        XCTAssertEqual(b.focus.count, 3, "notification names a few things, not everything")
        XCTAssertTrue(b.notificationBody.hasPrefix("3 overdue, 2 due today, 2 coming up, 1 waiting on others."))
        XCTAssertTrue(b.notificationBody.contains("Start with “Overdue high”"))
        XCTAssertLessThan(b.notificationBody.count, 160)
    }

    func testLimitsKeepNotificationShort() throws {
        let h = try Harness(now: now, calendar: cal)
        for i in 0..<40 { _ = try h.add("Overdue \(i)", deadline: at(cal, 2026, 10, 1)) }
        let b = Briefing.build(from: try h.store.all(), now: now, calendar: cal)
        XCTAssertEqual(b.overdue.count, 5)
        XCTAssertTrue(b.notificationBody.contains("5 overdue"))
    }

    func testCheckInContent() throws {
        let h = try Harness(now: at(cal, 2026, 10, 8, 19), calendar: cal)
        let a = try h.add("Finished today", deadline: at(cal, 2026, 10, 8)); try h.store.complete(a, now: at(cal, 2026, 10, 8, 14))
        let y = try h.add("Finished yesterday"); try h.store.complete(y, now: at(cal, 2026, 10, 7, 14))
        _ = try h.add("Still open", deadline: at(cal, 2026, 10, 8))
        _ = try h.add("Due Saturday", deadline: at(cal, 2026, 10, 10))
        _ = try h.add("Waiting on Sam", kind: .waiting)
        let d = try h.add("Put off"); try h.store.snooze(d, until: at(cal, 2026, 10, 9, 9), now: at(cal, 2026, 10, 8, 12))

        let c = CheckIn.build(from: try h.store.all(), now: h.clock.now, calendar: cal)
        XCTAssertEqual(c.completedToday.map(\.title), ["Finished today"])
        XCTAssertEqual(c.open.map(\.title), ["Still open"])
        XCTAssertEqual(c.dueSoon.map(\.title), ["Due Saturday"])
        XCTAssertEqual(c.waiting.map(\.title), ["Waiting on Sam"])
        XCTAssertEqual(c.deferredToday.map(\.title), ["Put off"])
        XCTAssertEqual(c.title, "Did you finish “Still open”?")
        XCTAssertEqual(c.singleItem?.title, "Still open")
    }
}

@MainActor
final class DailyEngineTests: XCTestCase {
    let cal = calendar("Asia/Kolkata")

    func settings(_ f: (inout DailySettings) -> Void = { _ in }) -> DailySettings { var s = DailySettings(); f(&s); return s }

    func testBriefingOnceAndNoDuplicateAfterRestart() async throws {
        let url = tempStoreURL()
        do {
            let h = try Harness(url: url, now: at(cal, 2026, 10, 8, 10, 59), calendar: cal)
            _ = try h.add("Overdue", deadline: at(cal, 2026, 10, 7))
            var r = await h.engine.tick()
            XCTAssertEqual(r.briefing, .pending)
            XCTAssertTrue(h.notifier.briefings.isEmpty)
            h.clock.set(at(cal, 2026, 10, 8, 11, 0))
            r = await h.engine.tick()
            XCTAssertEqual(r.briefing, .sent)
            h.clock.advance(60)
            _ = await h.engine.tick()
            XCTAssertEqual(h.notifier.briefings.count, 1)
        }
        // Restart: new process state, same database.
        let h2 = try Harness(url: url, now: at(cal, 2026, 10, 8, 11, 5), calendar: cal)
        let r2 = await h2.engine.tick()
        XCTAssertEqual(r2.briefing, .sent)
        XCTAssertTrue(h2.notifier.briefings.isEmpty, "no duplicate after restart")
    }

    func testMissedBriefingRecoveryIsPredictable() async throws {
        // Started at 14:00: briefing window (11:00–19:00) still open → sent once, late.
        let h = try Harness(now: at(cal, 2026, 10, 8, 14), calendar: cal)
        _ = try h.add("Due today", deadline: at(cal, 2026, 10, 8))
        do { let r1 = await h.engine.tick(); XCTAssertEqual(r1.briefing, .sent) }

        // Started at 20:30: briefing window closed → missed (not sent); check-in window open → sent.
        let late = try Harness(now: at(cal, 2026, 10, 8, 20, 30), calendar: cal)
        _ = try late.add("Due today", deadline: at(cal, 2026, 10, 8))
        let r = await late.engine.tick()
        XCTAssertEqual(r.briefing, .missed)
        XCTAssertEqual(r.checkIn, .sent)
        XCTAssertTrue(late.notifier.briefings.isEmpty)

        // Started at 23:30: both missed, nothing sent at night.
        let night = try Harness(now: at(cal, 2026, 10, 8, 23, 30), calendar: cal)
        _ = try night.add("Due today", deadline: at(cal, 2026, 10, 8))
        let n = await night.engine.tick()
        XCTAssertEqual(n.briefing, .missed)
        XCTAssertEqual(n.checkIn, .missed)
        XCTAssertTrue(night.notifier.briefings.isEmpty && night.notifier.checkIns.isEmpty)

        // Next morning before 11: yesterday is never sent late; today is pending.
        night.clock.set(at(cal, 2026, 10, 9, 8))
        let next = await night.engine.tick()
        XCTAssertEqual(next.briefing, .pending)
        XCTAssertTrue(night.notifier.briefings.isEmpty)
    }

    func testEmptyBriefingSkippedUnlessEnabled() async throws {
        let h = try Harness(now: at(cal, 2026, 10, 8, 11), calendar: cal)
        do { let r2 = await h.engine.tick(); XCTAssertEqual(r2.briefing, .skippedEmpty) }
        XCTAssertTrue(h.notifier.briefings.isEmpty)

        let h2 = try Harness(now: at(cal, 2026, 10, 8, 11), calendar: cal, daily: settings { $0.sendEmptySummaries = true })
        do { let r3 = await h2.engine.tick(); XCTAssertEqual(r3.briefing, .sent) }
        XCTAssertEqual(h2.notifier.briefings.first?.notificationBody, "Nothing due today. Enjoy the space.")
    }

    func testDisabledAndCustomTimes() async throws {
        let h = try Harness(now: at(cal, 2026, 10, 8, 11), calendar: cal, daily: settings { $0.briefingEnabled = false; $0.checkInMinutes = 17 * 60 + 30 })
        _ = try h.add("Due today", deadline: at(cal, 2026, 10, 8))
        do { let r4 = await h.engine.tick(); XCTAssertEqual(r4.briefing, .disabled) }
        h.clock.set(at(cal, 2026, 10, 8, 17, 29))
        do { let r5 = await h.engine.tick(); XCTAssertEqual(r5.checkIn, .pending) }
        h.clock.set(at(cal, 2026, 10, 8, 17, 30))
        do { let r6 = await h.engine.tick(); XCTAssertEqual(r6.checkIn, .sent) }
        XCTAssertTrue(h.notifier.briefings.isEmpty)
    }

    func testCheckInDedupAndCompletion() async throws {
        let url = tempStoreURL()
        let h = try Harness(url: url, now: at(cal, 2026, 10, 8, 19), calendar: cal)
        _ = try h.add("Open", deadline: at(cal, 2026, 10, 8))
        do { let r7 = await h.engine.tick(); XCTAssertEqual(r7.checkIn, .sent) }
        h.engine.closeCheckIn(.completed)
        h.clock.advance(3600)
        _ = await h.engine.tick()
        XCTAssertEqual(h.notifier.checkIns.count, 1)
        let h2 = try Harness(url: url, now: at(cal, 2026, 10, 8, 21), calendar: cal)
        do { let r8 = await h2.engine.tick(); XCTAssertEqual(r8.checkIn, .completed) }
        XCTAssertTrue(h2.notifier.checkIns.isEmpty)
    }

    func testCheckInNeverChangesItems() async throws {
        let h = try Harness(now: at(cal, 2026, 10, 8, 19), calendar: cal)
        let c = try h.add("Open", deadline: at(cal, 2026, 10, 8), priority: .high)
        _ = await h.engine.tick()
        XCTAssertEqual(c.status, .pending)
        XCTAssertEqual(c.deadline, at(cal, 2026, 10, 8))
        XCTAssertEqual(c.priority, .high)
    }

    func testNotificationsUnavailable() async throws {
        let n = FakeNotifier(); n.allowed = false
        let h = try Harness(now: at(cal, 2026, 10, 8, 11), calendar: cal, notifier: n)
        let c = try h.add("Due", deadline: at(cal, 2026, 10, 8))
        try h.store.scheduleReminder(c, at: at(cal, 2026, 10, 8, 10), now: h.clock.now)
        let r = await h.engine.tick()
        XCTAssertEqual(r.briefing, .undelivered, "recorded so it isn't retried every minute; still viewable in the menu")
        XCTAssertEqual(r.remindersUndelivered, 1)
        XCTAssertNil(c.lastReminderAt, "an undelivered reminder is never recorded as sent")
        XCTAssertTrue(ReminderPolicy.isDue(c, now: h.clock.now))
    }

    func testRemindersFlowThroughBrokerAndAudit() async throws {
        let h = try Harness(now: at(cal, 2026, 10, 8, 9), calendar: cal)
        let c = try h.add("Stretch")
        try h.store.scheduleReminder(c, at: at(cal, 2026, 10, 8, 9, 1), now: h.clock.now)
        _ = await h.engine.tick()
        XCTAssertTrue(h.notifier.reminders.isEmpty)
        h.clock.set(at(cal, 2026, 10, 8, 9, 1))
        let r = await h.engine.tick()
        XCTAssertEqual(r.remindersDelivered, 1)
        XCTAssertEqual(h.notifier.reminders.map(\.title), ["Stretch"])
        let a = try XCTUnwrap(h.audit().first { $0.action == "reminder.deliver" })
        XCTAssertEqual(a.status, .succeeded)
        XCTAssertTrue(a.authorization?.contains("Automatically remind me") == true)
        h.clock.advance(60)
        _ = await h.engine.tick()
        XCTAssertEqual(h.notifier.reminders.count, 1)
    }

    // Continued operation with Ollama unavailable: the engine has no model dependency,
    // and capture → rules interpretation → reminder → delivery works end to end.
    func testWholePipelineWithoutModel() async throws {
        let h = try Harness(now: at(cal, 2026, 10, 8, 9), calendar: cal)
        let c = try h.store.capture("Call my friend at 9:05am", source: .hotkey, now: h.clock.now)
        let processor = IntentProcessor(client: try OllamaClient(baseURL: URL(string: "http://127.0.0.1:9")!), model: "missing", calendar: cal)
        guard case .unavailable = await processor.interpret(c.originalText, now: h.clock.now) else { return XCTFail("expected unavailable") }
        let rules = processor.rulesOnly(c.originalText, now: h.clock.now)
        let apply = await h.broker.submit(ActionRequest(action: BuiltInAction.applyInterpretation, target: c.targetRef,
                                                        parameters: rules.parameters(model: nil, state: .awaiting, dateOnlyReminderHour: 10),
                                                        origin: .system("rules"), createdAt: h.clock.now))
        XCTAssertEqual(apply.status, .succeeded)
        XCTAssertEqual(c.nextReminderAt, at(cal, 2026, 10, 8, 9, 5))
        h.clock.set(at(cal, 2026, 10, 8, 9, 5))
        do { let r9 = await h.engine.tick(); XCTAssertEqual(r9.remindersDelivered, 1) }
    }
}

/// Daylight-saving transitions in America/Los_Angeles, 2026: spring forward Sun 8 Mar, fall back Sun 1 Nov.
@MainActor
final class DSTTests: XCTestCase {
    let la = calendar("America/Los_Angeles")

    func testDailyTimesOnTransitionDays() {
        for (y, m, d) in [(2026, 3, 8), (2026, 11, 1)] {
            let day = at(la, y, m, d, 12)
            let w = DailySchedule.window(.briefing, on: day, settings: DailySettings(), calendar: la)
            let comps = la.dateComponents([.hour, .minute], from: w.lowerBound)
            XCTAssertEqual(comps.hour, 11); XCTAssertEqual(comps.minute, 0)
            XCTAssertEqual(la.dateComponents([.hour], from: w.upperBound).hour, 19)
            XCTAssertEqual(la.dayKey(for: w.lowerBound), String(format: "%04d-%02d-%02d", y, m, d))
        }
    }

    func testNonexistentTimeUsesNextValid() {
        // 02:30 doesn't exist on spring-forward day.
        let t = la.time(minutesAfterMidnight: 150, on: at(la, 2026, 3, 8, 12))
        XCTAssertEqual(la.dateComponents([.hour, .minute], from: t).hour, 3)
        XCTAssertEqual(la.dayKey(for: t), "2026-03-08")
    }

    func testOncePerDayAcrossFallBack() async throws {
        let h = try Harness(now: at(la, 2026, 10, 31, 11), calendar: la, daily: { var s = DailySettings(); s.sendEmptySummaries = true; return s }())
        _ = await h.engine.tick()
        // 25-hour day: step through it hourly.
        var t = at(la, 2026, 10, 31, 12)
        while t < at(la, 2026, 11, 2, 12) {
            h.clock.set(t); _ = await h.engine.tick()
            t = t.addingTimeInterval(3600)
        }
        XCTAssertEqual(h.notifier.briefings.map(\.day), ["2026-10-31", "2026-11-01", "2026-11-02"])
        XCTAssertEqual(h.notifier.checkIns.map(\.day), ["2026-10-31", "2026-11-01"])
    }

    func testOncePerDayAcrossSpringForward() async throws {
        let h = try Harness(now: at(la, 2026, 3, 7, 11), calendar: la, daily: { var s = DailySettings(); s.sendEmptySummaries = true; return s }())
        var t = at(la, 2026, 3, 7, 11)
        while t < at(la, 2026, 3, 9, 12) {
            h.clock.set(t); _ = await h.engine.tick()
            t = t.addingTimeInterval(1800)
        }
        XCTAssertEqual(h.notifier.briefings.map(\.day), ["2026-03-07", "2026-03-08", "2026-03-09"])
    }

    func testNextWakeHitsBriefingTime() throws {
        let s = DailySettings()
        let now = at(la, 2026, 3, 8, 1)
        XCTAssertEqual(DailySchedule.nextBoundary(after: now, settings: s, calendar: la), at(la, 2026, 3, 8, 11))
    }
}
