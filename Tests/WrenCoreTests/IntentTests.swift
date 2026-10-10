import XCTest
@testable import WrenCore

final class IntentTests: XCTestCase {
    let cal = calendar("Asia/Kolkata")
    var now: Date { at(cal, 2026, 10, 8, 15) }
    var proc: IntentProcessor { IntentProcessor(client: nil, model: nil, calendar: cal) }

    func json(_ kind: String, _ title: String, _ phrase: String?, priority: String = "normal") -> String {
        let p = phrase.map { "\"\($0)\"" } ?? "null"
        return #"{"kind":"\#(kind)","title":"\#(title)","priority":"\#(priority)","deadline_phrase":\#(p)}"#
    }

    // P3-01
    func testCommitmentWithDate() throws {
        let i = try proc.validate(modelOutput: json("commitment", "Submit the form", "tomorrow"),
                                  input: "I need to submit the form tomorrow.", now: now)
        XCTAssertEqual(i.kind, .commitment)
        XCTAssertEqual(i.title, "Submit the form")
        XCTAssertEqual(i.deadline, at(cal, 2026, 10, 9))
        XCTAssertFalse(i.deadlineHasTime)
    }

    // P3-04
    func testIdeaGetsNoDeadline() throws {
        let i = try proc.validate(modelOutput: json("idea", "Build an AI startup", nil),
                                  input: "I might build an AI startup someday.", now: now)
        XCTAssertEqual(i.kind, .idea)
        XCTAssertNil(i.deadline)
    }

    func testSpeculativeCommitmentDowngradedToIdea() throws {
        let i = try proc.validate(modelOutput: json("commitment", "Build an AI startup", nil),
                                  input: "I might build an AI startup someday.", now: now)
        XCTAssertEqual(i.kind, .idea)
        XCTAssertNil(i.deadline)
    }

    // P3-07: missing detail preserved, nothing invented.
    func testForgotWhichForm() throws {
        let input = "I need to submit something on Friday, but I forgot which form."
        let i = try proc.validate(modelOutput: json("commitment", "Submit a form (which one?)", "on Friday"), input: input, now: now)
        XCTAssertEqual(i.deadline, at(cal, 2026, 10, 9))
    }

    // P3-08: invented deadline is rejected.
    func testInventedDeadlineIgnored() throws {
        let i = try proc.validate(modelOutput: json("commitment", "Read the paper", "next tuesday"),
                                  input: "Read that research paper", now: now)
        XCTAssertNil(i.deadline)
        XCTAssertNotNil(i.note)
    }

    // P3-09, P3-10
    func testMalformedOutputThrows() {
        XCTAssertThrowsError(try proc.validate(modelOutput: "Sure! Here is the JSON:", input: "x", now: now))
        XCTAssertThrowsError(try proc.validate(modelOutput: json("task", "x", nil), input: "x", now: now))
        XCTAssertThrowsError(try proc.validate(modelOutput: json("commitment", "  ", nil), input: "x", now: now))
        XCTAssertThrowsError(try proc.validate(modelOutput: json("commitment", "x", nil, priority: "urgent!!"), input: "x", now: now))
        XCTAssertThrowsError(try proc.validate(modelOutput: #"{"title":"x"}"#, input: "x", now: now))
    }

    func testQuestionAndWaitingDropDates() throws {
        let q = try proc.validate(modelOutput: json("waiting", "Recruiter reply", "tomorrow"),
                                  input: "Waiting for the recruiter to reply, maybe tomorrow", now: now)
        XCTAssertEqual(q.kind, .waiting)
        XCTAssertNil(q.deadline)
    }

    func testRulesOnly() {
        let a = proc.rulesOnly("Remind me to call my friend at 8 tonight.", now: now)
        XCTAssertEqual(a.kind, .commitment)
        XCTAssertEqual(a.title, "Call my friend at 8 tonight")
        XCTAssertEqual(a.deadline, at(cal, 2026, 10, 8, 20))
        let b = proc.rulesOnly("I have an idea for a new AI startup.", now: now)
        XCTAssertEqual(b.kind, .unsorted)
        XCTAssertNil(b.deadline)
    }

    func testUnavailableWithoutClientOrModel() async {
        if case .unavailable = await proc.interpret("x", now: now) {} else { XCTFail() }
        let p2 = IntentProcessor(client: try! OllamaClient(), model: nil, calendar: cal)
        if case .unavailable = await p2.interpret("x", now: now) {} else { XCTFail() }
    }
}
