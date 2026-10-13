import Foundation

/// The operations Wren can execute from words. Typed text, the capture panel, a voice transcript
/// and the debug command URL all go through `ExecutionRouter.operation`, so the same words always
/// lead to the same operation. Each operation runs behind its own connector or local subsystem and
/// that subsystem's permission checks; nothing here grants a permission.
public enum ExecutionOperation: Equatable, Sendable {
    /// Something to do, with a date or task framing ("I need to finish the report by Friday").
    case createTask
    /// "Remind me to … at …", "remind me every weekday at 3 PM to …".
    case createReminder
    /// A question about Wren's own items ("what am I waiting for?").
    case queryStoredItems(QueryKind?)
    /// Change an existing item: complete, move, snooze, drop ("move the research task to Sunday").
    case changeItem
    /// An explicit request to ChatGPT ("ask GPT to research …").
    case delegateToChatGPT(AIRequest)
    /// A question answered from Gmail ("do I have an important email from the recruiter?").
    case searchGmail
    /// Open a specific email in Wren ("open the latest email from Sam").
    case openEmail(sender: String?)
    /// Mark an email read in Gmail (needs the separate Gmail permission and a confirmation).
    case markEmailRead(sender: String?)
    /// A question answered from connected calendars.
    case queryCalendar
    /// Show a GPT result ("show the GPT result", "open the last ChatGPT answer").
    case openDelegationResult
    /// "Note: …": keep the text without acting on it.
    case saveNote(String)
    /// A question that names no assistant; the user chooses who answers.
    case generalQuestion(AIRequest)
    /// Something to remember, with nothing to execute.
    case capture
    /// Too unclear to act on safely; Wren asks this question instead of guessing.
    case clarifyIntent(String)

    /// Stable name for logs, results and tests (never contains the user's words).
    public var name: String {
        switch self {
        case .createTask: "CreateTask"
        case .createReminder: "CreateReminder"
        case .queryStoredItems: "QueryStoredItems"
        case .changeItem: "ChangeItem"
        case .delegateToChatGPT: "DelegateToChatGPT"
        case .searchGmail: "SearchGmail"
        case .openEmail: "OpenEmail"
        case .markEmailRead: "MarkEmailRead"
        case .queryCalendar: "QueryCalendar"
        case .openDelegationResult: "OpenDelegationResult"
        case .saveNote: "SaveNote"
        case .generalQuestion: "GeneralQuestion"
        case .capture: "Capture"
        case .clarifyIntent: "ClarifyIntent"
        }
    }
}

/// What an executed operation did. Every entry point records one, so success is never assumed.
public struct ExecutionResult: Equatable, Sendable {
    public var operation: String
    public var succeeded: Bool
    /// The item, reminder, delegation or message the operation created or acted on, when there is one.
    public var entityID: String?
    /// What went wrong, in words the user can act on. nil when it succeeded.
    public var error: String?
    /// The operation is waiting on the user (a confirmation, a choice, a clarification).
    public var needsUser: Bool
    public var at: Date

    public init(operation: String, succeeded: Bool, entityID: String? = nil, error: String? = nil, needsUser: Bool = false, at: Date) {
        self.operation = operation; self.succeeded = succeeded; self.entityID = entityID; self.error = error; self.needsUser = needsUser; self.at = at
    }
}

