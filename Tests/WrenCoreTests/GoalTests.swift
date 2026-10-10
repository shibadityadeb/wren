import XCTest
@testable import WrenCore

@MainActor
final class GoalTests: XCTestCase {
    let cal = calendar("Asia/Kolkata")
    var now: Date { at(cal, 2026, 10, 8, 12) }

    func goalReq(_ h: Harness, _ a: ActionID, _ g: Goal, _ p: [String: JSONValue] = [:]) -> ActionRequest {
        ActionRequest(action: a, target: g.targetRef, parameters: p, origin: .user(.popover), createdAt: h.clock.now)
    }

    func testCreateEditStatusAndPersistence() async throws {
        let url = tempStoreURL()
        var goalID: UUID
        do {
            let h = try Harness(url: url, now: now, calendar: cal)
            let text = "I want to publish a technical article about multi-agent reasoning before the end of the month."
            let r = await h.broker.submit(ActionRequest(action: BuiltInAction.createGoal, target: TargetRef(kind: "goal", id: "new", label: "Publish article"),
                                                        parameters: ["title": .string("Publish multi-agent reasoning article"), "originalText": .string(text),
                                                                     "targetDate": .number(at(cal, 2026, 10, 31).timeIntervalSince1970)],
                                                        origin: .user(.popover), createdAt: h.clock.now))
            XCTAssertEqual(r.status, .succeeded)
            let g = try XCTUnwrap(try h.store.goals().first)
            goalID = g.id
            XCTAssertEqual(g.originalText, text)
            XCTAssertEqual(g.method, .manual, "never assumes task counting")

            h.clock.advance(60)
            for s in ["paused", "active", "completed", "active"] {
                let rr = await h.broker.submit(goalReq(h, BuiltInAction.setGoalStatus, g, ["status": .string(s)]))
                XCTAssertEqual(rr.status, .succeeded, s)
            }
            let bad = await h.broker.submit(goalReq(h, BuiltInAction.setGoalStatus, g, ["status": .string("bogus")]))
            XCTAssertEqual(bad.status, .failed)

            let edit = await h.broker.submit(goalReq(h, BuiltInAction.editGoal, g, ["title": .string("Publish the article"),
                                                                                      "targetDate": .number(at(cal, 2026, 11, 7).timeIntervalSince1970)]))
            XCTAssertEqual(edit.status, .succeeded)
            XCTAssertTrue(g.events.contains { $0.kind == .targetDateChanged }, "target date changes are never silent")
        }
        let h2 = try Harness(url: url, now: now, calendar: cal)
        let g = try XCTUnwrap(try h2.store.goal(id: goalID))
        XCTAssertEqual(g.title, "Publish the article")
        XCTAssertEqual(g.targetDate, at(cal, 2026, 11, 7))
        XCTAssertEqual(g.status, .active)
        XCTAssertGreaterThanOrEqual(g.events.count, 6)
    }

    func testArchivedGoalCanOnlyResume() throws {
        let h = try Harness(now: now, calendar: cal)
        let g = try h.store.createGoal(title: "G", targetDate: nil, now: now)
        try h.store.setGoalStatus(g, .archived, now: now)
        XCTAssertThrowsError(try h.store.setGoalStatus(g, .paused, now: now))
        XCTAssertNoThrow(try h.store.setGoalStatus(g, .active, now: now))
    }

