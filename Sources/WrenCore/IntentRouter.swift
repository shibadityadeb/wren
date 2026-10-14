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

    public init(prompt: String, original: String, depth: HandoffDepth = .normal, kind: DelegationKind? = nil, target: Target?) {
        self.prompt = prompt; self.original = original; self.depth = depth; self.target = target
        self.kind = kind ?? (depth == .deep ? .thinking : .question)
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
        let subject = a.replacingOccurrences(of: #"^(?:remind me\s+)?(?:to|about|that)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        let lower = pending.lowercased()
        guard let trigger = ReminderCommand.triggers.first(where: { lower.hasPrefix($0) }) else { return nil }
        let schedule = String(pending.dropFirst(trigger.count)).trimmingCharacters(in: .whitespaces)
        return "remind me to \(subject) \(schedule)"
    }
}

/// Deterministic routing. The local model is only consulted afterwards, for `.capture` inputs that
/// look like commands, and its answer is checked against the user's own words.
public enum IntentRouter {
    public static func route(_ raw: String, now: Date, calendar: Calendar = .current, resolver: ContextResolver? = nil) -> Intent {
        let text = ReminderCommand.stripAddress(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .capture }
        if let saved = explicitCapture(text) { return .explicitCapture(saved) }
        if ReminderCommand.parse(text, now: now, calendar: calendar) != nil { return .reminder }
        if let ask = aiRequest(text) { return .askAI(ask) }
        let r = resolver ?? ContextResolver(calendar: calendar)
        if isQuestion(text), let q = ContextResolver.queryKind(text) { return .storedQuery(q) }
        if r.command(text, now: now) != nil { return .itemCommand }
        if let q = ContextResolver.queryKind(text), text.lowercased().firstMatch(of: /^(?:show|list|tell me|give me)\b/) != nil { return .storedQuery(q) }
        if isQuestion(text) { return .generalQuestion(AIRequest(prompt: questionPrompt(text), original: raw, target: nil)) }
        return .capture
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
            // what does ChatGPT say/think about X
            "^" + polite + #"what (?:does|would|do) (?:the\s+)?"# + a + #" (?:say|think|know) (?:about|of|on|regarding)\s+(.+)$"#,
            // ask/get/have/tell/use ChatGPT to/about/whether … ; check/consult with ChatGPT …
            "^" + polite + #"(?:go\s+(?:and\s+)?)?(?:ask|get|have|tell|use|query|prompt|consult|check(?:\s+(?:on|with|in))?|see\s+(?:on|with|in|if|what)|look\s+(?:it\s+)?up\s+(?:on|in|with)|search\s+(?:on|in|with)|find\s+out\s+(?:on|from|with)|run\s+(?:this\s+)?(?:by|past|through)|send\s+(?:this|that|it)?\s*to|let)\s+(?:the\s+|my\s+)?"# + a + #"(?:\s+account)?\b[\s,:]*(.+)$"#,
            // … on/with/via/using ChatGPT: "check what quantum physics is on chatgpt"
            "^" + polite + #"(.+?)\s+(?:on|with|via|using|through|from|in|by)\s+(?:the\s+|my\s+)?"# + a + #"[\s.?!]*$"#,
            // ChatGPT, explain X
            "^(?:the\\s+)?" + a + #"[\s,:]+(.+)$"#,
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
        // Earlier, fixed phrasings ("send this research question to GPT and …").
        if let h = HandoffRequest.detect(t) {
            let deep = h.depth == .deep || DelegationIntent.wantsDeepThinking(t)
            return AIRequest(prompt: sentence(h.task), original: text, depth: deep ? .deep : .normal, kind: DelegationIntent.kind(t), target: .chatgpt)
        }
        return nil
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
        s = s.replacingOccurrences(of: #"[\s,]+(?:for me|please)[\s.!?]*$"#, with: "", options: [.regularExpression, .caseInsensitive])
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
        return s.lowercased().firstMatch(of: /^(?:what|what's|whats|why|how|who|whom|whose|when|where|which|is|are|was|were|can|could|does|do|did|should|would|will|explain|define)\b/) != nil
    }

    static func startsLikeQuestion(_ s: String) -> Bool {
        s.lowercased().firstMatch(of: /^(?:what|what's|whats|why|how|who|whom|whose|when|where|which|is|are|was|were|can|could|does|do|did|should|would|will)\b/) != nil
    }

    public static func questionPromptPublic(_ s: String) -> String { questionPrompt(s) }

    static func questionPrompt(_ s: String) -> String {
        var q = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
        q = q.prefix(1).uppercased() + q.dropFirst()
        if q.lowercased().firstMatch(of: /^(?:explain|define|describe|tell)\b/) != nil { return q + "." }
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
        }
        return s.firstMatch(of: cues) != nil
    }
}
