import Foundation

/// Typed standing rules. Deliberately a closed set: there is no free-text policy that
/// could be misread into something broader. Each has a fixed, documented scope.
public enum StandingRuleKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The scheduler may set and deliver reminders derived from your own deadlines.
    case autoRemindDeadlines
    /// The local model's reading of your own captures (type, title, date) is applied automatically.
    case autoApplyInterpretations
    /// Ask before deleting anything. Wren already confirms deletes; this rule cannot be weakened.
    case confirmBeforeDelete
    /// Never send email without showing the final draft (always confirm email sends).
    case showDraftBeforeSending
    /// Never send content marked private to an external AI service.
    case noPrivateDataToExternalAI
    /// The briefing may read connected Gmail and Calendar (read-only) on its own.
    case includeConnectedSourcesInBriefing
    /// While Wren runs, it may check connected Gmail for new inbox mail (read-only) for alerts and the digest.
    case monitorConnectedEmail

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .autoRemindDeadlines: "Automatically remind me about deadlines"
        case .autoApplyInterpretations: "Apply the local model's reading of my captures"
        case .confirmBeforeDelete: "Ask me before deleting anything"
        case .showDraftBeforeSending: "Never send an email without showing me the final draft"
        case .noPrivateDataToExternalAI: "Don't send private content outside this Mac unless I include it each time"
        case .includeConnectedSourcesInBriefing: "Let the briefing read connected Gmail and Calendar"
        case .monitorConnectedEmail: "Check connected Gmail for new mail while Wren runs (alerts and digest)"
        }
    }

    /// Rules that grant automation. Only these can allow something without the user present,
    /// and only for local, reversible actions.
    public var allowsActions: Set<ActionID> {
        switch self {
        case .autoRemindDeadlines: [BuiltInAction.scheduleReminder, BuiltInAction.deliverReminder, BuiltInAction.markReminderSummarized]
        case .autoApplyInterpretations: [BuiltInAction.applyInterpretation]
        case .includeConnectedSourcesInBriefing: [BuiltInAction.readEmail, BuiltInAction.readCalendar]
        case .monitorConnectedEmail: [BuiltInAction.readEmail]
        default: []
        }
    }

    /// Which of Wren's schedulers a rule speaks for (`ActionOrigin.system(label)`). nil: any. Rules that
    /// read external data are scoped, so turning off the briefing's rule stops the briefing even while
    /// the mail monitor's rule is on (and the other way round).
    public var systemScope: String? {
        switch self {
        case .includeConnectedSourcesInBriefing: "briefing"
        case .monitorConnectedEmail: "mail monitor"
        default: nil
        }
    }

    /// True when this rule lets `system` (the scheduler's label) perform `action` on its own.
    public func covers(_ action: ActionID, system: String) -> Bool {
        allowsActions.contains(action) && (systemScope == nil || systemScope == system)
    }

    /// Rules that only ever add restrictions.
    public var isRestrictive: Bool { allowsActions.isEmpty }

    /// Defaults for a new install. Automation that only touches Wren's own reminders is on;
    /// every restriction is on. All of them are visible and revocable in Settings.
    public static let defaults: Set<StandingRuleKind> = Set(allCases)
}

public enum PolicyError: Error, Equatable, LocalizedError {
    case cannotRevokeProtection(StandingRuleKind)
    public var errorDescription: String? {
        switch self {
        case let .cannotRevokeProtection(k): "“\(k.title)” protects you and can't be turned off."
        }
    }
}

/// Everything the Authorizer needs, as plain values. Persisted by PolicyStore.
public struct PolicySnapshot: Sendable, Equatable {
    public var grants: Set<Permission>
    public var rules: Set<StandingRuleKind>
    /// denialKey → reason. A denial persists until the user lifts it.
    public var denials: [String: String]

    public init(grants: Set<Permission>, rules: Set<StandingRuleKind>, denials: [String: String] = [:]) {
        self.grants = grants; self.rules = rules; self.denials = denials
    }

    /// Wren's own local capabilities only. External permissions are never granted by default.
    public static let defaultGrants: Set<Permission> = [.manageItems, .deleteItems, .reminders, .notify]
    public static let `default` = PolicySnapshot(grants: defaultGrants, rules: StandingRuleKind.defaults)

    /// Protective rules can't be removed: they only restate floors the Authorizer
    /// already enforces, and showing them as "off" would mislead.
    public static let protectedRules: Set<StandingRuleKind> = [.confirmBeforeDelete, .showDraftBeforeSending, .noPrivateDataToExternalAI]
}