    func testProgressMethodsAreExplicitAndExplained() async throws {
        let h = try Harness(now: now, calendar: cal)
        let g = try h.store.createGoal(title: "Article", targetDate: nil, now: now)
        let a = try h.add("Outline"), b = try h.add("Draft"), c = try h.add("Edit"), d = try h.add("Abandoned approach")
        for (t, ms) in [(a, true), (b, true), (c, false), (d, false)] {
            let r = await h.broker.submit(h.request(BuiltInAction.linkToGoal, t, params: ["goalID": .string(g.id.uuidString), "milestone": .bool(ms)]))
            XCTAssertEqual(r.status, .succeeded)
        }
        XCTAssertEqual(g.tasks.count, 4)
        try h.store.complete(a, now: now)
        try h.store.drop(d, now: now)

        // Manual (default): linked tasks don't move it.
        XCTAssertEqual(GoalProgressReport.of(g).fraction, 0)
        XCTAssertTrue(GoalProgressReport.of(g).explanation.contains("Set by you"))
        let setP = await h.broker.submit(ActionRequest(action: BuiltInAction.setGoalProgress, target: g.targetRef, parameters: ["value": .number(0.4)],
                                                       origin: .user(.popover), createdAt: now))
        XCTAssertEqual(setP.status, .succeeded)
        XCTAssertEqual(GoalProgressReport.of(g).percentText, "40%")

        try h.store.setProgressMethod(g, .linkedTasks, now: now)
        let r = GoalProgressReport.of(g)
        XCTAssertEqual(r.fraction!, 1.0 / 3.0, accuracy: 0.001)
        XCTAssertTrue(r.explanation.contains("1 of 3 linked tasks done"))
        XCTAssertTrue(r.explanation.contains("1 dropped or archived not counted"))
        XCTAssertTrue(r.explanation.contains("counts equally"))

        try h.store.setProgressMethod(g, .milestones, now: now)
        XCTAssertEqual(GoalProgressReport.of(g).fraction, 0.5)
        XCTAssertTrue(GoalProgressReport.of(g).explanation.contains("1 of 2 milestones done"))

        // Completing a linked task records goal progress.
        XCTAssertTrue(g.events.contains { $0.kind == .progressChanged && $0.note?.contains("Outline") == true })
        XCTAssertNotNil(g.lastProgressAt)

        // Unlink keeps both histories.
        _ = await h.broker.submit(h.request(BuiltInAction.unlinkFromGoal, c))
        XCTAssertNil(c.goal)
        XCTAssertTrue(c.events.contains { $0.kind == .unlinkedFromGoal })
        XCTAssertTrue(g.events.contains { $0.kind == .taskUnlinked })
    }

    func testEmptyLinkedProgressIsNotZeroPercent() throws {
        let h = try Harness(now: now, calendar: cal)
        let g = try h.store.createGoal(title: "G", targetDate: nil, method: .linkedTasks, now: now)
        XCTAssertNil(GoalProgressReport.of(g).fraction)
        XCTAssertEqual(GoalProgressReport.of(g).percentText, "—")
    }

    func testConvertItemToGoalKeepsHistory() async throws {
        let h = try Harness(now: now, calendar: cal)
        let c = try h.add("Learn Rust", deadline: at(cal, 2026, 12, 1))
        try h.store.snooze(c, until: at(cal, 2026, 10, 9), now: now)
        let r = await h.broker.submit(h.request(BuiltInAction.convertToGoal, c))
        XCTAssertEqual(r.status, .succeeded)
        let g = try XCTUnwrap(c.goal)
        XCTAssertEqual(g.targetDate, at(cal, 2026, 12, 1))
        XCTAssertEqual(c.status, .archived)
        XCTAssertNotNil(try h.store.item(id: c.id), "archived, not deleted")
        XCTAssertTrue(c.events.contains { $0.kind == .snoozed })
        XCTAssertTrue(c.events.contains { $0.kind == .convertedToGoal })
    }

    func testAddMilestone() async throws {
        let h = try Harness(now: now, calendar: cal)
        let g = try h.store.createGoal(title: "G", targetDate: nil, method: .milestones, now: now)
        let r = await h.broker.submit(ActionRequest(action: BuiltInAction.addMilestone, target: g.targetRef, parameters: ["title": .string("First draft")],
                                                    origin: .user(.popover), createdAt: now))
        XCTAssertEqual(r.status, .succeeded)
        XCTAssertEqual(g.milestones.map(\.title), ["First draft"])
        XCTAssertEqual(GoalProgressReport.of(g).fraction, 0)
    }

    func testModelCannotChangeGoals() async throws {
        let h = try Harness(now: now, calendar: cal)
        let g = try h.store.createGoal(title: "G", targetDate: at(cal, 2026, 10, 31), now: now)
        let r = await h.broker.submit(ActionRequest(action: BuiltInAction.editGoal, target: g.targetRef,
                                                    parameters: ["title": .string("G"), "targetDate": .number(at(cal, 2026, 12, 31).timeIntervalSince1970)],
                                                    origin: .model("m"), createdAt: now))
        XCTAssertEqual(r.status, .awaitingConfirmation)
        XCTAssertEqual(g.targetDate, at(cal, 2026, 10, 31))
        let s = await h.broker.submit(ActionRequest(action: BuiltInAction.setGoalStatus, target: g.targetRef, parameters: ["status": .string("archived")],
                                                    origin: .system("scheduler"), createdAt: now))
        XCTAssertEqual(s.status, .denied, "the scheduler never changes goal status")
        XCTAssertEqual(g.status, .active)
    }
}

@MainActor
final class WaitingAndInsightTests: XCTestCase {
    let cal = calendar("Asia/Kolkata")
    var now: Date { at(cal, 2026, 10, 8, 12) }

