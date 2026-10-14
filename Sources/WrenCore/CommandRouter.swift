import Foundation

/// Where an operation is carried out.
public enum CommandDestination: String, Sendable, Equatable {
    /// Wren's own items: tasks, reminders, notes, and questions about them.
    case wren
    /// The user's ChatGPT: the website, or their plan run inside Wren (their setting decides which).
    case chatgpt
    /// Wren's local model, on this Mac.
    case localAI
    case gmail
    case calendar
    /// Nothing runs until the user answers a question.
    case user
}

/// The rule that decided an input's operation. Logged (it never contains the user's words) and
/// asserted in tests. The letter is the routing rule it implements (docs/EXECUTION_AUDIT.md):
/// A tasks and reminders, B explicit ChatGPT, C questions for Wren, D email and calendar, E clarify.
public enum RoutingRule: String, Sendable, Equatable, CaseIterable {
    case empty
    case explicitNote
    case advanceReminder
    case reminderRequest
    case taskRequest
    case obligation
    case deadlineStatement
    case knowledgeRequest
    case delegationFollowUp
    case assistantRequest
    case assistantWithoutRequest
    case gptResult
    case emailAction
    case itemChange
    case storedQuery
    case emailQuestion
    case calendarQuestion
    case question
    case datedStatement
    case capture

    public var letter: String {
        switch self {
        case .advanceReminder, .reminderRequest, .taskRequest, .obligation, .deadlineStatement, .datedStatement, .itemChange: "A"
        case .delegationFollowUp, .assistantRequest, .gptResult: "B"
        case .storedQuery, .question, .knowledgeRequest: "C"
        case .emailAction, .emailQuestion, .calendarQuestion: "D"
        case .empty, .assistantWithoutRequest: "E"
        case .explicitNote, .capture: "-"
        }
    }
}

/// A task the user asked for, read from their own words: the title without the framing or the date
/// phrase, and the deadline exactly as written (nil when none was given; nothing is invented).
public struct TaskDraft: Equatable, Sendable {
    public var title: String
    public var deadline: ParsedDate?
    public init(title: String, deadline: ParsedDate?) { self.title = title; self.deadline = deadline }
}

/// One input, understood: the operation to run, where it runs, the rule that decided, and how sure
/// the rule is. The outer request decides the operation; what it carries ("ask GPT about …" inside
/// "remind me to …") is content and never changes the operation.
public struct CommandIntent: Equatable, Sendable {
    public var operation: ExecutionOperation
    public var destination: CommandDestination
    public var rule: RoutingRule
    /// 0…1. A rule matching the user's own framing is 0.9 or more; a fallback reading is lower.
    public var confidence: Double
    /// What the user asked Wren to do, without address or politeness ("make a reminder to call Sam tomorrow at 10 AM").
    public var request: String
    /// What the outer request carries ("call Sam tomorrow at 10 AM"; the question for ChatGPT; a task's subject).
    public var content: String
    /// Exactly what was typed or said.
    public var original: String

    /// Stable name for logs and tests: the operation (never the user's words).
    public var action: String { operation.name }
    /// For logs: operation, destination, rule and confidence. Contains no user text.
    public var summary: String { "\(operation.name) → \(destination.rawValue) (rule \(rule.letter) \(rule.rawValue), confidence \(String(format: "%.2f", confidence)))" }
}

