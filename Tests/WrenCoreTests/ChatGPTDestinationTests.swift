import XCTest
@testable import WrenCore

/// "ChatGPT means ChatGPT": an explicit request is never answered by the local model, a tool named
/// inside a reminder or task isn't run now, and every headline names who really did the work.
/// The two transcripts below are exactly what Apple's on-device speech produced on 14 October 2026
/// (read from the installed app's records); both had been answered by the local AI and shown as
/// "GPT finished".
final class ChatGPTDestinationTests: XCTestCase {
    let ist = calendar("Asia/Kolkata")
    var now: Date { at(ist, 2026, 10, 14, 21, 48) }
    func intent(_ s: String) -> CommandIntent { CommandRouter.intent(for: s, now: now, calendar: ist) }
    func prompt(_ s: String) -> String? { if case let .delegateToChatGPT(r) = intent(s).operation { r.prompt } else { nil } }

    func testTheRealTranscriptsGoToChatGPT() {
        XCTAssertEqual(prompt("Can you make a query at ChatGPT? What is the gradient descent machine learning?"),
                       "What is the gradient descent machine learning?", "“at ChatGPT” and a question mark in the middle")
        XCTAssertEqual(prompt("Can you make a query, ChatGPT what is great in decent machine learning?"),
                       "What is great in decent machine learning?", "the misheard words are kept as heard, not “corrected”")
        // The reminder transcript from 20:38 ("for to"): a reminder, never a question.
        guard case let .create(title, .once(d), _)? = ReminderCommand.parse("Can you make a reminder for to call Sam tomorrow at 10 AM?", now: now, calendar: ist) else { return XCTFail() }
        XCTAssertEqual(title, "Call Sam"); XCTAssertEqual(d, at(ist, 2026, 10, 15, 10))
    }

    func testExplicitChatGPTRequestsAreNeverLocal() {
        for s in ["Ask GPT what gradient descent is.", "Can you make a query in ChatGPT about gradient descent?", "Ask ChatGPT to explain quantum physics.",
                  "Search in GPT for research on agentic AI.", "Tell GPT to investigate this problem.", "Ask GPT to think deeply about this.",
                  "Research this in ChatGPT and let me know when it is done.", "Ask GPT about quantum physics now.",
                  "Send a question to GPT about the visa rules", "Hey ChatGPT, what is backpropagation?", "Start a chat in ChatGPT on Rust lifetimes"] {
            let i = intent(s)
            XCTAssertEqual(i.action, "DelegateToChatGPT", s)
            XCTAssertEqual(i.destination, .chatgpt, s)
            XCTAssertNotEqual(i.action, "AskLocalAI", s)
        }
        XCTAssertEqual(prompt("Research this in ChatGPT and let me know when it is done."), "Research this.", "the instruction stays; the note to Wren goes")
        XCTAssertEqual(prompt("Ask GPT about quantum physics now."), "Quantum physics.", "“now” is for Wren, not ChatGPT")
    }

    func testSpokenSpellingsOfTheNameStillMeanChatGPT() {
        for s in ["Ask chat GPT what a monad is", "Ask chat G P T what a monad is", "Ask Chat-GPT what a monad is", "Ask chat G.P.T. what a monad is",
                  "Ask chat GBT what a monad is", "Ask Chad GPT what a monad is", "Ask G.P.T. what a monad is"] {
            XCTAssertEqual(prompt(s), "What is a monad?", s)
        }
        XCTAssertEqual(IntentRouter.normalizeAssistantName("ask chat G P T about the chat log"), "ask ChatGPT about the chat log", "only the name changes")
    }

    func testNamingGPTAsATopicIsntARequest() {
        XCTAssertEqual(intent("What is GPT?").action, "AskLocalAI")
        XCTAssertEqual(intent("I compared GPT and Claude yesterday").action, "Capture")
        XCTAssertNotEqual(intent("Email the GPT team about the launch tomorrow").action, "DelegateToChatGPT")
    }

    func testAToolInsideAFutureTaskIsntRunNow() {
        XCTAssertEqual(intent("Remind me to ask GPT about quantum physics tomorrow.").action, "CreateReminder")
        XCTAssertEqual(intent("Remind me to call Sam tomorrow at 10 AM.").action, "CreateReminder")
        guard case let .createTask(t) = intent("I need to research this by Friday.").operation else { return XCTFail() }
        XCTAssertEqual(t.title, "Research this"); XCTAssertEqual(t.deadline?.date, at(ist, 2026, 10, 16))
        XCTAssertEqual(intent("I need to submit the assignment by Friday").action, "CreateTask")
        XCTAssertEqual(intent("Remind me to finish the project tomorrow.").action, "CreateReminder")
    }

    func testEveryIntentNamesItsAuthorizationAndHandler() {
        let r = intent("Can you make a reminder to call Sam tomorrow at 10 AM?")
        XCTAssertEqual(r.authorization, BuiltInAction.createReminder.rawValue)
        XCTAssertEqual(r.handler, "ItemExecution.createReminder")
        XCTAssertTrue(intent("Ask GPT what gradient descent is.").authorization.contains(BuiltInAction.chatgptHandoff.rawValue))
        XCTAssertEqual(intent("Anything urgent in my inbox?").authorization, BuiltInAction.readEmail.rawValue)
        XCTAssertTrue(intent("What is gradient descent?").authorization.hasPrefix("none"))
        XCTAssertFalse(r.summary.contains("Sam"), "logs never carry the user's words")
    }
}