public enum ExecutionRouter {
    public static func operation(for raw: String, now: Date, calendar: Calendar = .current, resolver: ContextResolver? = nil) -> ExecutionOperation {
        let text = ReminderCommand.stripAddress(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .clarifyIntent("What would you like Wren to do?") }
        if let body = IntentRouter.explicitCapture(text) { return .saveNote(body) }
        if ReminderCommand.parse(text, now: now, calendar: calendar) != nil { return .createReminder }
        if let ask = IntentRouter.aiRequest(text) { return .delegateToChatGPT(ask) }
        // "Ask GPT." with nothing to ask: don't send an empty request or save it as a note.
        if addressesAssistantWithoutRequest(text) { return .clarifyIntent("What should ChatGPT do? For example: “ask GPT to research the basics of quantum physics”.") }
        if isDelegationResultRequest(text) { return .openDelegationResult }
        if let sender = emailAction(text, verb: #"mark"#) { return .markEmailRead(sender: sender.isEmpty ? nil : sender) }
        if let sender = emailAction(text, verb: #"open|show|read|view"#) { return .openEmail(sender: sender.isEmpty ? nil : sender) }
        switch IntentRouter.route(text, now: now, calendar: calendar, resolver: resolver) {
        case let .explicitCapture(body): return .saveNote(body)
        case .reminder: return .createReminder
        case let .askAI(r): return .delegateToChatGPT(r)
        case .itemCommand: return .changeItem
        case let .storedQuery(q): return .queryStoredItems(q)
        case let .generalQuestion(r):
            if EmailQuestion.isEmailQuestion(text) { return .searchGmail }
            if CalendarQuestion.isCalendarQuestion(text) { return .queryCalendar }
            return .generalQuestion(r)
        case .capture:
            if EmailQuestion.isEmailQuestion(text) { return .searchGmail }
            if CalendarQuestion.isCalendarQuestion(text) { return .queryCalendar }
            if IntentProcessor(client: nil, model: nil, calendar: calendar).rulesOnly(text, now: now).kind == .commitment || hasTaskFraming(text) { return .createTask }
            return .capture
        }
    }

    static func addressesAssistantWithoutRequest(_ text: String) -> Bool {
        text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!?")).firstMatch(of: /^(?:please\s+)?(?:ask|tell|use|check with|consult)\s+(?:the\s+)?(?:chat\s*-?\s*gpt|gpt|open\s?ai)$/) != nil
    }

    /// "show the GPT result", "open the last ChatGPT answer", "what did GPT say?".
    static func isDelegationResultRequest(_ text: String) -> Bool {
        let s = text.lowercased()
        return s.firstMatch(of: /^(?:please\s+)?(?:show|open|view|read)\s+(?:me\s+)?(?:the\s+|my\s+)?(?:last\s+|latest\s+|most recent\s+)?(?:chat\s*-?\s*gpt|gpt)\s+(?:result|answer|response|reply)s?\b/) != nil
            || s.firstMatch(of: /^what did (?:chat\s*-?\s*gpt|gpt) (?:say|answer|reply|come back with)\b/) != nil
    }

    /// "open the latest email from Sam" → "sam"; "mark the email from the bank as read" → "the bank".
    /// "" when no sender is named; nil when the words aren't that action on an email.
    static func emailAction(_ text: String, verb: String) -> String? {
        let pattern = #"^(?:please\s+)?(?:"# + verb + #")\s+(?:the\s+|my\s+|that\s+)?(?:last\s+|latest\s+|newest\s+|most recent\s+|new\s+)?(?:e-?mail|message|mail)(?:\s+from\s+(?:the\s+|my\s+)?(.+?))?(?:\s+as\s+read)?(?:\s+in\s+gmail)?[\s.!?]*$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        if verb.contains("mark"), text.range(of: #"\bas\s+read\b"#, options: [.regularExpression, .caseInsensitive]) == nil { return nil }
        guard let r = Range(m.range(at: 1), in: text) else { return "" }
        return text[r].trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func hasTaskFraming(_ text: String) -> Bool {
        text.lowercased().firstMatch(of: /^(?:create|add|make|new)\s+(?:a\s+)?(?:task|to-?do)\b|^(?:task|todo|to do)\s*:/) != nil
    }
}

/// Stops the same submission from running twice: a repeated Return, a voice event delivered again,
/// a notification action clicked twice. Keyed by channel and normalized text.
public struct SubmissionGuard: Sendable {
    public var window: TimeInterval
    var inFlight: Set<String> = []
    var finished: [String: Date] = [:]

    public init(window: TimeInterval = 3) { self.window = window }

    public static func key(_ text: String, channel: String) -> String {
        channel + "|" + text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// true: go ahead. false: the same thing is running, or just ran.
    public mutating func begin(_ key: String, now: Date) -> Bool {
        finished = finished.filter { now.timeIntervalSince($0.value) < window }
        guard !inFlight.contains(key), finished[key] == nil else { return false }
        inFlight.insert(key)
        return true
    }

    public mutating func end(_ key: String, now: Date) {
        inFlight.remove(key)
        finished[key] = now
    }
}
