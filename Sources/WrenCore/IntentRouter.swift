import Foundation

/// A request for an AI assistant to answer, explain, brainstorm, analyse or summarise something.
public struct AIRequest: Equatable, Sendable {
    /// What will be sent: the user's request without the "ask ChatGPT" framing, meaning unchanged.
    public var prompt: String
    /// Exactly what the user typed or said.
    public var original: String
    public var depth: HandoffDepth
    /// Who the user addressed. nil: a general question with no assistant named.
    public var target: Target?
    public enum Target: String, Equatable, Sendable { case chatgpt }

    public init(prompt: String, original: String, depth: HandoffDepth = .normal, target: Target?) {
        self.prompt = prompt; self.original = original; self.depth = depth; self.target = target
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
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = assistant
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
            let prompt = cleanPrompt(body)
            guard prompt.count >= 2 else { continue }
            let deep = t.lowercased().firstMatch(of: /\b(think (deeply|hard|carefully)|deeper|in depth|in-depth|deep analysis|thoroughly)\b/) != nil
            return AIRequest(prompt: prompt, original: text, depth: deep ? .deep : .normal, target: .chatgpt)
        }
        // Earlier, fixed phrasings ("send this research question to GPT and …").
        if let h = HandoffRequest.detect(t) { return AIRequest(prompt: sentence(h.task), original: text, depth: h.depth, target: .chatgpt) }
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
        s = s.replacingOccurrences(of: #"[\s,]+(?:and\s+)?(?:tell|let)\s+me(?:\s+know)?(?:\s+what\s+(?:it|they)\s+says?)?[\s.!?]*$"#, with: "", options: [.regularExpression, .caseInsensitive])
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