    func waiting(_ h: Harness, followUp: Date?) async throws -> Commitment {
        let c = try h.add("Recruiter reply", kind: .waiting, created: at(cal, 2026, 10, 1))
        var p: [String: JSONValue] = ["waitingOn": .string("Priya at Acme"), "expected": .string("Interview slot")]
        if let followUp { p["followUpAt"] = .number(followUp.timeIntervalSince1970) }
        let r = await h.broker.submit(h.request(BuiltInAction.updateWaiting, c, params: p))
        XCTAssertEqual(r.status, .succeeded)
        return c
    }

    func testFollowUpBecomesDueThenQuietAfterAcknowledgement() async throws {
        let h = try Harness(now: now, calendar: cal)
        let c = try await waiting(h, followUp: at(cal, 2026, 10, 10))
        XCTAssertEqual(c.waitingOn, "Priya at Acme")
        XCTAssertNotNil(c.waitingSince)
        XCTAssertTrue(c.events.contains { $0.kind == .followUpScheduled })
        XCTAssertTrue(h.engine.openInsights().filter { $0.kind == .followUpDue }.isEmpty, "not due yet")

        h.clock.set(at(cal, 2026, 10, 10, 9))
        let due = h.engine.openInsights().filter { $0.kind == .followUpDue }
        XCTAssertEqual(due.count, 1)
        XCTAssertTrue(due[0].message.contains("Priya at Acme"))

        // Acknowledge without a new date: nothing further.
        let ack = await h.broker.submit(h.request(BuiltInAction.acknowledgeFollowUp, c, params: ["note": .string("Emailed Priya")]))
        XCTAssertEqual(ack.status, .succeeded)
        XCTAssertTrue(h.engine.openInsights().isEmpty)
        h.clock.set(at(cal, 2026, 10, 12, 9))
        XCTAssertTrue(h.engine.openInsights().filter { $0.subjectID == c.id.uuidString && $0.kind == .followUpDue }.isEmpty)

        // A new date the user chose brings it back on that date only.
        _ = await h.broker.submit(h.request(BuiltInAction.acknowledgeFollowUp, c, params: ["next": .number(at(cal, 2026, 10, 15).timeIntervalSince1970)]))
        XCTAssertTrue(h.engine.openInsights().filter { $0.kind == .followUpDue }.isEmpty)
        h.clock.set(at(cal, 2026, 10, 15, 9))
        XCTAssertEqual(h.engine.openInsights().filter { $0.kind == .followUpDue }.count, 1)
        XCTAssertEqual(c.events.filter { $0.kind == .followedUp }.count, 2, "follow-up attempts are recorded")
    }

    func testFollowUpSurfacesOnceInDailySummaries() async throws {
        let h = try Harness(now: at(cal, 2026, 10, 10, 11), calendar: cal)
        _ = try await waiting(h, followUp: at(cal, 2026, 10, 10))
        let r = await h.engine.tick()
        XCTAssertEqual(r.briefing, .sent)
        XCTAssertEqual(h.notifier.briefings.first?.waiting.map(\.title), ["Recruiter reply"])
        // Check-in the same day doesn't repeat it.
        h.clock.set(at(cal, 2026, 10, 10, 19))
        _ = await h.engine.tick()
        XCTAssertTrue(h.notifier.checkIns.first?.decisions.isEmpty ?? true)
        // Next day, unchanged: not repeated in the briefing (still visible in Review).
        h.clock.set(at(cal, 2026, 10, 11, 11))
        _ = await h.engine.tick()
        XCTAssertTrue(h.notifier.briefings.count < 2 || h.notifier.briefings[1].waiting.isEmpty)
        XCTAssertEqual(h.engine.openInsights().filter { $0.kind == .followUpDue }.count, 1)
    }

    func testFollowUpTurnsStaleAfterGrace() async throws {
        let h = try Harness(now: now, calendar: cal)
        let c = try await waiting(h, followUp: at(cal, 2026, 10, 1))
        let i = h.engine.openInsights().filter { $0.subjectID == c.id.uuidString }
        XCTAssertEqual(i.map(\.kind), [.stale])
        XCTAssertTrue(i[0].reason.contains("Follow-up date passed"))
    }

