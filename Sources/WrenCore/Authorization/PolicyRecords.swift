import Foundation
import SwiftData

/// Persisted permission grant. Absence means not granted.
@Model
public final class PermissionGrantRecord {
    @Attribute(.unique) public var permission: String
    public var grantedAt: Date
    public init(_ p: Permission, at: Date) { permission = p.rawValue; grantedAt = at }
}

/// Persisted standing rule. Absence means the rule is off.
@Model
public final class StandingRuleRecord {
    @Attribute(.unique) public var kind: String
    public var enabledAt: Date
    public init(_ k: StandingRuleKind, at: Date) { kind = k.rawValue; enabledAt = at }
}

/// A user's "no" to a specific action on a specific target.
@Model
public final class DenialRecord {
    @Attribute(.unique) public var key: String
    public var action: String
    public var targetLabel: String
    public var reason: String
    public var at: Date
    public init(key: String, action: String, targetLabel: String, reason: String, at: Date) {
        self.key = key; self.action = action; self.targetLabel = String(targetLabel.prefix(80)); self.reason = reason; self.at = at
    }
}

/// One line of "what Wren did and why". Holds identifiers and short labels only:
/// never message bodies, document text or full parameters.
@Model
public final class AuditRecord {
    public var id: UUID
    public var requestID: UUID
    public var at: Date
    public var action: String
    public var category: String
    public var targetKind: String
    public var targetID: String
    public var targetLabel: String
    public var origin: String
    public var authorization: String?
    var statusRaw: String
    var verificationRaw: String
    public var confirmationObtained: Bool
    public var dryRun: Bool
    /// Short outcome or reason, at most 200 characters.
    public var detail: String?

    init(request r: ActionRequest, descriptor d: ActionDescriptor?, at: Date) {
        id = UUID(); requestID = r.id; self.at = at
        action = r.action.rawValue; category = d?.category.rawValue ?? "unknown"
        targetKind = r.target.kind; targetID = r.target.id; targetLabel = r.target.label
        origin = r.origin.label; statusRaw = ExecutionStatus.proposed.rawValue
        verificationRaw = Verification.notRun.rawValue; confirmationObtained = false; dryRun = false
    }

    public var status: ExecutionStatus {
        get { ExecutionStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }
    public var verification: Verification {
        get { Verification(rawValue: verificationRaw) ?? .notRun }
        set { verificationRaw = newValue.rawValue }
    }
}

/// Persistence boundary for policy, so tests and the app can inject their own.
@MainActor
public protocol PolicyStoring: AnyObject {
    func load() throws -> PolicySnapshot
    func setGrant(_ p: Permission, granted: Bool) throws
    func setRule(_ k: StandingRuleKind, enabled: Bool) throws
    func recordDenial(_ r: ActionRequest, reason: String) throws
    func liftDenial(key: String) throws
    func denials() throws -> [DenialRecord]
}

@MainActor
public final class SwiftDataPolicyStore: PolicyStoring {
    let context: ModelContext
    let clock: WrenClock

    /// Seeds defaults the first time, once, so later revocations stick.
    public init(context: ModelContext, clock: WrenClock, defaults: UserDefaults? = nil) throws {
        self.context = context; self.clock = clock
        let seededKey = "policySeeded.v1"
        let alreadySeeded = (try? context.fetchCount(FetchDescriptor<PermissionGrantRecord>())) ?? 0 > 0
            || (try? context.fetchCount(FetchDescriptor<StandingRuleRecord>())) ?? 0 > 0
            || defaults?.bool(forKey: seededKey) == true
        if !alreadySeeded {
            for p in PolicySnapshot.defaultGrants { context.insert(PermissionGrantRecord(p, at: clock.now)) }
            for k in StandingRuleKind.defaults { context.insert(StandingRuleRecord(k, at: clock.now)) }
            try context.save()
            defaults?.set(true, forKey: seededKey)
        }
        // Protective rules are always present, even if an older store lacks them.
        for k in PolicySnapshot.protectedRules where try fetchRule(k) == nil {
            context.insert(StandingRuleRecord(k, at: clock.now))
        }
        try context.save()
    }

    public func load() throws -> PolicySnapshot {
        let grants = try context.fetch(FetchDescriptor<PermissionGrantRecord>()).map { Permission(rawValue: $0.permission) }
        let rules = try context.fetch(FetchDescriptor<StandingRuleRecord>()).compactMap { StandingRuleKind(rawValue: $0.kind) }
        let denials = try context.fetch(FetchDescriptor<DenialRecord>()).reduce(into: [String: String]()) { $0[$1.key] = $1.reason }
        return PolicySnapshot(grants: Set(grants), rules: Set(rules).union(PolicySnapshot.protectedRules), denials: denials)
    }

    public func setGrant(_ p: Permission, granted: Bool) throws {
        let raw = p.rawValue
        let existing = try context.fetch(FetchDescriptor<PermissionGrantRecord>(predicate: #Predicate { $0.permission == raw }))
        if granted, existing.isEmpty { context.insert(PermissionGrantRecord(p, at: clock.now)) }
        if !granted { existing.forEach(context.delete) }
        try context.save()
    }

    public func setRule(_ k: StandingRuleKind, enabled: Bool) throws {
        if !enabled, PolicySnapshot.protectedRules.contains(k) { throw PolicyError.cannotRevokeProtection(k) }
        let existing = try fetchRule(k)
        if enabled, existing == nil { context.insert(StandingRuleRecord(k, at: clock.now)) }
        if !enabled, let existing { context.delete(existing) }
        try context.save()
    }

    private func fetchRule(_ k: StandingRuleKind) throws -> StandingRuleRecord? {
        let raw = k.rawValue
        return try context.fetch(FetchDescriptor<StandingRuleRecord>(predicate: #Predicate { $0.kind == raw })).first
    }

    public func recordDenial(_ r: ActionRequest, reason: String) throws {
        let key = r.denialKey
        let existing = try context.fetch(FetchDescriptor<DenialRecord>(predicate: #Predicate { $0.key == key }))
        if existing.isEmpty {
            context.insert(DenialRecord(key: key, action: r.action.rawValue, targetLabel: r.target.label, reason: reason, at: clock.now))
            try context.save()
        }
    }

    public func liftDenial(key: String) throws {
        try context.fetch(FetchDescriptor<DenialRecord>(predicate: #Predicate { $0.key == key })).forEach(context.delete)
        try context.save()
    }

    public func denials() throws -> [DenialRecord] {
        try context.fetch(FetchDescriptor<DenialRecord>(sortBy: [SortDescriptor(\.at, order: .reverse)]))
    }
}
