import XCTest
@testable import WrenCore

/// The personal-executor brief's own phrasings, through the one router every entry point uses
/// (typed, capture panel, voice transcript). Each must reach the intended operation, never a
/// generic note or an unrelated card.
final class ExecutionRouterTests: XCTestCase {
    let ist = calendar("Asia/Kolkata")
    var now: Date { at(ist, 2026, 10, 13, 14) }
    func op(_ s: String) -> ExecutionOperation { ExecutionRouter.operation(for: s, now: now, calendar: ist) }
    func name(_ s: String) -> String { op(s).name }

    func testBriefExamplesReachTheRightOperation() {
        XCTAssertEqual(name("Remind me to call Sam tomorrow at 10 AM."), "CreateReminder")
        XCTAssertEqual(name("Ask GPT to research the fundamentals of quantum physics."), "DelegateToChatGPT")
        XCTAssertEqual(name("Check whether I have an important email from the recruiter."), "SearchGmail")
        XCTAssertEqual(name("Move the research task to Sunday."), "UpdateTask")
        XCTAssertEqual(name("Move that reminder to Sunday."), "UpdateTask")
        XCTAssertEqual(name("I need to finish the report by Friday."), "CreateTask")
        XCTAssertEqual(name("Remind me every weekday at 3 PM."), "CreateReminder", "the reminder flow asks what to remind about")
        XCTAssertEqual(name("What am I waiting for?"), "QueryStoredItems")
        XCTAssertEqual(name("What's on my calendar tomorrow?"), "QueryCalendar")
        XCTAssertEqual(name("Note: Friday is a holiday"), "SaveNote")
    }

    func testSpokenFormsRouteTheSameAsTyped() {
        for (typed, spoken) in [("Ask GPT to research quantum physics", "Hey Wren, ask GPT to research quantum physics"),
                                ("Remind me to call Sam tomorrow at 10 AM", "hey wren remind me to call Sam tomorrow at 10 AM"),
                                ("Do I have an important email from the recruiter?", "Hey Wren, do I have an important email from the recruiter?")] {
            XCTAssertEqual(op(typed).name, op(spoken).name, spoken)
            if case let .delegateToChatGPT(a) = op(typed), case let .delegateToChatGPT(b) = op(spoken) { XCTAssertEqual(a.prompt, b.prompt) }
        }
    }

    func testGPTDelegationIsNeverANoteOrWaitingCard() {
        guard case let .delegateToChatGPT(r) = op("Hey Wren, ask GPT to research quantum physics and think carefully about the important concepts.") else {
            return XCTFail("not delegated")
        }
        XCTAssertEqual(r.target, .chatgpt)
        XCTAssertEqual(r.kind, .research)
        XCTAssertTrue(r.wantsHighEffort, "“think carefully” asks for higher reasoning effort")
        XCTAssertTrue(r.wantsWebSearch)
        XCTAssertTrue(r.prompt.lowercased().contains("quantum physics"))
        XCTAssertFalse(r.prompt.lowercased().hasPrefix("hey wren"))
    }

    func testThinkingAndResearchAreDistinguished() {
        func req(_ s: String) -> AIRequest? { if case let .delegateToChatGPT(r) = op(s) { r } else { nil } }
        let think = req("Ask GPT to think deeply about whether I should change jobs")
        XCTAssertEqual(think?.kind, .thinking); XCTAssertEqual(think?.wantsHighEffort, true); XCTAssertEqual(think?.wantsWebSearch, false)
        let effort = req("Ask GPT how to structure my thesis, use high reasoning effort")
        XCTAssertEqual(effort?.wantsHighEffort, true)
        XCTAssertFalse(effort?.prompt.lowercased().contains("reasoning effort") ?? true, "the run instruction is for Wren, not the query: \(effort?.prompt ?? "")")
        let research = req("Research this topic using GPT: the latest battery chemistry")
        XCTAssertEqual(research?.kind, .research); XCTAssertEqual(research?.wantsWebSearch, true)
        let investigate = req("Tell GPT to investigate this carefully and tell me when GPT is done: why my sourdough is flat")
        XCTAssertEqual(investigate?.kind, .thinking); XCTAssertEqual(investigate?.wantsHighEffort, true)
        let plain = req("Ask GPT what quantum physics is")
        XCTAssertEqual(plain?.kind, .question); XCTAssertEqual(plain?.wantsHighEffort, false); XCTAssertEqual(plain?.wantsWebSearch, false)
    }

    func testAmbiguousOrEmptyRequestsAskInsteadOfGuessing() {
        XCTAssertEqual(name("Ask GPT."), "ClarifyIntent")
        XCTAssertEqual(name("Hey Wren, ask ChatGPT"), "ClarifyIntent")
        XCTAssertEqual(name("   "), "ClarifyIntent")
    }

    func testEmailActionsAndDelegationResults() {
        XCTAssertEqual(op("Open the latest email from Sam"), .openEmail(sender: "sam"))
        XCTAssertEqual(op("show my last email"), .openEmail(sender: nil))
        XCTAssertEqual(op("Mark the email from the bank as read"), .markEmailRead(sender: "bank"))
        XCTAssertNotEqual(name("Mark the email from the bank"), "MarkEmailRead", "only an explicit “as read”")
        XCTAssertEqual(name("Show the GPT result"), "OpenChatGPTRequest")
        XCTAssertEqual(name("What did ChatGPT say?"), "OpenChatGPTRequest")
    }

    func testNonGPTMentionsStayLocal() {
        XCTAssertNotEqual(name("Email the GPT team about the launch tomorrow"), "DelegateToChatGPT")
        XCTAssertEqual(name("Remind me to ask GPT about taxes tomorrow at 9 AM"), "CreateReminder")
    }

    func testSubmissionGuardBlocksRepeatsButNotLaterRequests() {
        var g = SubmissionGuard(window: 3)
        let t = Date(timeIntervalSince1970: 1_000)
        let k = SubmissionGuard.key("Remind me to call Sam tomorrow at 10 AM.", channel: "voice")
        XCTAssertEqual(k, SubmissionGuard.key("remind me to call sam tomorrow at 10 am", channel: "voice"))
        XCTAssertTrue(g.begin(k, now: t))
        XCTAssertFalse(g.begin(k, now: t.addingTimeInterval(0.5)), "still running")
        g.end(k, now: t.addingTimeInterval(1))
        XCTAssertFalse(g.begin(k, now: t.addingTimeInterval(2)), "just ran")
        XCTAssertTrue(g.begin(SubmissionGuard.key("something else", channel: "voice"), now: t.addingTimeInterval(2)))
        XCTAssertTrue(g.begin(k, now: t.addingTimeInterval(5)), "a deliberate repeat later is allowed")
    }
}

extension ExecutionRouterTests {
    func testCarefullyOrInvestigateAloneDontRaiseTheEffort() {
        func req(_ s: String) -> AIRequest? { if case let .delegateToChatGPT(r) = op(s) { r } else { nil } }
        XCTAssertEqual(req("Ask GPT to carefully summarize this article")?.wantsHighEffort, false)
        XCTAssertEqual(req("Ask GPT to investigate why my build fails")?.wantsHighEffort, false)
        XCTAssertEqual(req("Ask GPT to investigate this carefully: why my build fails")?.wantsHighEffort, true)
        XCTAssertEqual(req("Ask GPT to think carefully about my options")?.wantsHighEffort, true)
    }
}