    // Repeated postponement.
    func testPostponementThresholdDismissalAndResurfacing() async throws {
        let h = try Harness(now: now, calendar: cal)
        let c = try h.add("Write the API report", deadline: at(cal, 2026, 10, 9))
        func postpone() async {
            h.clock.advance(60)
            _ = await h.broker.submit(h.request(BuiltInAction.snooze, c, params: ["until": .number(h.clock.now.addingTimeInterval(3600).timeIntervalSince1970)]))
        }
        await postpone(); await postpone()
        XCTAssertTrue(h.engine.openInsights().filter { $0.kind == .postponed }.isEmpty, "below threshold")
        // A deadline moved later also counts.
        _ = await h.broker.submit(h.request(BuiltInAction.reschedule, c, params: ["deadline": .number(at(cal, 2026, 10, 12).timeIntervalSince1970)]))
        let p = try XCTUnwrap(h.engine.openInsights().first { $0.kind == .postponed })
        XCTAssertTrue(p.message.hasPrefix("You've moved this 3 times."))
        for word in ["lazy", "procrastinat", "motivation", "should have", "failed"] {
            XCTAssertFalse(p.message.lowercased().contains(word))
        }

        let d = await h.broker.submit(ActionRequest(action: BuiltInAction.dismissInsight, target: p.targetRef, parameters: p.parameters, origin: .user(.popover), createdAt: h.clock.now))
        XCTAssertEqual(d.status, .succeeded)
        XCTAssertTrue(h.engine.openInsights().filter { $0.kind == .postponed }.isEmpty)
        // Moved again once or twice: same bucket, stays dismissed.
        await postpone(); await postpone()
        XCTAssertTrue(h.engine.openInsights().filter { $0.kind == .postponed }.isEmpty, "no repeated prompts for the same situation")
        await postpone()
        XCTAssertEqual(h.engine.openInsights().filter { $0.kind == .postponed }.first?.message.hasPrefix("You've moved this 6 times."), true)
        XCTAssertEqual(c.deadline, at(cal, 2026, 10, 12), "the insight never changes the deadline")
    }

    func testKeepDateRecordsReviewAndCustomThreshold() async throws {
        var s = InsightSettings(); s.postponeThreshold = 2
        let h = try Harness(now: now, calendar: cal)
        let c = try h.add("Call the bank")
        try h.store.snooze(c, until: now.addingTimeInterval(60), now: now)
        try h.store.snooze(c, until: now.addingTimeInterval(120), now: now)
        let i = try XCTUnwrap(InsightEngine.compute(items: try h.store.all(), goals: [], now: now, calendar: cal, settings: s).first { $0.kind == .postponed })
        let r = await h.broker.submit(ActionRequest(action: BuiltInAction.resolveInsight, target: i.targetRef,
                                                    parameters: i.parameters.merging(["note": .string("kept the date")]) { $1 }, origin: .user(.popover), createdAt: now))
        XCTAssertEqual(r.status, .succeeded)
        XCTAssertTrue(c.events.contains { $0.kind == .postponementReviewed })
        XCTAssertTrue(h.store.isClosed(i))
    }

    func testInsightForgeryRejected() async throws {
        let h = try Harness(now: now, calendar: cal)
        let c = try h.add("x")
        let fake = Insight(kind: .postponed, subject: .commitment, subjectID: c.id.uuidString, title: "x", message: "", reason: "", fingerprint: "b1")
        var p = fake.parameters; p["fingerprint"] = .string("b9")
        let r = await h.broker.submit(ActionRequest(action: BuiltInAction.dismissInsight, target: fake.targetRef, parameters: p, origin: .user(.popover), createdAt: now))
        XCTAssertEqual(r.status, .failed, "parameters must match the target key")
    }

    // Stale detection and exclusions.
    func testStaleCriteriaAndExclusions() throws {
        let h = try Harness(now: now, calendar: cal)
        let old = at(cal, 2026, 9, 1)
        let quiet = try h.add("Quiet task", created: old)
        _ = try h.add("Old but due later", deadline: at(cal, 2026, 12, 1), created: old)
        let snoozed = try h.add("Old but reminder ahead", created: old); snoozed.nextReminderAt = at(cal, 2026, 10, 20)
        _ = try h.add("Old and overdue", deadline: at(cal, 2026, 9, 10), created: old)
        _ = try h.add("Recent task", created: at(cal, 2026, 10, 1))
        let idea = try h.add("Old idea", kind: .idea, created: old)
        _ = try h.add("Young idea", kind: .idea, created: at(cal, 2026, 9, 20))
        let done = try h.add("Old but done", created: old); try h.store.complete(done, now: old)
        let g = try h.store.createGoal(title: "Quiet goal", targetDate: nil, now: old)
        let busy = try h.store.createGoal(title: "Busy goal", targetDate: nil, now: old)
        let t = try h.add("Busy goal task", created: at(cal, 2026, 10, 7)); try h.store.link(t, to: busy, asMilestone: false, now: at(cal, 2026, 10, 7))
        try h.store.context.save()

        let stale = h.engine.openInsights().filter { $0.kind == .stale }
        XCTAssertEqual(Set(stale.map(\.title)), ["Quiet task", "Old idea", "Quiet goal"])
        XCTAssertTrue(stale.first { $0.subjectID == quiet.id.uuidString }!.reason.contains("no upcoming deadline or reminder"))
        XCTAssertTrue(stale.first { $0.subjectID == idea.id.uuidString }!.reason.contains("30+ days"))
        XCTAssertTrue(stale.first { $0.subjectID == g.id.uuidString }!.message.hasPrefix("No progress recorded"))

        // Activity resets staleness (new fingerprint, and not stale any more).
        try h.store.scheduleReminder(quiet, at: at(cal, 2026, 10, 9), now: now)
        XCTAssertFalse(h.engine.openInsights().contains { $0.subjectID == quiet.id.uuidString })
        // Reviewing never archives or deletes anything.
        XCTAssertEqual(try h.store.all().filter { $0.status == .archived }.count, 0)
    }