/// The single router for every entry point: typed capture, the capture panel, voice transcripts,
/// notification replies and the debug command URL. Deterministic and testable: explicit rules over
/// the user's own words decide the tool. The local model is consulted only later, by the executor,
/// for inputs these rules leave as a plain capture, and its reading is checked against the words.
public enum CommandRouter {
    public static func intent(for raw: String, now: Date, calendar: Calendar = .current) -> CommandIntent {
        let stripped = ReminderCommand.stripAddress(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let request = CommandGrammar.request(stripped)
        func make(_ op: ExecutionOperation, _ d: CommandDestination, _ rule: RoutingRule, _ confidence: Double, content: String? = nil) -> CommandIntent {
            CommandIntent(operation: op, destination: d, rule: rule, confidence: confidence, request: request, content: content ?? request, original: raw)
        }
        guard !request.isEmpty else { return make(.clarifyIntent("What would you like Wren to do?"), .user, .empty, 1) }

        // "Note: …" keeps the text as it is, whatever it says.
        if let body = IntentRouter.explicitCapture(stripped) { return make(.saveNote(body), .wren, .explicitNote, 1, content: body) }

        // Rule A: reminders and tasks. The outer request is read first, so whatever the reminder or
        // task is about ("ask GPT about …", "email the recruiter") stays its subject.
        if let advance = CommandGrammar.advanceReminder(request) {
            return make(.changeItem(.remind), .wren, .advanceReminder, 0.9, content: advance.reference)
        }
        if let canonical = ReminderCommand.canonical(request) {
            return make(.createReminder, .wren, .reminderRequest, 0.95, content: canonical)
        }
        let parser = DateParser(calendar: calendar)
        if let frame = CommandGrammar.task(request, parser: parser, now: now) {
            switch frame {
            case let .task(content, rule):
                return make(.createTask(TaskDraft.from(content, now: now, parser: parser)), .wren, rule, rule == .taskRequest ? 0.95 : 0.9, content: content)
            case let .deadline(subject, date):
                return make(.createTask(TaskDraft(title: subject.capitalizedFirst, deadline: date)), .wren, .deadlineStatement, 0.85, content: subject)
            case let .knowledge(question):
                let prompt = IntentRouter.cleanPrompt(question)
                return make(.generalQuestion(AIRequest(prompt: IntentRouter.questionPrompt(prompt), original: raw, target: nil)), .localAI, .knowledgeRequest, 0.8, content: question)
            }
        }

        // Rule B: ChatGPT, when the user names it as who should do the work now.
        // Follow-ups first: "continue that research in ChatGPT" refers to an earlier request.
        if let f = DelegationFollowUp.detect(stripped) { return make(.followUpDelegation(f), .chatgpt, .delegationFollowUp, 0.9) }
        if let ask = IntentRouter.aiRequest(stripped) { return make(.delegateToChatGPT(ask), .chatgpt, .assistantRequest, 0.95, content: ask.prompt) }
        if ExecutionRouter.addressesAssistantWithoutRequest(stripped) {
            return make(.clarifyIntent("What should ChatGPT do? For example: “ask GPT to research the basics of quantum physics”."), .user, .assistantWithoutRequest, 1)
        }
        if ExecutionRouter.isDelegationResultRequest(request) { return make(.openDelegationResult, .chatgpt, .gptResult, 0.95) }

        // Rule D: a specific email action.
        if let sender = ExecutionRouter.emailAction(request, verb: #"mark"#) { return make(.markEmailRead(sender: sender.isEmpty ? nil : sender), .gmail, .emailAction, 0.95) }
        if let sender = ExecutionRouter.emailAction(request, verb: #"open|show|read|view"#) { return make(.openEmail(sender: sender.isEmpty ? nil : sender), .gmail, .emailAction, 0.95) }

        // Changes to existing items: complete, move, snooze, drop, archive.
        if let (cmd, _) = ContextResolver(calendar: calendar).command(stripped, now: now) {
            return make(.changeItem(cmd.verb), .wren, .itemChange, 0.9)
        }

        // Rules C and D: questions. Wren's own items, then Gmail and calendars, then general knowledge.
        let asks = IntentRouter.isQuestion(stripped) || IntentRouter.isQuestion(request) || CommandGrammar.isLookup(request)
        if let q = ContextResolver.queryKind(request), asks || request.lowercased().firstMatch(of: /^(?:show|list|tell me|give me)\b/) != nil {
            return make(.queryStoredItems(q), .wren, .storedQuery, 0.9)
        }
        if asks, EmailQuestion.isEmailQuestion(request) { return make(.searchGmail, .gmail, .emailQuestion, 0.85) }
        if asks, CalendarQuestion.isCalendarQuestion(request) { return make(.queryCalendar, .calendar, .calendarQuestion, 0.85) }
        if IntentRouter.isQuestion(stripped) || IntentRouter.isQuestion(request) {
            return make(.generalQuestion(AIRequest(prompt: IntentRouter.questionPrompt(stripped), original: raw, target: nil)), .localAI, .question, 0.8)
        }

        // A statement with a date in it is something to do by then ("dentist Friday 3 PM").
        let rules = IntentProcessor(client: nil, model: nil, calendar: calendar).rulesOnly(stripped, now: now)
        if rules.kind == .commitment {
            return make(.createTask(TaskDraft(title: rules.title, deadline: parser.parse(stripped, now: now))), .wren, .datedStatement, 0.75)
        }
        return make(.capture, .wren, .capture, 0.5)
    }
}

/// The grammar the router reads. Every pattern is anchored at the start of the request, so it is the
/// user's outer request that matches, never a phrase inside what they want done.
public enum CommandGrammar {
    /// Removes what is said to Wren about asking ("can you", "please", "I want you to", "hey") and
    /// keeps the request itself unchanged.
    public static func request(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers = [
            #"^(?:(?:hey|hi|ok(?:ay)?|so|well|um+|uh+|hmm+|actually|alright)[\s,]+)+"#,
            #"^(?:(?:can|could|would|will) you(?:\s+please)?|please|kindly|i (?:want|need|would like|'d like) you to|i'd like you to|go ahead and|do me a favou?r and)[\s,]+"#,
        ]
        var changed = true
        while changed {
            changed = false
            for w in wrappers {
                if let r = t.range(of: w, options: [.regularExpression, .caseInsensitive]), r.lowerBound == t.startIndex, r.upperBound < t.endIndex {
                    t.removeSubrange(r); changed = true
                }
            }
        }
        t = t.replacingOccurrences(of: #"[\s,]+please(?=[\s.!?]*$)"#, with: "", options: [.regularExpression, .caseInsensitive])
        return t.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "?!")))
    }

    /// "check …", "any …", "is there …": a lookup even without a question mark.
    static func isLookup(_ request: String) -> Bool {
        request.lowercased().firstMatch(of: /^(?:check|look|see|search|find|show|scan|any|anything|is there|are there|tell me)\b/) != nil
    }

    /// "remind me a day before the deadline", "remind me about the essay two days before it's due":
    /// an advance reminder on a task that already exists. The reference ("it" when none is named) and
    /// how many days before its deadline.
    static func advanceReminder(_ request: String) -> (reference: String, days: Int)? {
        let s = request.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        guard let m = s.firstMatch(of: /^(?:please\s+)?remind me\s+(?:about\s+(.+?)\s+|of\s+(.+?)\s+)?(?:the\s+|one\s+|a\s+)?(day|\d+\s+days?|two days|three days|a week|one week)\s+before\s+(?:the\s+deadline|its\s+deadline|the\s+due date|it'?s\s+due|it\s+is\s+due|that'?s\s+due|it)$/)
        else { return nil }
        let raw = String(m.3)
        let days: Int = raw == "day" ? 1 : raw == "two days" ? 2 : raw == "three days" ? 3 : raw.hasSuffix("week") ? 7 : Int(raw.prefix { $0.isNumber }) ?? 1
        return ((m.1 ?? m.2).map(String.init) ?? "it", days)
    }

    enum TaskFrame: Equatable {
        /// A task, with the words that describe it (date phrase still inside).
        case task(String, RoutingRule)
        /// "The essay is due Friday": subject and its deadline.
        case deadline(String, ParsedDate)
        /// "I need to know what X is": a question, not a task.
        case knowledge(String)
    }

    static func task(_ request: String, parser: DateParser, now: Date) -> TaskFrame? {
        func group(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let m = re.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)),
                  let r = Range(m.range(at: 1), in: request) else { return nil }
            let g = request[r].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
            return g.isEmpty ? nil : g
        }
        // "Create a task to …", "add a to-do: …", "make a task for …", "task: …", "add … to my list".
        if let c = group(#"^(?:create|add|make|new|set up|start|put|open|log)\s+(?:me\s+)?(?:a\s+|an\s+)?(?:new\s+)?(?:task|to-?do|todo item|to-?do item|action item)(?:\s+(?:item|entry))?(?:\s+(?:to|for|called|named|that says)|\s*[:\-–])?\s+(.+)$"#) {
            return .task(c.replacingOccurrences(of: #"^the\s+"#, with: "", options: [.regularExpression, .caseInsensitive]), .taskRequest)
        }
        if let c = group(#"^(?:task|todo|to-?do)\s*[:\-–]\s*(.+)$"#) { return .task(c, .taskRequest) }
        if let c = group(#"^add\s+(.+?)\s+to\s+(?:my\s+)?(?:task list|tasks|to-?do list|to-?dos|todo list|todos|list)$"#) { return .task(c, .taskRequest) }
        // First-person obligations: "I need to …", "I have to …", "I must …", "I've got to …".
        if let c = group(#"^(?:i|we)\s+(?:really\s+|still\s+|also\s+|definitely\s+)?(?:need to|have to|must|'ve got to|have got to|got to|gotta|should|ought to|am supposed to|'m supposed to|are supposed to|'ll need to|will need to|'ll have to|will have to|am going to have to|'m going to have to)\s+(.+)$"#) {
            // "I need to know what X is" asks for an answer; with a date it is still a task.
            if c.lowercased().firstMatch(of: /^(?:know|understand|figure out|find out|learn|work out)\s+(?:what|why|how|who|when|where|which|whether|if)\b/) != nil,
               parser.parse(c, now: now) == nil {
                return .knowledge(c.replacingOccurrences(of: #"^(?:know|understand|figure out|find out|learn|work out)\s+"#, with: "", options: [.regularExpression, .caseInsensitive]))
            }
            return .task(c, .obligation)
        }
        // Deadline statements: "the essay is due Friday", "deadline for the visa form is Monday".
        for p in [#"^(?:the\s+|my\s+|our\s+)?(.+?)\s+(?:is|are)\s+due\s+(.+)$"#, #"^(?:the\s+)?deadline\s+(?:for|of|on)\s+(?:the\s+|my\s+)?(.+?)\s+is\s+(.+)$"#,
                  #"^(?:the\s+|my\s+|our\s+)?(.+?)\s+due\s+(?:by\s+|on\s+)?(.+)$"#] {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)),
                  let a = Range(m.range(at: 1), in: request), let b = Range(m.range(at: 2), in: request) else { continue }
            let when = String(request[b]).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            // The whole rest must be the date ("due Friday"), not "due to the weather".
            guard let d = parser.parse(when, now: now), d.phrase.count >= when.count - 3 else { continue }
            return .deadline(String(request[a]), d)
        }
        return nil
    }
}

extension TaskDraft {
    /// Title and deadline from a task's words: "submit the assignment by Friday" → "Submit the assignment", Friday.
    static func from(_ content: String, now: Date, parser: DateParser) -> TaskDraft {
        let parsed = parser.parse(content, now: now)
        var title = content
        if let p = parsed {
            let pattern = #"(?:[\s,]+(?:by|on|before|due|at|until|for|no later than)\b)?\s*\b"# + NSRegularExpression.escapedPattern(for: p.phrase) + #"[.!]?"#
            let stripped = title.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",.")))
            if stripped.count >= 3 { title = stripped }
        }
        title = title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
        return TaskDraft(title: title.capitalizedFirst, deadline: parsed)
    }
}
