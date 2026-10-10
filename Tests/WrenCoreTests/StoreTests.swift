import XCTest
@testable import WrenCore

@MainActor
final class StoreTests: XCTestCase {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wren-test-\(UUID().uuidString)/Wren.store")
    }

    // P1-01
    func testPersistsAcrossReopen() throws {
        let url = tempURL()
        var id: UUID
        do {
            let store = try WrenStore(url: url)
            let c = try store.capture("Submit the scholarship form by Friday", source: .hotkey)
            try store.scheduleReminder(c, at: Date().addingTimeInterval(3600))
            id = c.id
        }
        let reopened = try WrenStore(url: url)
        let c = try XCTUnwrap(reopened.item(id: id))
        XCTAssertEqual(c.originalText, "Submit the scholarship form by Friday")
        XCTAssertEqual(c.source, .hotkey)
        XCTAssertEqual(c.status, .pending)
        XCTAssertNotNil(c.nextReminderAt)
        XCTAssertEqual(c.events.map(\.kind).sorted { $0.rawValue < $1.rawValue }, [.captured, .reminderScheduled])
    }

    func testCaptureRejectsEmpty() throws {
        let store = try WrenStore(url: nil)
        XCTAssertThrowsError(try store.capture("   \n", source: .hotkey)) { XCTAssertEqual($0 as? StoreError, .emptyText) }
    }

    func testCaptureIsSavedBeforeInterpretation() throws {
        let store = try WrenStore(url: nil)
        let c = try store.capture("call mum", source: .hotkey)
        XCTAssertEqual(c.processing, .awaiting)
        XCTAssertEqual(c.kind, .unsorted)
        XCTAssertEqual(try store.all().count, 1)
    }

    // P1-02, P1-03
    func testCompleteAndDropClearReminders() throws {
        let store = try WrenStore(url: nil)
        let a = try store.capture("a", source: .manual), b = try store.capture("b", source: .manual)
        try store.scheduleReminder(a, at: .now.addingTimeInterval(60))
        try store.scheduleReminder(b, at: .now.addingTimeInterval(60))
        try store.complete(a); try store.drop(b)
        XCTAssertEqual(a.status, .completed); XCTAssertNotNil(a.completedAt); XCTAssertNil(a.nextReminderAt)
        XCTAssertEqual(b.status, .dropped); XCTAssertNotNil(b.droppedAt); XCTAssertNil(b.nextReminderAt)
        XCTAssertTrue(try store.pending().isEmpty)
        XCTAssertEqual(try store.closed().count, 2)
    }

    // P1-04
    func testSnooze() throws {
        let store = try WrenStore(url: nil)
        let now = Date()
        let c = try store.capture("x", source: .manual)
        try store.snooze(c, until: now.addingTimeInterval(3600), now: now)
        XCTAssertEqual(c.snoozeCount, 1)
        XCTAssertEqual(c.nextReminderAt, now.addingTimeInterval(3600))
        XCTAssertTrue(c.events.contains { $0.kind == .snoozed })
        XCTAssertThrowsError(try store.snooze(c, until: now.addingTimeInterval(-1), now: now))
    }

    // P1-05
    func testTerminalStatesRejectTransitions() throws {
        let store = try WrenStore(url: nil)
        let c = try store.capture("x", source: .manual)
        try store.complete(c)
        XCTAssertThrowsError(try store.snooze(c, until: .now.addingTimeInterval(60)))
        XCTAssertThrowsError(try store.complete(c))
        XCTAssertThrowsError(try store.scheduleReminder(c, at: .now.addingTimeInterval(60)))
        try store.reopen(c)
        XCTAssertEqual(c.status, .pending)
        XCTAssertNil(c.completedAt)
    }

    // P1-06
    func testPendingOrder() throws {
        let store = try WrenStore(url: nil)
        let undatedHigh = try store.capture("undated high", source: .manual); undatedHigh.priority = .high
        let later = try store.capture("later", source: .manual); later.deadline = .now.addingTimeInterval(86400 * 3)
        let soon = try store.capture("soon", source: .manual); soon.deadline = .now.addingTimeInterval(3600)
        let undatedLow = try store.capture("undated low", source: .manual); undatedLow.priority = .low
        XCTAssertEqual(try store.pending().map(\.title), ["soon", "later", "undated high", "undated low"])
    }

    // P1-07
    func testUnwritablePathThrowsTypedError() {
        XCTAssertThrowsError(try WrenStore(url: URL(fileURLWithPath: "/System/wren-nope/Wren.store"))) {
            guard case .cannotOpen = $0 as? StoreError else { return XCTFail("\($0)") }
        }
    }

    func testManualEditIsNotOverwrittenByModel() throws {
        let store = try WrenStore(url: nil)
        let c = try store.capture("thing", source: .hotkey)
        try store.edit(c, .init(title: "My title", details: nil, kind: .idea, priority: .low, deadline: nil, deadlineHasTime: false, nextReminderAt: nil))
        try store.applyInterpretation(Interpretation(kind: .commitment, title: "Model title", priority: .high, deadline: nil, deadlineHasTime: false, note: nil),
                                      to: c, model: "m", reminderPolicy: ReminderPolicy())
        XCTAssertEqual(c.title, "My title")
        XCTAssertEqual(c.kind, .idea)
    }

    func testInterpretationSchedulesFirstReminderFromDeadline() throws {
        let cal = calendar("Asia/Kolkata")
        let now = at(cal, 2026, 10, 8, 15)
        let store = try WrenStore(url: nil)
        let c = try store.capture("submit form by friday", source: .hotkey, now: now)
        try store.applyInterpretation(Interpretation(kind: .commitment, title: "Submit form", priority: .normal,
                                                     deadline: at(cal, 2026, 10, 9), deadlineHasTime: false, note: nil),
                                      to: c, model: nil, reminderPolicy: ReminderPolicy(dateOnlyReminderHour: 10, calendar: cal), now: now)
        XCTAssertEqual(c.nextReminderAt, at(cal, 2026, 10, 9, 10))
    }

    func testInterpretationFailureKeepsRawText() throws {
        let store = try WrenStore(url: nil)
        let c = try store.capture("Submit something Friday", source: .hotkey)
        try store.markInterpretationFailed(c, reason: "not json")
        XCTAssertEqual(c.processing, .failed)
        XCTAssertEqual(c.originalText, "Submit something Friday")
        XCTAssertEqual(c.status, .pending)
    }
}