    func testGoalApproachingAppearsInBriefingOnce() async throws {
        let h = try Harness(now: at(cal, 2026, 10, 26, 11), calendar: cal)
        let g = try h.store.createGoal(title: "Publish the article", targetDate: at(cal, 2026, 10, 31), now: at(cal, 2026, 10, 25))
        _ = g
        _ = await h.engine.tick()
        let b = try XCTUnwrap(h.notifier.briefings.first)
        XCTAssertEqual(b.decisions.map(\.kind), [.goalApproaching])
        XCTAssertTrue(b.decisions[0].message.contains("Progress: 0%"))
        XCTAssertTrue(b.notificationBody.contains("1 needs a decision"))
        // Next day unchanged bucket: not repeated.
        h.clock.set(at(cal, 2026, 10, 27, 11))
        _ = await h.engine.tick()
        XCTAssertTrue(h.notifier.briefings.count == 1, "nothing new to say, so the empty briefing is skipped")
        // Day before the target: new bucket, raised again.
        h.clock.set(at(cal, 2026, 10, 30, 11))
        _ = await h.engine.tick()
        XCTAssertEqual(h.notifier.briefings.last?.decisions.first?.fingerprint.hasPrefix("imminent"), true)
    }
}

@MainActor
final class MigrationTests: XCTestCase {
    /// Opens a real schema-v2 store (written by the Milestone 2 release) with v3 code.
    func testV2StoreOpensWithDataAndHistoryIntact() async throws {
        let src = try XCTUnwrap(Bundle.module.url(forResource: "Wren", withExtension: "store", subdirectory: "Fixtures/v2"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wren-mig-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Wren.store")
        try FileManager.default.copyItem(at: src, to: url)

        try WrenStore.backupBeforeUpgrade(url, version: 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Backups/schema-v3/Wren.store").path))

        let cal = calendar("Asia/Kolkata")
        let h = try Harness(url: url, now: at(cal, 2026, 10, 8, 12), calendar: cal)
        let all = try h.store.all()
        XCTAssertEqual(Set(all.map(\.title)), ["Submit the API review by Friday", "Waiting for the recruiter to reply", "Renew passport", "Idea: a CLI for notes"])
        let api = try XCTUnwrap(all.first { $0.title.hasPrefix("Submit") })
        XCTAssertEqual(api.snoozeCount, 2)
        XCTAssertEqual(api.postponementCount, 2, "existing snooze history counts toward postponements")
        XCTAssertEqual(api.events.filter { $0.kind == .captured }.count, 1)
        XCTAssertNil(api.goal)
        XCTAssertFalse(api.isMilestone)
        XCTAssertNil(api.followUpAt)
        XCTAssertEqual(all.first { $0.title == "Renew passport" }?.status, .completed)
        XCTAssertEqual(all.first { $0.title.hasPrefix("Waiting") }?.kind, .waiting)
        XCTAssertTrue(try h.store.goals().isEmpty)
        // v2 policy survives: the user's revocation stays.
        XCTAssertFalse(try h.policy.load().rules.contains(.autoApplyInterpretations))
        XCTAssertEqual(try h.store.dailyRun(for: "2026-10-01").briefing, .sent)
        // New features work on migrated rows.
        let r = await h.broker.submit(h.request(BuiltInAction.updateWaiting, all.first { $0.title.hasPrefix("Waiting") }!,
                                                params: ["followUpAt": .number(at(cal, 2026, 10, 9).timeIntervalSince1970)]))
        XCTAssertEqual(r.status, .succeeded)
        let g = try h.store.createGoal(title: "G", targetDate: nil, now: h.clock.now)
        try h.store.link(api, to: g, asMilestone: true, now: h.clock.now)
        XCTAssertEqual(g.milestones.count, 1)
    }
}
