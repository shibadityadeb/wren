import XCTest
@testable import WrenCore

final class IntentRouterTests: XCTestCase {
    let ist = calendar("Asia/Kolkata")
    var now: Date { at(ist, 2026, 10, 11, 14) }
    func route(_ s: String) -> Intent { IntentRouter.route(s, now: now, calendar: ist) }
    func ask(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> AIRequest? {
        guard case let .askAI(r) = route(s) else { XCTFail("\(s) → \(route(s))", file: file, line: line); return nil }
        XCTAssertEqual(r.target, .chatgpt, file: file, line: line)
        XCTAssertEqual(r.original, s, file: file, line: line)
        return r
    }

    func testTheReportedSentenceAsksChatGPT() {
        XCTAssertEqual(ask("can you check on gpt what is quantum physics")?.prompt, "What is quantum physics?")
        XCTAssertEqual(ask("Can you check on GPT what is quantum physics?")?.prompt, "What is quantum physics?")
    }

    func testNaturalVariations() {
        XCTAssertEqual(ask("Ask ChatGPT to explain quantum physics.")?.prompt, "Explain quantum physics.")
        XCTAssertEqual(ask("Get GPT to brainstorm names for my project.")?.prompt, "Brainstorm names for my project.")
        XCTAssertEqual(ask("Can you ask ChatGPT to analyze this idea?")?.prompt, "Analyze this idea.")
        XCTAssertEqual(ask("Ask GPT to summarize this document.")?.prompt, "Summarize this document.")
        XCTAssertEqual(ask("Ask ChatGPT to brainstorm names for Wren")?.prompt, "Brainstorm names for Wren.")
        XCTAssertEqual(ask("ask chatgpt whether coffee is bad for sleep")?.prompt, "Is it true that coffee is bad for sleep?")
        XCTAssertEqual(ask("what does chatgpt think about rust vs go")?.prompt, "What can you tell me about rust vs go?")
        XCTAssertEqual(ask("look up the boiling point of water on chatgpt")?.prompt, "The boiling point of water.")
        XCTAssertEqual(ask("ChatGPT, why is the sky blue")?.prompt, "Why is the sky blue?")
        XCTAssertEqual(ask("please use my ChatGPT account to explore this problem")?.prompt, "Explore this problem.")
        XCTAssertEqual(ask("Send this research question to GPT and ask for a deeper analysis")?.depth, .deep)
        XCTAssertEqual(ask("check with gpt-4o how tides work and tell me")?.prompt, "How tides work?")
    }

    func testOtherIntentsStayTheirOwn() {
        XCTAssertEqual(route("Remind me to call Sam tomorrow"), .reminder, "reminder, not a ChatGPT question")
        XCTAssertEqual(route("Remind me to ask ChatGPT about the API tomorrow at 9 AM"), .reminder)
        XCTAssertEqual(route("What am I waiting for?"), .storedQuery(.waiting))
        XCTAssertEqual(route("show me what's overdue"), .storedQuery(.overdue))
        XCTAssertEqual(route("Move the report to Friday"), .itemCommand)
        XCTAssertEqual(route("snooze it for 10 minutes"), .itemCommand)
        XCTAssertEqual(route("Note: ask ChatGPT about quantum physics"), .explicitCapture("ask ChatGPT about quantum physics"),
                       "an explicit save keeps the text instead of running it")
        XCTAssertEqual(route("save this: what is quantum physics"), .explicitCapture("what is quantum physics"))
        XCTAssertEqual(route("Buy milk"), .capture)
        XCTAssertEqual(route("Email the GPT team about pricing"), .capture, "mentioning GPT isn't asking it")
        guard case let .generalQuestion(q) = route("what is quantum physics") else { return XCTFail() }
        XCTAssertEqual(q.prompt, "What is quantum physics?"); XCTAssertNil(q.target)
    }

    func testStoredQueriesMustBeGroundedInTheWords() {
        XCTAssertFalse(IntentRouter.isGrounded(.waiting, in: "can you check on gpt what is quantum physics"),
                       "the reported bug: nothing in the text is about waiting items")
        XCTAssertTrue(IntentRouter.isGrounded(.waiting, in: "anything I'm still expecting from people?"))
        XCTAssertTrue(IntentRouter.isGrounded(.goalsNoProgress, in: "which goals are stuck"))
        XCTAssertFalse(IntentRouter.isGrounded(.overdue, in: "what is the capital of France"))
    }
}
