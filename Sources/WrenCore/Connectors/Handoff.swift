import Foundation

/// Something that may be included as context in an external request.
public struct HandoffContextItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var source: String         // "Wren item", "Notion page", …
    public var title: String
    public var text: String
    public var isPrivate: Bool
    public init(id: String, source: String, title: String, text: String, isPrivate: Bool) {
        self.id = id; self.source = source; self.title = title; self.text = text; self.isPrivate = isPrivate
    }
}

public struct SensitiveFinding: Equatable, Sendable {
    public enum Kind: String, Sendable { case apiKey, privateKey, password, cardNumber, verificationCode }
    public var kind: Kind
    public var label: String { ["apiKey": "an API key or token", "privateKey": "a private key", "password": "a password",
                                "cardNumber": "a card number", "verificationCode": "a verification code"][kind.rawValue]! }
}

/// Finds obvious secrets so they can be left out of anything that leaves the Mac.
public enum SensitiveScanner {
    static let patterns: [(SensitiveFinding.Kind, String)] = [
        (.apiKey, #"\b(sk-[A-Za-z0-9_-]{16,}|ntn_[A-Za-z0-9]{20,}|secret_[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|xox[abp]-[A-Za-z0-9-]{10,})\b"#),
        (.privateKey, #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        (.password, #"(?i)\b(password|passwd|pwd|passcode)\s*[:=]\s*\S+"#),
        (.verificationCode, #"(?i)\b(code|otp|pin)\s*(is|:)?\s*\d{4,8}\b"#),
    ]

    public static func scan(_ text: String) -> [SensitiveFinding] {
        var out = patterns.compactMap { k, p in text.range(of: p, options: .regularExpression) != nil ? SensitiveFinding(kind: k) : nil }
        if !cardNumbers(text).isEmpty { out.append(SensitiveFinding(kind: .cardNumber)) }
        return out
    }

    public static func redact(_ text: String) -> String {
        var t = text
        for (_, p) in patterns { t = t.replacingOccurrences(of: p, with: "[removed]", options: .regularExpression) }
        for n in cardNumbers(t) { t = t.replacingOccurrences(of: n, with: "[removed]") }
        return t
    }

    /// 13–19 digit runs (spaces/dashes allowed) that pass the Luhn check.
    static func cardNumbers(_ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\b(?:\d[ -]?){12,18}\d\b"#) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            let s = String(text[Range(m.range, in: text)!])
            let digits = s.compactMap(\.wholeNumberValue)
            guard (13...19).contains(digits.count) else { return nil }
            let sum = digits.reversed().enumerated().reduce(0) { acc, e in
                let d = e.offset % 2 == 1 ? e.element * 2 : e.element
                return acc + (d > 9 ? d - 9 : d)
            }
            return sum % 10 == 0 ? s : nil
        }
    }
}

public enum HandoffDepth: String, Codable, Sendable { case normal, deep }

/// The prompt that will leave the Mac, built only from what the user approved.
public struct HandoffDraft: Equatable, Sendable {
    public var task: String
    public var depth: HandoffDepth
    public var context: [HandoffContextItem]
    /// Private items the user explicitly chose to include.
    public var includedPrivate: Set<String>
    /// Send detected secrets as written (otherwise they're replaced with "[removed]").
    public var includeSensitive: Bool

    public init(task: String, depth: HandoffDepth = .normal, context: [HandoffContextItem] = [],
                includedPrivate: Set<String> = [], includeSensitive: Bool = false) {
        self.task = task; self.depth = depth; self.context = context; self.includedPrivate = includedPrivate; self.includeSensitive = includeSensitive
    }

    public var includedContext: [HandoffContextItem] { context.filter { !$0.isPrivate || includedPrivate.contains($0.id) } }
    public var excludedContext: [HandoffContextItem] { context.filter { $0.isPrivate && !includedPrivate.contains($0.id) } }
    public var containsPrivate: Bool { privateOverride ?? (includedContext.contains { $0.isPrivate } || (includeSensitive && !findings.isEmpty)) }
    /// Set only by `exact`: whether the text being re-sent contained private content when the user approved it.
    var privateOverride: Bool?

    /// A prompt already sent once, re-sent exactly as it was (a retry): no redaction, no additions.
    public static func exact(_ prompt: String, depth: HandoffDepth, containsPrivate: Bool) -> HandoffDraft {
        var d = HandoffDraft(task: prompt, depth: .normal, includeSensitive: true)
        d.privateOverride = containsPrivate
        return d
    }
    public var findings: [SensitiveFinding] {
        let all = ([task] + includedContext.map(\.text)).joined(separator: "\n")
        var seen = Set<String>()
        return SensitiveScanner.scan(all).filter { seen.insert($0.kind.rawValue).inserted }
    }

    /// The exact text shown in the preview and copied.
    public var prompt: String {
        func clean(_ s: String) -> String { includeSensitive ? s : SensitiveScanner.redact(s) }
        var p = clean(task.trimmingCharacters(in: .whitespacesAndNewlines))
        if depth == .deep {
            p += "\n\nPlease think this through carefully before answering: consider several approaches, check your reasoning and point out uncertainties."
        }
        let ctx = includedContext
        if !ctx.isEmpty {
            p += "\n\nContext:"
            for c in ctx { p += "\n\n## \(c.title) (\(c.source))\n\(clean(String(c.text.prefix(4000))))" }
        }
        return p
    }
}

/// Recognises "ask ChatGPT to …" style requests. Deterministic.
public enum HandoffRequest {
    public struct Match: Equatable, Sendable { public var task: String; public var depth: HandoffDepth }

    public static func detect(_ text: String) -> Match? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"^(?:please\s+)?(?:ask|tell|have)\s+(?:chat\s?gpt|gpt|openai)\s+(?:to\s+)?(.+)$"#,
            #"^(?:please\s+)?send\s+(?:this|that|it)?\s*(.*?)\s*to\s+(?:chat\s?gpt|gpt)(?:\s+and\s+(.+))?$"#,
            #"^(?:please\s+)?use\s+my\s+chat\s?gpt(?:\s+account)?\s+to\s+(.+)$"#,
            #"^(?:please\s+)?prepare\s+a\s+prompt\s+for\s+(?:chat\s?gpt|gpt)\s+(?:to\s+)?(.+)$"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { continue }
            let groups = (1..<m.numberOfRanges).compactMap { i -> String? in
                guard let r = Range(m.range(at: i), in: t) else { return nil }
                let s = String(t[r]).trimmingCharacters(in: .whitespaces)
                return s.isEmpty ? nil : s
            }
            let task = groups.joined(separator: ": ")
            guard !task.isEmpty else { continue }
            let deep = t.lowercased().firstMatch(of: /\b(think (deeply|hard|carefully)|deeper|in depth|in-depth|deep analysis|thoroughly)\b/) != nil
            return Match(task: task.prefix(1).uppercased() + task.dropFirst(), depth: deep ? .deep : .normal)
        }
        return nil
    }

    /// Candidate follow-up tasks in an answer: short bullet or numbered lines.
    public static func followUps(in response: String, limit: Int = 8) -> [String] {
        response.split(separator: "\n").compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let m = line.firstMatch(of: /^(?:[-*•]|\d{1,2}[.)])\s+(.{6,140})$/) else { return nil }
            return String(m.1).replacingOccurrences(of: "**", with: "")
        }.prefix(limit).map { $0 }
    }
}
