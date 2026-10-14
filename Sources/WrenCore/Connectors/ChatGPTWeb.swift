import Foundation

/// Where an explicit "ask GPT" request runs.
///
/// - `web`: the ChatGPT website, in the user's own browser and account, so the work becomes a normal
///   ChatGPT conversation they can continue and find in their history. OpenAI documents no supported
///   way for an app to create a website conversation or learn its URL, so this is a *handoff*: Wren
///   prepares the prompt and opens ChatGPT; the user sends it there. Wren never claims it was sent or
///   finished, and only stores a conversation link the user gives it.
/// - `inWren`: "Run with connected ChatGPT in Wren": Sign in with ChatGPT plan usage through the
///   Responses API. Real streamed answer and completion, stored in Wren; it is not a ChatGPT website
///   conversation and doesn't appear in ChatGPT's history.
public enum ChatGPTMode: String, Codable, Sendable, CaseIterable {
    case web, inWren
    public var label: String {
        switch self {
        case .web: "Open in ChatGPT (website)"
        case .inWren: "Run with connected ChatGPT in Wren"
        }
    }
}

/// How the prompt reached the ChatGPT website.
public enum WebLaunchMethod: String, Codable, Sendable {
    /// Copied to the clipboard and chatgpt.com opened: the user pastes and sends.
    case clipboard
    /// `chatgpt.com/?q=…` (undocumented by OpenAI; opt-in after the user checked it in their browser).
    /// The prompt is also copied in case the page doesn't fill it in.
    case prefillLink
}

/// What Wren actually knows about a ChatGPT website handoff. There is no "completed": opening a
/// page, copying a prompt or the user saying "I sent it" doesn't tell Wren the work finished.
public enum WebHandoffState: String, Codable, Sendable {
    case prepared
    /// Opened with the prompt filled in by link: not confirmed sent.
    case openedInChatGPT
    /// Opened with the prompt on the clipboard: the user still has to paste and send it.
    case awaitingSubmission
    /// The user said they sent it. The answer is in ChatGPT; Wren can't see it.
    case submittedUnverified
    /// The user gave Wren the conversation's link; Open in ChatGPT goes straight to it.
    case conversationLinked
    case failedToOpen

    public var label: String {
        switch self {
        case .prepared: "Prepared"
        case .openedInChatGPT: "Opened in ChatGPT"
        case .awaitingSubmission: "Awaiting your submission"
        case .submittedUnverified: "Submitted; completion not verified"
        case .conversationLinked: "Conversation linked"
        case .failedToOpen: "Failed to open"
        }
    }

    public var detail: String {
        switch self {
        case .prepared: "Not opened yet."
        case .openedInChatGPT: "ChatGPT opened with your request filled in (experimental link). Wren can't see whether it was sent; check ChatGPT."
        case .awaitingSubmission: "Your request is on the clipboard. Paste it in ChatGPT and send it there."
        case .submittedUnverified: "You sent it in ChatGPT. The answer is in your ChatGPT conversation; Wren can't see it or tell when it's done."
        case .conversationLinked: "Open in ChatGPT goes straight to this conversation."
        case .failedToOpen: "Wren couldn't copy the request or open ChatGPT."
        }
    }
}

public enum ChatGPTWeb {
    public static let home = URL(string: "https://chatgpt.com/")!
    /// Longest prompt put in a `?q=` link; longer ones go by clipboard only.
    public static let maxPrefillCharacters = 1500

    /// The page to open for a prompt, and the method that page actually uses.
    public static func launch(_ prompt: String, prefill: Bool) -> (url: URL, method: WebLaunchMethod) {
        guard prefill, prompt.count <= maxPrefillCharacters, var c = URLComponents(url: home, resolvingAgainstBaseURL: false) else { return (home, .clipboard) }
        c.queryItems = [URLQueryItem(name: "q", value: prompt)]
        // `+` and `&` inside the prompt must survive as text.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return (c.url ?? home, c.url == nil ? .clipboard : .prefillLink)
    }