/// A one-time approval for exactly one request (by fingerprint), short-lived.
public struct Confirmation: Sendable, Equatable {
    public let id: UUID
    public let fingerprint: String
    public let grantedAt: Date
    /// The user ticked "include private content" for exactly this request.
    public let includesPrivate: Bool
    public static let lifetime: TimeInterval = 5 * 60

    public init(for request: ActionRequest, at: Date, includingPrivate: Bool = false) {
        id = UUID(); fingerprint = request.fingerprint; grantedAt = at; includesPrivate = includingPrivate
    }
}

public enum AuthorizationDecision: Sendable, Equatable {
    case allow(AuthorizationSource)
    case needsConfirmation(String)
    case deny(String)
}

/// Pure decision function. Inputs: the request, what the action is, the policy, an
/// optional confirmation, and the time. No model, network or UI involved.
///
/// Things that are deliberately NOT inputs: model confidence, priority, urgency,
/// "recommended" flags, or any text from the request's content.
public enum Authorizer {
    public static func decide(_ r: ActionRequest, descriptor: ActionDescriptor?, policy: PolicySnapshot,
                              confirmation: Confirmation?, usedConfirmations: Set<UUID>, now: Date) -> AuthorizationDecision {
        guard let d = descriptor else { return .deny("Unknown action “\(r.action)”.") }
        guard d.id == r.action else { return .deny("Descriptor mismatch.") }

        // 1. Wren must hold the capability at all.
        guard policy.grants.contains(d.permission) else {
            return .deny("Wren doesn't have the “\(d.permission.rawValue)” permission.")
        }
        // 2. Hard restrictions from rules.
        // Private content leaves the Mac only with a confirmation that explicitly includes it.
        if (d.category == .externalWrite || d.category == .irreversible), r.containsPrivateContent,
           policy.rules.contains(.noPrivateDataToExternalAI), confirmation?.includesPrivate != true {
            return .deny("Private content can't be sent outside this Mac unless you explicitly include it for this request.")
        }
        // 3. Content Wren read can propose, never cause, consequential actions.
        if case .untrustedContent = r.origin, d.category != .localReversible && d.category != .externalRead {
            return .deny("Instructions found in \(r.origin.label) can't trigger a \(d.category.label.lowercased()) action.")
        }
        // 4. A denial stands until the user lifts it, however the request is rephrased.
        if let reason = policy.denials[r.denialKey], !r.origin.isDirectUser {
            return .deny("You declined this before: \(reason)")
        }

        // 5. A matching, fresh, unused confirmation authorizes exactly this request.
        if let c = confirmation {
            guard c.fingerprint == r.fingerprint else { return .deny("The confirmation was for a different action or target.") }
            guard !usedConfirmations.contains(c.id) else { return .deny("That confirmation was already used.") }
            guard now.timeIntervalSince(c.grantedAt) <= Confirmation.lifetime, now >= c.grantedAt else {
                return .deny("The confirmation expired. Please confirm again.")
            }
            return .allow(.userConfirmation(c.id))
        }

        // 6. Without a confirmation: who asked, and how strict is this action?
        var policyLevel = d.effectiveConfirmation
        if d.id == BuiltInAction.sendEmail, policy.rules.contains(.showDraftBeforeSending) { policyLevel = .always }

        switch r.origin {
        case let .user(channel):
            if policyLevel == .always { return .needsConfirmation(confirmationPrompt(d, r)) }
            return .allow(.directUserInstruction(channel))
        case let .system(label):
            guard d.category == .localReversible || d.category == .externalRead,
                  let rule = policy.rules.first(where: { $0.covers(d.id, system: label) }) else {
                return .deny("No standing rule lets Wren do “\(d.summary)” on its own.")
            }
            return .allow(.standingRule(rule))
        case .model:
            // The model may act only where a standing rule covers exactly this reversible local action.
            if d.category == .localReversible, let rule = policy.rules.first(where: { $0.allowsActions.contains(d.id) }) {
                return .allow(.standingRule(rule))
            }
            return .needsConfirmation(confirmationPrompt(d, r))
        case .untrustedContent, .conversational:
            return .needsConfirmation(confirmationPrompt(d, r))
        }
    }

    static func confirmationPrompt(_ d: ActionDescriptor, _ r: ActionRequest) -> String {
        switch r.origin {
        case .user, .conversational: "\(d.summary): “\(r.target.label)”"
        default: "\(d.summary): “\(r.target.label)” (suggested by \(r.origin.label))"
        }
    }
}
