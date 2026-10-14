import Foundation

/// A request for an AI assistant to answer, explain, brainstorm, analyse or summarise something.
public struct AIRequest: Equatable, Sendable {
    /// What will be sent: the user's request without the "ask ChatGPT" framing, meaning unchanged.
    public var prompt: String
    /// Exactly what the user typed or said.
    public var original: String
    /// `.deep`: the user asked for careful thinking, so Wren asks for a higher reasoning effort.
    public var depth: HandoffDepth
    /// Question, deep thinking, or research (which may use web search when the account allows it).
    public var kind: DelegationKind
    /// Who the user addressed. nil: a general question with no assistant named.
    public var target: Target?
    public enum Target: String, Equatable, Sendable { case chatgpt }

    /// A follow-up to this earlier delegation ("continue that research").
    public var followUpOf: UUID?
    /// Forces where a ChatGPT request runs (a follow-up keeps its parent's tool). nil: the user's setting.
    public var mode: ChatGPTMode?

    public init(prompt: String, original: String, depth: HandoffDepth = .normal, kind: DelegationKind? = nil, target: Target?,
                followUpOf: UUID? = nil, mode: ChatGPTMode? = nil) {
        self.prompt = prompt; self.original = original; self.depth = depth; self.target = target
        self.kind = kind ?? (depth == .deep ? .thinking : .question)
        self.followUpOf = followUpOf; self.mode = mode
    }

    /// What to ask of the model: higher reasoning effort only when asked for, web search only for research.
    public var wantsHighEffort: Bool { depth == .deep }
    public var wantsWebSearch: Bool { kind == .research }
}

/// Reads, from the user's own words, whether a delegated request asks for deeper thinking or for
/// research that needs outside sources. Nothing is inferred from the topic.
public enum DelegationIntent {
    /// "think deeply/carefully", "high reasoning effort", "in depth", "investigate … carefully".
    /// "carefully" or "investigate" alone don't count ("carefully summarize this" is an ordinary request).
    public static func wantsDeepThinking(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.firstMatch(of: /\b(think(?:ing)? (?:deeply|hard|harder|carefully|it through)|deep(?:ly)? think\w*|deeper|in[ -]depth|deep analysis|thorough(?:ly)?|high(?:er)? reasoning(?: effort)?|reason (?:carefully|deeply)|maximum reasoning)\b/) != nil
            || lower.firstMatch(of: /\binvestigate(?:\s+\w+){0,4}\s+(?:carefully|thoroughly|deeply)\b/) != nil
    }