    /// A real ChatGPT conversation link the user gave Wren: `https://chatgpt.com/c/<id>`, a custom-GPT
    /// conversation `…/g/<gpt>/c/<id>`, or a shared conversation `…/share/<id>`. Anything else (another
    /// host, the home page, a project page) is refused, so Wren never stores a link that isn't one.
    public static func conversationURL(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 500, let c = URLComponents(string: text), c.scheme == "https",
              let host = c.host?.lowercased(), ["chatgpt.com", "www.chatgpt.com", "chat.openai.com"].contains(host),
              c.user == nil, c.password == nil, c.port == nil else { return nil }
        let id = #"[A-Za-z0-9][A-Za-z0-9-]{7,99}"#
        let path = c.path
        guard path.range(of: "^/c/\(id)/?$", options: .regularExpression) != nil
                || path.range(of: "^/g/[A-Za-z0-9-]{3,120}/c/\(id)/?$", options: .regularExpression) != nil
                || path.range(of: "^/share/\(id)/?$", options: .regularExpression) != nil else { return nil }
        var out = URLComponents()
        out.scheme = "https"; out.host = host == "chat.openai.com" ? "chatgpt.com" : host; out.path = path
        return out.url
    }

    /// What a follow-up sends when there's no linked conversation to continue: the earlier request,
    /// and the earlier answer when Wren has it, then the new instruction. Nothing else is attached.
    public static func followUpPrompt(earlierRequest: String, earlierAnswer: String?, instruction: String) -> String {
        var p = "Following up on my earlier request: “\(earlierRequest.trimmingCharacters(in: .whitespacesAndNewlines))”"
        if let a = earlierAnswer?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty {
            let shortened = a.count > 6000 ? String(a.prefix(6000)) + " […]" : a
            p += "\n\nThe answer I got:\n\(shortened)"
        }
        return p + "\n\n" + instruction
    }
}

/// "Continue that research", "ask it to go deeper", "find more sources", "open that in GPT": a
/// follow-up to an earlier delegation, keeping its tool. Detected from the user's words; which record
/// it refers to is decided by the app (the most recent one, or the one on screen).
public struct DelegationFollowUp: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Open the earlier request where it lives (its ChatGPT conversation, or its result in Wren).
        case open
        /// Ask for more on the earlier request.
        case `continue`(instruction: String)
    }
    public var action: Action
    /// The user named GPT/ChatGPT ("… in ChatGPT"): the website handoff, never the local model.
    public var namesChatGPT: Bool

    static let reference = #"(?:that|this|it|the (?:last|previous|latest|earlier) (?:one|query|request|question|research|answer|result)|the (?:query|request|research|conversation|chat|answer|result))"#

    public static func detect(_ raw: String) -> DelegationFollowUp? {
        let text = ReminderCommand.stripAddress(raw).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
        let lower = text.lowercased()
        let names = lower.range(of: #"\b(?:chat\s*-?\s*gpt|gpt)\b"#, options: .regularExpression) != nil
        let core = lower.replacingOccurrences(of: #"\s+(?:in|on|with|using|via|to)\s+(?:the\s+)?(?:chat\s*-?\s*gpt|gpt)\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^(?:please\s+|can you\s+|could you\s+)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // Open: "open that (query) in GPT", "show me that conversation in ChatGPT".
        if core.range(of: "^(?:open|show(?: me)?|go to|take me to|bring up)\\s+\(reference)(?:\\s+(?:query|request|research|conversation|chat))?$", options: .regularExpression) != nil,
           names || core.contains("conversation") || core.contains("chat") {
            return DelegationFollowUp(action: .open, namesChatGPT: names)
        }
        // Continue: "continue that research", "continue researching this", "keep going on it".
        if core.range(of: "^(?:continue|keep going|carry on|go on|resume)(?:\\s+(?:with|on|researching|working on|the))?(?:\\s+\(reference))?(?:\\s+(?:research|query|request|conversation|chat))?$", options: .regularExpression) != nil {
            return DelegationFollowUp(action: .continue(instruction: "Please continue this research and go further."), namesChatGPT: names)
        }
        // "ask it to go deeper", "tell it to find more sources". ("Ask GPT to …" is a new request.)
        if let m = core.firstMatch(of: /^(?:ask|tell|have|get) (?:it|them) to (.+)$/) {
            return DelegationFollowUp(action: .continue(instruction: sentence(String(m.1))), namesChatGPT: names)
        }
        // Bare follow-up asks: "go deeper", "find more sources", "dig deeper into that", "expand on that".
        if core.range(of: #"^(?:go|dig|look) deeper\b|^(?:find|get|give me|add) (?:more|other|additional|better) (?:sources|references|citations|examples|detail|details)\b|^(?:expand|elaborate) on (?:that|this|it)\b"#, options: .regularExpression) != nil {
            return DelegationFollowUp(action: .continue(instruction: sentence(core)), namesChatGPT: names)
        }
        return nil
    }

    static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".!?")))
        return t.prefix(1).uppercased() + t.dropFirst() + "."
    }
}