/// The capture panel's headline is built from who actually ran the request (the card's destination
/// and real phase), so a local answer can never read "GPT finished".
final class AskHeadlineTests: XCTestCase {
    let request = AIRequest(prompt: "What is gradient descent?", original: "What is gradient descent?", target: nil)
    func card(_ d: AskCard.Destination, _ p: AskCard.Phase) -> AskCard { var c = AskCard(request: request, destination: d); c.phase = p; return c }
    let id = UUID()

    func testLocalAnswersSayLocalAI() {
        let h = card(.local, .answered(text: "…", source: "Local model qwen2.5:3b, on this Mac", recordID: id)).headline
        XCTAssertEqual(h, "Local AI answered")
        XCTAssertFalse(h?.contains("GPT") ?? true)
        XCTAssertEqual(card(.local, .sending(recordID: nil)).headline, "Asking local AI on this Mac…")
        XCTAssertEqual(card(.local, .failed("x", retryable: true)).headline, "Local AI didn't answer")
    }

    func testChatGPTInWrenSaysInWren() {
        XCTAssertEqual(card(.chatgpt, .answered(text: "…", source: "ChatGPT", recordID: id)).headline, "ChatGPT answered, in Wren")
        XCTAssertEqual(card(.chatgpt, .notConnected).headline, "Not sent to ChatGPT")
    }

    func testTheWebsiteIsNeverFinished() {
        for state in [WebHandoffState.preparing, .opening, .promptLoaded, .awaitingSubmission, .submittedUnverified, .submittedVerified, .conversationLinked, .signInRequired, .failedToOpen] {
            let h = card(.chatgptWeb, .handedOff(state, recordID: id)).headline ?? ""
            XCTAssertEqual(h, state.label)
            XCTAssertFalse(h.lowercased().contains("finished") || h.lowercased().contains("answered"), "\(state): \(h)")
        }
        XCTAssertNil(card(.choose, .ready).headline, "nothing has run yet")
    }
}

/// "Send it for me" decides only from facts: the setting, macOS permissions, the browser, and the
/// tab's address. It presses once, after the page has taken the question, and never counts the key
/// press as proof of sending.
final class ChatGPTAutoSendTests: XCTestCase {
    func ready(enabled: Bool = true, ax: Bool = true, control: Bool = true, browser: String? = "com.google.chrome", method: WebLaunchMethod = .prefillLink) -> ChatGPTAutoSend.Readiness {
        ChatGPTAutoSend.readiness(enabled: enabled, accessibilityTrusted: ax, browserControlAllowed: control, browser: browser, browserName: "Safari", method: method)
    }

    func testReadinessNamesWhatsMissing() {
        XCTAssertEqual(ready(), .ready)
        XCTAssertEqual(ready(enabled: false), .off)
        XCTAssertNil(ready(enabled: false).reason, "off is the default and needs no warning")
        XCTAssertEqual(ready(ax: false), .needsAccessibility)
        XCTAssertEqual(ready(control: false), .needsBrowserControl)
        XCTAssertEqual(ready(browser: nil), .unsupportedBrowser("Safari"))
        XCTAssertEqual(ready(method: .clipboard), .noPrefill)
        XCTAssertNotNil(ready(ax: false).reason)
    }

    func testPressesOnlyOnTheStartPageAfterTheQuestionWasTaken() {
        XCTAssertFalse(ChatGPTAutoSend.pageTookPrompt("https://chatgpt.com/?q=What%20is%20X"), "still loading the link")
        XCTAssertTrue(ChatGPTAutoSend.pageTookPrompt("https://chatgpt.com/"))
        XCTAssertFalse(ChatGPTAutoSend.pageTookPrompt("https://chatgpt.com/c/68ee1a2b-1234"), "already a conversation")
        XCTAssertFalse(ChatGPTAutoSend.pageTookPrompt("https://auth.openai.com/log-in"), "sign-in page")
        XCTAssertFalse(ChatGPTAutoSend.pageTookPrompt("https://example.com/"))
        let t = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(ChatGPTAutoSend.shouldPress(url: "https://chatgpt.com/", tookPromptAt: t, now: t.addingTimeInterval(0.5), pressed: false), "let the box fill first")
        XCTAssertTrue(ChatGPTAutoSend.shouldPress(url: "https://chatgpt.com/", tookPromptAt: t, now: t.addingTimeInterval(2), pressed: false))
        XCTAssertFalse(ChatGPTAutoSend.shouldPress(url: "https://chatgpt.com/", tookPromptAt: t, now: t.addingTimeInterval(2), pressed: true), "once only")
        XCTAssertFalse(ChatGPTAutoSend.shouldPress(url: "https://chatgpt.com/", tookPromptAt: nil, now: t, pressed: false))
    }
}

/// A spoken request that would leave the Mac waits for checking when the recogniser wasn't sure.
final class VoiceDestinationReviewTests: XCTestCase {
    func testDoubtfulChatGPTRequestsWaitForTheUser() {
        XCTAssertNotNil(TranscriptAssessment.checkBeforeSending(destination: .chatgpt, confidence: 0.78), "seen live: 0.78 for a garbled ChatGPT request")
        XCTAssertNil(TranscriptAssessment.checkBeforeSending(destination: .chatgpt, confidence: 0.95))
        XCTAssertNil(TranscriptAssessment.checkBeforeSending(destination: .chatgpt, confidence: nil), "no confidence reported: the words are shown and run")
        XCTAssertNil(TranscriptAssessment.checkBeforeSending(destination: .wren, confidence: 0.5), "a reminder stays on this Mac")
        XCTAssertNil(TranscriptAssessment.checkBeforeSending(destination: .localAI, confidence: 0.5))
    }
}
