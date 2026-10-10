import XCTest
@testable import WrenCore

@MainActor
final class ReminderTests: XCTestCase {
    func testDueOnlyOnceAndOnlyWhenPending() throws {
        let store = try WrenStore(url: nil)
        let now = Date()
        let c = try store.capture("x", source: .manual, now: now)
        try store.scheduleReminder(c, at: now.addingTimeInterval(60), now: now)
        XCTAssertFalse(ReminderPolicy.isDue(c, now: now))
        XCTAssertTrue(ReminderPolicy.isDue(c, now: now.addingTimeInterval(60)))
        try store.markReminderSent(c, now: now.addingTimeInterval(61))
        XCTAssertFalse(ReminderPolicy.isDue(c, now: now.addingTimeInterval(120)), "sent reminder must not fire again")
        XCTAssertTrue(ReminderPolicy.due(try store.all(), now: now.addingTimeInterval(9999)).isEmpty)
    }

    func testRestartDoesNotDuplicate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wren-\(UUID())/Wren.store")
        let now = Date()
        do {
            let s = try WrenStore(url: url)
            let c = try s.capture("x", source: .manual, now: now)
            try s.scheduleReminder(c, at: now, now: now)
            try s.markReminderSent(c, now: now)
        }
        let s2 = try WrenStore(url: url)
        XCTAssertTrue(ReminderPolicy.due(try s2.all(), now: now.addingTimeInterval(60)).isEmpty)
    }

    // P4-10/P4-11: closed items never surface even with a stale reminder field.
    func testClosedItemsNeverDue() throws {
        let store = try WrenStore(url: nil)
        let c = try store.capture("x", source: .manual)
        c.status = .completed
        c.nextReminderAt = Date().addingTimeInterval(-10)
        XCTAssertFalse(ReminderPolicy.isDue(c, now: .now))
        c.status = .dropped
        XCTAssertFalse(ReminderPolicy.isDue(c, now: .now))
    }

    func testInitialReminderRules() throws {
        let cal = calendar("America/Los_Angeles")
        let policy = ReminderPolicy(dateOnlyReminderHour: 10, calendar: cal)
        let now = at(cal, 2026, 10, 8, 15)
        let c = Commitment(originalText: "x", source: .manual, now: now)
        c.deadline = at(cal, 2026, 10, 9)
        XCTAssertNil(policy.initialReminder(for: c, now: now), "unsorted items get no reminders")
        c.kind = .idea
        XCTAssertNil(policy.initialReminder(for: c, now: now), "ideas get no reminders")
        c.kind = .commitment
        XCTAssertEqual(policy.initialReminder(for: c, now: now), at(cal, 2026, 10, 9, 10))
        c.deadline = at(cal, 2026, 10, 8, 20); c.deadlineHasTime = true
        XCTAssertEqual(policy.initialReminder(for: c, now: now), at(cal, 2026, 10, 8, 20))
        c.deadline = at(cal, 2026, 10, 8, 9)
        XCTAssertNil(policy.initialReminder(for: c, now: now), "past times are not scheduled")
    }

    func testNextWakeIsCapped() {
        let now = Date()
        let c = Commitment(originalText: "x", source: .manual)
        c.nextReminderAt = now.addingTimeInterval(20)
        XCTAssertEqual(ReminderPolicy.nextWake([c], now: now), now.addingTimeInterval(20))
        c.nextReminderAt = now.addingTimeInterval(3600)
        XCTAssertEqual(ReminderPolicy.nextWake([c], now: now), now.addingTimeInterval(60))
    }
}
