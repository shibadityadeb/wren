import XCTest
@testable import WrenCore

/// Destination-aware routing: naming GPT/ChatGPT always means ChatGPT (never a choice, never the local
/// model); a question naming no assistant goes to Wren's local AI; follow-ups keep their tool.
final class ChatGPTRoutingTests: XCTestCase {
    let ist = calendar("Asia/Kolkata")
    var now: Date { at(ist, 2026, 10, 14, 11) }
    func op(_ s: String) -> ExecutionOperation { ExecutionRouter.operation(for: s, now: now, calendar: ist) }
    func gpt(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> AIRequest? {
        guard case let .delegateToChatGPT(r) = op(s) else { XCTFail("\(s) → \(op(s).name)", file: file, line: line); return nil }
        XCTAssertEqual(r.target, .chatgpt, file: file, line: line)
        return r
    }

    func testRuleAExplicitChatGPTAlwaysMeansChatGPT() {
        XCTAssertEqual(gpt("Can you ask in GPT what gradient means in machine learning?")?.prompt.lowercased().contains("gradient means in machine learning"), true)
        XCTAssertEqual(gpt("Ask ChatGPT what quantum physics is.")?.prompt, "What is quantum physics?")
        XCTAssertEqual(gpt("Make a query in ChatGPT about transformer architectures.")?.prompt, "Transformer architectures.")
        XCTAssertEqual(gpt("Search in GPT for recent research on agentic AI.")?.kind, .research)
        XCTAssertEqual(gpt("Ask GPT to think deeply about this.")?.wantsHighEffort, true)
        XCTAssertEqual(gpt("Tell ChatGPT to research this topic.")?.prompt, "Research this topic.")
        XCTAssertEqual(gpt("Ask ChatGPT what gradient descent is.")?.prompt, "What is gradient descent?")
        XCTAssertEqual(gpt("Could you look this up using ChatGPT: the history of the transistor")?.target, .chatgpt)
        // The instruction is kept as said; Wren doesn't claim to switch on ChatGPT's Deep Research mode.
        XCTAssertEqual(gpt("Ask ChatGPT to use Deep Research to investigate this topic")?.prompt, "Use Deep Research to investigate this topic.")
    }

    func testRuleBQuestionsNamingNoAssistantGoToTheLocalAI() {
        for q in ["What is gradient descent?", "Can you explain quantum physics?", "Explain this code.", "What does this error mean?", "Help me understand this concept."] {
            guard case let .generalQuestion(r) = op(q) else { XCTFail("\(q) → \(op(q).name)"); continue }
            XCTAssertNil(r.target, q)
            XCTAssertEqual(op(q).name, "AskLocalAI")
        }
    }

    func testRuleCFollowUpsReferToTheEarlierRequest() {
        XCTAssertEqual(op("Continue researching this in ChatGPT."), .followUpDelegation(.init(action: .continue(instruction: "Please continue this research and go further."), namesChatGPT: true)))
        XCTAssertEqual(op("Continue that research in ChatGPT."), .followUpDelegation(.init(action: .continue(instruction: "Please continue this research and go further."), namesChatGPT: true)))
        XCTAssertEqual(op("Continue that research."), .followUpDelegation(.init(action: .continue(instruction: "Please continue this research and go further."), namesChatGPT: false)))
        XCTAssertEqual(op("Ask it to go deeper."), .followUpDelegation(.init(action: .continue(instruction: "Go deeper."), namesChatGPT: false)))
        XCTAssertEqual(op("Find more sources."), .followUpDelegation(.init(action: .continue(instruction: "Find more sources."), namesChatGPT: false)))
        XCTAssertEqual(op("Open that in GPT."), .followUpDelegation(.init(action: .open, namesChatGPT: true)))
        XCTAssertEqual(op("Open that query in GPT."), .followUpDelegation(.init(action: .open, namesChatGPT: true)))
    }

    func testNamingGPTAsATopicIsntADestination() {
        XCTAssertNotEqual(op("Email the GPT team about the launch tomorrow").name, "DelegateToChatGPT")
        XCTAssertNotEqual(op("I compared GPT models yesterday").name, "DelegateToChatGPT")
        XCTAssertEqual(op("Remind me to ask GPT about taxes tomorrow at 9 AM").name, "CreateReminder")
        XCTAssertEqual(op("Note: try asking in ChatGPT later").name, "SaveNote")
        XCTAssertNotEqual(op("Open the report").name, "FollowUpDelegation", "an item, not a delegation")
        XCTAssertNotEqual(op("Continue the report tomorrow").name, "FollowUpDelegation")
    }

    func testConversationLinksAreValidatedNeverInvented() {
        XCTAssertEqual(ChatGPTWeb.conversationURL("https://chatgpt.com/c/68f0c1d2-1234-4abc-9def-0123456789ab")?.absoluteString, "https://chatgpt.com/c/68f0c1d2-1234-4abc-9def-0123456789ab")
        XCTAssertEqual(ChatGPTWeb.conversationURL(" https://chat.openai.com/c/abcdef12-0000 ")?.host, "chatgpt.com")
        XCTAssertNotNil(ChatGPTWeb.conversationURL("https://chatgpt.com/g/g-abc123-research/c/68f0c1d2-1234"))
        XCTAssertNotNil(ChatGPTWeb.conversationURL("https://chatgpt.com/share/68f0c1d2-5678"))
        for bad in ["https://chatgpt.com/", "https://chatgpt.com/?q=hello", "http://chatgpt.com/c/68f0c1d2-1234", "https://evil.com/c/68f0c1d2-1234",
                    "https://chatgpt.com.evil.com/c/68f0c1d2-1234", "https://chatgpt.com/c/x", "https://user@chatgpt.com/c/68f0c1d2-1234", "javascript:alert(1)", "https://chatgpt.com/gpts"] {
            XCTAssertNil(ChatGPTWeb.conversationURL(bad), bad)
        }
        XCTAssertEqual(ChatGPTWeb.conversationURL("https://chatgpt.com/c/68f0c1d2-1234?model=x#frag")?.absoluteString, "https://chatgpt.com/c/68f0c1d2-1234", "query and fragment dropped")
    }

    func testLaunchLinksAreHonestAboutTheirMethod() {
        let off = ChatGPTWeb.launch("What is gradient descent?", prefill: false)
        XCTAssertEqual(off.url, ChatGPTWeb.home); XCTAssertEqual(off.method, .clipboard)
        let on = ChatGPTWeb.launch("What is A+B & why?", prefill: true)
        XCTAssertEqual(on.method, .prefillLink)
        XCTAssertEqual(URLComponents(url: on.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "What is A+B & why?", "the prompt survives exactly")
        XCTAssertEqual(ChatGPTWeb.launch(String(repeating: "x", count: 2000), prefill: true).method, .clipboard, "too long for a link")
    }

    func testFollowUpPromptCarriesOnlyTheEarlierExchange() {
        let p = ChatGPTWeb.followUpPrompt(earlierRequest: "Research quantum physics.", earlierAnswer: "Quantum physics is…", instruction: "Find more sources.")
        XCTAssertTrue(p.contains("Research quantum physics.") && p.contains("Quantum physics is…") && p.hasSuffix("Find more sources."))
        XCTAssertFalse(ChatGPTWeb.followUpPrompt(earlierRequest: "x", earlierAnswer: nil, instruction: "y").contains("The answer I got"))
    }
}

extension ChatGPTRoutingTests {
    func testCardsNeverChooseAProviderForTheUser() {
        let q = AIRequest(prompt: "What is gradient descent?", original: "What is gradient descent?", target: nil)
        var choose = AskCard(request: q, destination: .choose)
        choose.chatgptReady = true; choose.localAvailable = false
        XCTAssertNil(choose.primary, "no local AI: the user picks; Return doesn't send it to ChatGPT just because it's connected")
        choose.localAvailable = true
        XCTAssertEqual(choose.primary, .run(.local))
        var web = AskCard(request: AIRequest(prompt: "x", original: "ask GPT x", target: .chatgpt), destination: .chatgptWeb)
        XCTAssertEqual(web.primary, .run(.chatgptWeb))
        web.phase = .handedOff(.awaitingSubmission, recordID: UUID())
        XCTAssertNil(web.primary, "Return after the handoff doesn't open ChatGPT again")
    }

    func testAWebsiteHandoffIsNeverReportedCompleted() {
        let r = DelegationRecord(task: "Research quantum physics.", destination: .chatgptHandoff, depth: .normal, now: Date())
        r.status = .handedOff
        for s in [WebHandoffState.prepared, .openedInChatGPT, .awaitingSubmission, .submittedUnverified, .conversationLinked, .failedToOpen] {
            r.webState = s
            XCTAssertNotEqual(r.displayStatus, "Completed")
            XCTAssertFalse(r.displayStatus.lowercased().contains("complete") && s != .submittedUnverified, s.rawValue)
        }
        r.webState = .awaitingSubmission
        XCTAssertFalse(r.status.isFinal, "a handoff isn't a finished request, so it's never announced as one")
        XCTAssertNil(r.conversationURL, "no link until the user gives one")
        r.providerURL = "https://chatgpt.com/c/68f0c1d2-1234"
        XCTAssertNotNil(r.conversationURL)
        r.providerURL = "https://chatgpt.com/"
        XCTAssertNil(r.conversationURL, "a stored non-conversation address is never offered as the conversation")
        XCTAssertTrue(r.modeLabel.hasPrefix("ChatGPT website"))
        let api = DelegationRecord(task: "x", destination: .chatgptPlan, depth: .normal, now: Date())
        XCTAssertTrue(api.modeLabel.hasPrefix("Run with connected ChatGPT in Wren"))
    }
}
