import CryptoKit
import Foundation

/// How dangerous an action is. Drives the baseline confirmation policy.
public enum ActionCategory: String, Codable, Sendable, CaseIterable {
    /// Changes Wren's own data and can be undone (complete → reopen, snooze, schedule a reminder).
    case localReversible
    /// Removes Wren's own data (delete an item).
    case localDestructive
    /// Reads data outside Wren (email, calendar, files). Nothing is changed.
    case externalRead
    /// Changes something outside Wren (archive an email, create an event).
    case externalWrite
    /// Cannot be taken back or has serious consequences (send a message, permanent delete, payment).
    case irreversible

    public var label: String {
        switch self {
        case .localReversible: "Local, reversible"
        case .localDestructive: "Local, destructive"
        case .externalRead: "External read"
        case .externalWrite: "External write"
        case .irreversible: "Irreversible or high-impact"
        }
    }
}

/// A capability Wren holds. Grants are explicit, persisted and revocable.
public struct Permission: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral v: String) { rawValue = v }

    public static let manageItems: Permission = "local.items.modify"
    public static let deleteItems: Permission = "local.items.delete"
    public static let reminders: Permission = "local.reminders"
    public static let notify: Permission = "local.notifications"
    // Reserved for later phases. Never granted by default.
    public static let emailRead: Permission = "external.email.read"
    public static let emailModify: Permission = "external.email.modify"
    public static let emailSend: Permission = "external.email.send"
    public static let externalAI: Permission = "external.ai.delegate"
}

public enum ConfirmationPolicy: String, Codable, Sendable, Comparable {
    /// No extra prompt when otherwise authorized.
    case none
    /// Confirm unless the user directly asked for exactly this.
    case unlessDirect
    /// Always show the exact action and target and ask.
    case always

    var rank: Int { switch self { case .none: 0; case .unlessDirect: 1; case .always: 2 } }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

public struct ActionID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral v: String) { rawValue = v }
    public var description: String { rawValue }
}

/// Static facts about an action type, declared by whoever implements it.
public struct ActionDescriptor: Sendable {
    public var id: ActionID
    public var category: ActionCategory
    public var permission: Permission
    public var confirmation: ConfirmationPolicy
    public var summary: String
    /// How success is checked after execution.
    public var verification: String

    public init(id: ActionID, category: ActionCategory, permission: Permission, confirmation: ConfirmationPolicy,
                summary: String, verification: String) {
        self.id = id; self.category = category; self.permission = permission
        self.confirmation = confirmation; self.summary = summary; self.verification = verification
    }

    /// Baseline from the category. A descriptor or rule can make this stricter, never looser.
    public var effectiveConfirmation: ConfirmationPolicy {
        let floor: ConfirmationPolicy = switch category {
        case .localReversible, .externalRead: .none
        case .localDestructive, .externalWrite, .irreversible: .always
        }
        return max(floor, confirmation)
    }
}

/// Where a Wren input surface the user operates directly.
public enum UserChannel: String, Codable, Sendable {
    case hotkey, popover, notificationAction, settings, checkIn, briefing
    /// A spoken command ("Hey Wren" or the voice shortcut), transcribed on this Mac.
    case voice
}

/// Who proposed the action. Origins are set by Wren code paths, never parsed from text.
public enum ActionOrigin: Codable, Sendable, Equatable {
    /// The user operated a Wren control (button, notification action, own typed capture).
    case user(UserChannel)
    /// Wren's scheduler acting under a standing rule or built-in grant.
    case system(String)
    /// A language model suggested it.
    case model(String)
    /// Derived from content Wren read: an email, web page, document, or tool output.
    case untrustedContent(String)
    /// Wren's reading of something the user typed ("move that to Sunday"). The target and
    /// change were inferred, so the user must see and confirm them: this origin never runs
    /// without a confirmation, even where a standing rule would allow the action.
    case conversational(String)

    public var label: String {
        switch self {
        case let .user(c): "you (\(c.rawValue))"
        case let .system(s): "Wren scheduler (\(s))"
        case let .model(m): "model \(m)"
        case let .untrustedContent(s): "content from \(s)"
        case let .conversational(s): "your request “\(s.prefix(60))”"
        }
    }
    var isDirectUser: Bool { if case .user = self { true } else { false } }
}

/// What made an allowed action legitimate. Computed by the Authorizer; there is no
/// public way to attach one to a request.
public enum AuthorizationSource: Codable, Sendable, Equatable {
    case directUserInstruction(UserChannel)
    case standingRule(StandingRuleKind)
    case userConfirmation(UUID)

    public var label: String {
        switch self {
        case let .directUserInstruction(c): "your instruction (\(c.rawValue))"
        case let .standingRule(k): "standing rule: \(k.title)"
        case .userConfirmation: "your confirmation"
        }
    }
}

public struct TargetRef: Codable, Sendable, Hashable {
    public var kind: String
    public var id: String
    /// Short human label for review screens and the audit log (truncated).
    public var label: String
    public init(kind: String, id: String, label: String) {
        self.kind = kind; self.id = id; self.label = String(label.prefix(80))
    }
}

/// A proposed action. Note: no authorization field. Authorization is decided by the
/// Authorizer from origin, grants, rules and confirmations, so a model or a piece of
/// content cannot claim it.
public struct ActionRequest: Sendable, Identifiable {
    public let id: UUID
    public let action: ActionID
    public let target: TargetRef
    public let parameters: [String: JSONValue]
    public let origin: ActionOrigin
    public let createdAt: Date
    /// Content flagged private by the user (for the external-AI rule).
    public let containsPrivateContent: Bool

    public init(action: ActionID, target: TargetRef, parameters: [String: JSONValue] = [:], origin: ActionOrigin,
                createdAt: Date, containsPrivateContent: Bool = false) {
        id = UUID(); self.action = action; self.target = target; self.parameters = parameters
        self.origin = origin; self.createdAt = createdAt; self.containsPrivateContent = containsPrivateContent
    }

    /// Identifies "this action on this target with these parameters", for binding confirmations.
    public var fingerprint: String {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let params = (try? enc.encode(parameters)) ?? Data()
        var h = SHA256()
        h.update(data: Data("\(action.rawValue)|\(target.kind)|\(target.id)|".utf8))
        h.update(data: params)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// "This action on this target", ignoring parameters. Denials bind here so a
    /// rephrased retry (different parameters) stays denied.
    public var denialKey: String { "\(action.rawValue)|\(target.kind)|\(target.id)" }
}

public enum ExecutionStatus: String, Codable, Sendable {
    case proposed, awaitingConfirmation, denied, executing, succeeded, failed, unverified, dryRun
}

public enum Verification: String, Codable, Sendable {
    case verified, mismatch, notVerifiable, notRun
}