    /// "research …", "find sources", "with citations", "latest/current news", "search the web".
    public static func wantsResearch(_ text: String) -> Bool {
        text.lowercased().firstMatch(of: /\b(research(?:ing)?|find (?:me )?(?:sources|references|citations)|with (?:sources|citations|references)|cite (?:sources|your sources)|(?:latest|current|recent|today'?s) (?:news|developments|updates|research|papers|prices?)|search (?:the )?(?:web|internet|online)|look (?:it )?up online|browse the web|web search)\b/) != nil
    }

    public static func kind(_ text: String) -> DelegationKind {
        wantsResearch(text) ? .research : (wantsDeepThinking(text) ? .thinking : .question)
    }

    /// Phrases addressed to Wren about how to run the request, not part of the request itself.
    static func stripRunInstructions(_ s: String) -> String {
        s.replacingOccurrences(of: #"[\s,;.]*(?:and\s+)?(?:please\s+)?(?:use|with|at|using)\s+(?:a\s+)?(?:high|higher|maximum|max|deep)\s+(?:reasoning|thinking)(?:\s+effort)?(?:\s+mode)?[\s.!]*$"#,
                             with: "", options: [.regularExpression, .caseInsensitive])
    }
}

/// What an input to the capture panel (typed or spoken) is for. Decided before Wren shows any card
/// or does anything, so a card always matches the request.
public enum Intent: Equatable, Sendable {
    /// "Note: …", "save this: …": keep the text, don't act on it.
    case explicitCapture(String)
    /// "Remind me to …" (handled by `ReminderCommand`).
    case reminder
    /// Ask ChatGPT (or another named assistant) something.
    case askAI(AIRequest)
    /// Complete, move, snooze, drop or archive something already in Wren.
    case itemCommand
    /// A question about Wren's own data ("what am I waiting for?").
    case storedQuery(QueryKind)
    /// A question for an assistant that names none ("what is quantum physics?").
    case generalQuestion(AIRequest)
    /// Anything else: something to remember.
    case capture
}

/// Wren asked "When should I remind you…?". Only text that isn't its own explicit request may be the answer.
public enum ReminderFollowUp {
    public static func mayAnswer(_ text: String) -> Bool {
        let t = ReminderCommand.stripAddress(text)
        return IntentRouter.aiRequest(t) == nil && IntentRouter.explicitCapture(t) == nil
    }

    /// Wren asked "What should I remind you about?" for `pending` (which has the time, e.g.
    /// "Remind me every weekday at 3 PM"). The answer becomes the subject and the schedule is kept:
    /// "to stretch" → "remind me to stretch every weekday at 3 PM". An answer that brings its own
    /// date or schedule ("I need to send the invoice by Monday") is a new request, not this answer: nil.
    public static func subjectAnswer(_ answer: String, pending: String, now: Date, calendar: Calendar) -> String? {
        let a = ReminderCommand.stripAddress(answer).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
        guard !a.isEmpty, mayAnswer(a) else { return nil }
        guard DateParser(calendar: calendar).parse(a, now: now) == nil, RecurrenceRule.find(in: a, calendar: calendar) == nil else { return nil }
        // Its own request ("create a task to buy milk", "what's due?", "mark the report done") isn't a subject.
        guard !ExecutionRouter.hasTaskFraming(a), !IntentRouter.isQuestion(a),
              ContextResolver(calendar: calendar).command(a, now: now) == nil else { return nil }
        let subject = a.replacingOccurrences(of: #"^(?:remind me\s+)?(?:to|about|that)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        let lower = pending.lowercased()
        guard let trigger = ReminderCommand.triggers.first(where: { lower.hasPrefix($0) }) else { return nil }
        let schedule = String(pending.dropFirst(trigger.count)).trimmingCharacters(in: .whitespaces)
        return "remind me to \(subject) \(schedule)"
    }
}

/// Phrase readers used by `CommandRouter` (explicit notes, requests to ChatGPT, questions).
public enum IntentRouter {
    /// The older, coarser view of `CommandRouter.intent`, kept for callers that only need the kind.
    /// There is one router: this maps its decision and never decides differently.
    public static func route(_ raw: String, now: Date, calendar: Calendar = .current, resolver: ContextResolver? = nil) -> Intent {
        switch CommandRouter.intent(for: raw, now: now, calendar: calendar).operation {
        case let .saveNote(body): return .explicitCapture(body)
        case .createReminder: return .reminder
        case let .delegateToChatGPT(r): return .askAI(r)
        case .changeItem: return .itemCommand
        case let .queryStoredItems(q?): return .storedQuery(q)
        case let .generalQuestion(r): return .generalQuestion(r)
        case .searchGmail, .queryCalendar:
            let text = ReminderCommand.stripAddress(raw)
            return .generalQuestion(AIRequest(prompt: questionPrompt(text), original: raw, target: nil))
        default: return .capture
        }
    }

    // MARK: Explicit capture

    /// "note: …", "save this: …", "remember that …", "jot down …": the text to keep, without the prefix.
    public static func explicitCapture(_ text: String) -> String? {
        let pattern = #"^(?:please\s+)?(?:(?:save|note|capture|log|jot down|write down|keep)(?:\s+(?:this|that|a note|note))?\s*[:\-–]\s*|(?:make|add|take) a note(?: of| that)?\s+|remember that\s+|note that\s+|jot down\s+|write down\s+|save (?:this|that)(?: as a note)?\s*[:\-–]?\s+)(.+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        let body = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    // MARK: Asking an AI

    static let assistant = #"(?:chat\s*-?\s*gpt|gpt(?:\s*-?\s*\d+(?:\.\d+)?o?)?|open\s?ai)"#

    /// How speech recognition and quick typing spell the assistant's name, rewritten to "ChatGPT" or
    /// "GPT" before routing: "chat G P T", "Chat-GPT", "chat G.P.T.", "chat GBT", "Chad GPT", "G.P.T.".
    /// Only the name changes; the request itself is never rewritten.
    public static func normalizeAssistantName(_ text: String) -> String {
        var t = text
        let letters = #"g\.?\s*[pb]\.?\s*t\b\.?"#
        for (pattern, name) in [(#"\b(?:chat|chad|chet|chats|chap)\s*-?\s*"# + letters, "ChatGPT"),
                                (#"\bg\.\s*p\.\s*t\b\.?|\bg\s+p\s+t\b"#, "GPT")] {
            t = t.replacingOccurrences(of: pattern, with: name, options: [.regularExpression, .caseInsensitive])
        }
        return t
    }
    static let polite = #"^(?:(?:hey|hi|ok(?:ay)?|so|well|um+|hmm+)[\s,]+)*(?:(?:can|could|would|will) you(?: please)?|please|kindly|i (?:want|need|would like|'d like) you to|i want to|i'd like to|let's|help me)?\s*"#

    /// Finds a request addressed to ChatGPT/GPT, in many phrasings, and extracts what to send.
    /// "email the GPT team" doesn't count: the assistant has to be asked, checked with, used, etc.
    public static func aiRequest(_ text: String) -> AIRequest? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = assistant
        // "Research this topic using GPT: X" → "ask GPT to research X".
        if let m = t.firstMatch(of: try! Regex("^" + polite + #"(research|investigate|look into|analy[sz]e|explain|summari[sz]e|think (?:deeply |carefully |hard )?about)\s+(?:this|that|the following)?\s*(?:topic|question|idea|subject)?\s*(?:using|with|on|via|in|through)\s+(?:the\s+|my\s+)?"# + a + #"\s*[:,\-–]\s*(.+)$"#).ignoresCase()),
           let verb = m.output[1].substring, let rest = m.output[2].substring {
            t = "ask GPT to \(verb) \(rest)"
        }
        // Ordered from the most specific. Group 1 is always the request.
        let patterns: [String] = [
            // "make a query at ChatGPT? What is…", "make a query, ChatGPT what is…", "send a question to
            // GPT about…", "start a chat in ChatGPT on…": a request named as a thing to make, with
            // ChatGPT after it (by a preposition, punctuation or nothing), then what to ask.
            "^" + polite + #"(?:make|do|run|send|start|create|open|submit|put in|put|type|enter|write|give|post)\s+(?:me\s+)?(?:a\s+|an\s+|the\s+|this\s+|new\s+)*(?:query|question|request|search|prompt|chat|conversation|message)(?:\s+(?:at|to|in|on|with|for|into|through|via|using|from|of|over)\s+(?:the\s+|my\s+)?|\s*[,:;?.!\-–]+\s*|\s+)"# + a + #"\b[\s,:;?.!\-–]*(?:(?:about|on|for|regarding|asking|whether|if|that|and ask(?: it)?|to ask(?: it)?)\s+)?(.+)$"#,
            // what does ChatGPT say/think about X
            "^" + polite + #"what (?:does|would|do) (?:the\s+)?"# + a + #" (?:say|think|know) (?:about|of|on|regarding)\s+(.+)$"#,
            // ask/get/have/tell/use ChatGPT to/about/whether … ; check/consult with ChatGPT …
            "^" + polite + #"(?:go\s+(?:and\s+)?)?(?:ask|get|have|tell|use|query|prompt|consult|check(?:\s+(?:on|with|in))?|see\s+(?:on|with|in|if|what)|look\s+(?:it\s+)?up\s+(?:on|in|with)|search\s+(?:on|in|with)|find\s+out\s+(?:on|from|with)|run\s+(?:this\s+)?(?:by|past|through)|send\s+(?:this|that|it)?\s*to|let)\s+(?:the\s+|my\s+)?"# + a + #"(?:\s+account)?\b[\s,:]*(.+)$"#,
            // … on/with/via/using ChatGPT: "check what quantum physics is on chatgpt"
            "^" + polite + #"(.+?)\s+(?:on|with|via|using|through|from|in|by)\s+(?:the\s+|my\s+)?"# + a + #"[\s.?!]*$"#,
            // ChatGPT, explain X ("hey ChatGPT, …")
            "^(?:(?:hey|hi|ok(?:ay)?|so)[\\s,]+)?(?:the\\s+)?" + a + #"[\s,:]+(.+)$"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  let r = Range(m.range(at: 1), in: t) else { continue }
            var body = String(t[r])
            if p.hasPrefix("^" + polite + #"what (?:does|would"#) { body = "What can you tell me about " + body }
            // For the trailing "… on GPT" form, require an actual request verb or question in front.
            if p.contains(#"(.+?)\s+(?:on|with"#) {
                let lower = body.lowercased()
                guard lower.firstMatch(of: /^(?:check|look|search|find|see|ask|research|explain|summari[sz]e|analy[sz]e|brainstorm|what|why|how|who|when|where|which|is|are|can|does|do|should|tell)\b/) != nil
                else { continue }
                body = body.replacingOccurrences(of: #"^(?:check|look up|look|search|find out|find|see|ask)\s+(?:for\s+|up\s+)?"#, with: "", options: [.regularExpression, .caseInsensitive])
            }
            let prompt = cleanPrompt(DelegationIntent.stripRunInstructions(body))
            guard prompt.count >= 2 else { continue }
            let deep = DelegationIntent.wantsDeepThinking(t)
            return AIRequest(prompt: prompt, original: text, depth: deep ? .deep : .normal, kind: DelegationIntent.kind(t), target: .chatgpt)
        }
        // Any other sentence that names GPT as where the work should happen ("can you ask in GPT what …",
        // "make a query in ChatGPT about …"): it's for ChatGPT. Only the destination and the framing
        // around it are removed; the request itself is kept as said.
        if let r = destinationRequest(t) { return r }
        // Earlier, fixed phrasings ("send this research question to GPT and …").
        if let h = HandoffRequest.detect(t) {
            let deep = h.depth == .deep || DelegationIntent.wantsDeepThinking(t)
            return AIRequest(prompt: sentence(h.task), original: text, depth: deep ? .deep : .normal, kind: DelegationIntent.kind(t), target: .chatgpt)
        }
        return nil
    }

    /// GPT named as a destination anywhere: "… in/on/with/via/using/through GPT …", "query/prompt ChatGPT …".
    /// "email the GPT team" or "I compared GPT models" name it as a topic, not a destination: no match.
    static func destinationRequest(_ t: String) -> AIRequest? {
        let a = assistant
        let destination = #"\b(?:in|on|with|via|using|through|into)\s+(?:the\s+|my\s+)?"# + a + #"\b"#
        guard t.range(of: destination, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        var body = t.replacingOccurrences(of: #"[\s,]*"# + destination, with: "", options: [.regularExpression, .caseInsensitive])
        // The request framing left around it: "can you ask", "make a query about", "do a search for".
        // "Research" is the instruction itself ("research this in ChatGPT"), so it stays.
        body = body.replacingOccurrences(of: "^" + polite + #"(?:ask|query|prompt|search|look up|check|find out|make|do|run|start|create|open)?\s*(?:a\s+|an\s+|new\s+)*(?:query|search|question|request|chat|conversation|prompt)?\s*(?:about|on|for|regarding|whether|if|to|that)?[\s,:]*"#,
                                     with: "", options: [.regularExpression, .caseInsensitive])
        let prompt = cleanPrompt(body)
        guard prompt.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).count >= 3 else { return nil }
        let deep = DelegationIntent.wantsDeepThinking(t)
        return AIRequest(prompt: prompt, original: t, depth: deep ? .deep : .normal, kind: DelegationIntent.kind(t), target: .chatgpt)
    }

    /// Removes leftover framing ("to", "about", "what … is", "and tell me") without changing meaning.
    static func cleanPrompt(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // "whether X" / "if X" asks if X is true: keep it a question.
        var yesNo = false
        if let r = s.range(of: #"^(?:about\s+|to\s+)?(?:whether|if)\s+"#, options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(r); yesNo = true }
        let leading = #"^(?:to|about|for|on|and|that|regarding|re:?|please)\s+"#
        while let r = s.range(of: leading, options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(r) }
        // "… and let me know when it's finished": that's for Wren (it notifies on completion), not part of the query.
        s = s.replacingOccurrences(of: #"[\s,]+(?:and\s+)?(?:then\s+)?(?:tell|let|notify|ping|alert)\s+me(?:\s+know)?\s+(?:when|once|after)\s+(?:it\s*(?:'s|is|has)\s+|it'?s\s+|you'?re\s+|you\s+are\s+|that'?s\s+)?(?:done|finished|ready|complete|completed|back|through)[\s.!?]*$"#,
                                    with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"[\s,]+(?:and\s+)?(?:tell|let)\s+me(?:\s+know)?(?:\s+what\s+(?:it|they)\s+says?)?[\s.!?]*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        // "what quantum physics is" → "what is quantum physics" (an embedded question read back as a question).
        if let m = s.firstMatch(of: /^(?i)(what|who|where)\s+(.{2,80}?)\s+(is|are|was|were)[\s.?!]*$/) {
            s = "\(m.1) \(m.3) \(m.2)?"
        }
        s = s.replacingOccurrences(of: #"[\s,]+(?:for me|please|now|right now|immediately|right away)[\s.!?]*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:")))
        if yesNo { return "Is it true that " + s.trimmingCharacters(in: CharacterSet(charactersIn: "?.! ")) + "?" }
        // A request ("analyze this idea?") is an instruction even if typed with a question mark.
        if startsLikeQuestion(s) { return questionPrompt(s) }
        return sentence(s.trimmingCharacters(in: CharacterSet(charactersIn: "?")))
    }

    // MARK: Questions

    public static func isQuestion(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("?") { return true }
        return s.lowercased().firstMatch(of: /^(?:what|what's|whats|why|how|who|whom|whose|when|where|which|is|are|was|were|can|could|does|do|did|should|would|will|explain|define|describe|summari[sz]e|help me understand|teach me|tell me about)\b/) != nil
    }

    static func startsLikeQuestion(_ s: String) -> Bool {
        s.lowercased().firstMatch(of: /^(?:what|what's|whats|why|how|who|whom|whose|when|where|which|is|are|was|were|can|could|does|do|did|should|would|will)\b/) != nil
    }

    public static func questionPromptPublic(_ s: String) -> String { questionPrompt(s) }

    static func questionPrompt(_ s: String) -> String {
        var q = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
        q = q.prefix(1).uppercased() + q.dropFirst()
        if q.lowercased().firstMatch(of: /^(?:explain|define|describe|tell|summari[sz]e|help me|teach me)\b/) != nil { return q + "." }
        return q.hasSuffix("?") ? q : q + "?"
    }

    static func sentence(_ s: String) -> String {
        var q = s.prefix(1).uppercased() + s.dropFirst()
        if !(q.hasSuffix(".") || q.hasSuffix("?") || q.hasSuffix("!")) { q += "." }
        return q
    }

    /// Words a stored-data question of each kind must contain. A model's reading of the text as such
    /// a question is only used when the user's own words support it.
    public static func isGrounded(_ q: QueryKind, in text: String) -> Bool {
        let s = text.lowercased()
        let cues: Regex<AnyRegexOutput>
        switch q {
        case .waiting: cues = try! Regex(#"\b(waiting|wait for|expecting|hear back|heard back|reply|replies|respond|owe me)\b"#)
        case .recentPromises: cues = try! Regex(#"\b(promis\w*|commit\w*|said i'?d|agreed)\b"#)
        case .quietItems: cues = try! Regex(#"\b(quiet|stale|neglect\w*|forgot\w*|untouched|haven'?t touched)\b"#)
        case .postponed: cues = try! Regex(#"\b(postpon\w*|put off|putting off|delay\w*|keep moving|snooz\w*|pushed)\b"#)
        case .goalsNoProgress: cues = try! Regex(#"\bgoals?\b"#)
        case .overdue: cues = try! Regex(#"\b(overdue|late|missed|behind)\b"#)
        case .dueSoon: cues = try! Regex(#"\b(due|deadline\w*|coming up|upcoming|this week|soon)\b"#)
        case .doneRecently: cues = try! Regex(#"\b(done|finish\w*|complet\w*|accomplish\w*)\b"#)
        case .today: cues = try! Regex(#"\b(today|first|next|now|plate)\b"#)
        }
        return s.firstMatch(of: cues) != nil
    }
}
