import Foundation
import SwiftData

/// Portable, versioned export of everything the user created in Wren.
///
/// Format `wren-export`, version 1: one UTF-8 JSON document. Dates are ISO 8601 in UTC with
/// fractional seconds; `manifest.timeZone` is the Mac's zone at export time, needed to read
/// date-only deadlines as calendar days. IDs are UUIDs, so relationships (task → goal) can be
/// followed outside Wren. Documented in ARCHITECTURE.md §30.
public struct WrenExport: Codable, Equatable, Sendable {
    public static let format = "wren-export"
    public static let currentVersion = 1

    public struct Manifest: Codable, Equatable, Sendable {
        public var format: String
        public var formatVersion: Int
        public var exportedAt: Date
        public var appVersion: String
        public var schemaVersion: Int
        public var timeZone: String
        public var counts: [String: Int]
        public var includes: [String]
        public var excludes: [String]
    }

    public struct Event: Codable, Equatable, Sendable { public var at: Date; public var kind: String; public var note: String? }

    public struct Waiting: Codable, Equatable, Sendable {
        public var waitingOn: String?
        public var expectedResponse: String?
        public var waitingSince: Date?
        public var followUpAt: Date?
        public var followUpAcknowledgedAt: Date?
    }

    public struct Item: Codable, Equatable, Sendable {
        public var id: UUID
        public var originalText: String
        public var title: String
        public var details: String?
        public var kind: String
        public var status: String
        public var priority: String
        public var source: String
        public var createdAt: Date
        public var captureTimeZone: String
        public var deadline: Date?
        public var deadlineHasTime: Bool
        public var nextReminderAt: Date?
        public var lastReminderAt: Date?
        public var snoozeCount: Int
        public var postponementCount: Int
        public var deferredAt: Date?
        public var completedAt: Date?
        public var droppedAt: Date?
        public var archivedAt: Date?
        public var goalID: UUID?
        public var isMilestone: Bool
        public var waiting: Waiting?
        public var history: [Event]
    }

    public struct GoalRecord: Codable, Equatable, Sendable {
        public var id: UUID
        public var title: String
        public var originalText: String
        public var details: String?
        public var targetDate: Date?
        public var status: String
        public var progressMethod: String
        public var manualProgress: Double
        public var progressExplanation: String
        public var createdAt: Date
        public var updatedAt: Date
        public var lastProgressAt: Date?
        public var completedAt: Date?
        public var linkedItemIDs: [UUID]
        public var history: [Event]
    }

    public struct Observation: Codable, Equatable, Sendable {
        public var kind: String
        public var subjectID: String
        public var fingerprint: String
        public var state: String
        public var firstSeenAt: Date
        public var surfacedAt: Date?
        public var closedAt: Date?
    }

    public struct DailyRunRecord: Codable, Equatable, Sendable {
        public var day: String
        public var briefing: String
        public var briefingAt: Date?
        public var checkIn: String
        public var checkInAt: Date?
    }

    public struct Policy: Codable, Equatable, Sendable {
        public struct Denial: Codable, Equatable, Sendable { public var action: String; public var target: String; public var reason: String; public var at: Date }
        public var grantedPermissions: [String]
        public var standingRules: [String]
        public var declined: [Denial]
    }

    public struct AuditEntry: Codable, Equatable, Sendable {
        public var at: Date
        public var action: String
        public var category: String
        public var target: String
        public var origin: String
        public var authorization: String?
        public var status: String
        public var confirmationObtained: Bool
        public var detail: String?
    }

    public var manifest: Manifest
    public var items: [Item]
    public var goals: [GoalRecord]
    public var observations: [Observation]
    public var dailyRuns: [DailyRunRecord]
    public var policy: Policy
    public var activityLog: [AuditEntry]

    // MARK: Building

    @MainActor
    public static func make(from store: WrenStore, appVersion: String, now: Date, timeZone: TimeZone = .current) throws -> WrenExport {
        let ctx = store.context
        let commitments = try ctx.fetch(FetchDescriptor<Commitment>(sortBy: [SortDescriptor(\.createdAt)]))
        let goals = try ctx.fetch(FetchDescriptor<Goal>(sortBy: [SortDescriptor(\.createdAt)]))
        let insights = try ctx.fetch(FetchDescriptor<InsightRecord>(sortBy: [SortDescriptor(\.firstSeenAt)]))
        let runs = try ctx.fetch(FetchDescriptor<DailyRun>(sortBy: [SortDescriptor(\.day)]))
        let grants = try ctx.fetch(FetchDescriptor<PermissionGrantRecord>()).map(\.permission).sorted()
        let rules = try ctx.fetch(FetchDescriptor<StandingRuleRecord>()).map(\.kind).sorted()
        let denials = try ctx.fetch(FetchDescriptor<DenialRecord>(sortBy: [SortDescriptor(\.at)]))
        let audit = try ctx.fetch(FetchDescriptor<AuditRecord>(sortBy: [SortDescriptor(\.at)]))

        let items = commitments.map { c in
            Item(id: c.id, originalText: c.originalText, title: c.title, details: c.details, kind: c.kind.rawValue,
                 status: c.status.rawValue, priority: ["low", "normal", "high"][c.priority.rawValue], source: c.source.rawValue,
                 createdAt: c.createdAt, captureTimeZone: c.timeZoneID, deadline: c.deadline, deadlineHasTime: c.deadlineHasTime,
                 nextReminderAt: c.nextReminderAt, lastReminderAt: c.lastReminderAt, snoozeCount: c.snoozeCount,
                 postponementCount: c.postponementCount, deferredAt: c.deferredAt, completedAt: c.completedAt,
                 droppedAt: c.droppedAt, archivedAt: c.archivedAt, goalID: c.goal?.id, isMilestone: c.isMilestone,
                 waiting: (c.kind == .waiting || c.waitingOn != nil || c.followUpAt != nil)
                    ? Waiting(waitingOn: c.waitingOn, expectedResponse: c.expectedResponse, waitingSince: c.waitingSince,
                              followUpAt: c.followUpAt, followUpAcknowledgedAt: c.followUpAcknowledgedAt) : nil,
                 history: c.sortedEvents.map { Event(at: $0.at, kind: $0.kind.rawValue, note: $0.note) })
        }
        let goalRecords = goals.map { g in
            GoalRecord(id: g.id, title: g.title, originalText: g.originalText, details: g.details, targetDate: g.targetDate,
                       status: g.status.rawValue, progressMethod: g.method.rawValue, manualProgress: g.manualProgress,
                       progressExplanation: GoalProgressReport.of(g).explanation, createdAt: g.createdAt, updatedAt: g.updatedAt,
                       lastProgressAt: g.lastProgressAt, completedAt: g.completedAt,
                       linkedItemIDs: g.tasks.map(\.id).sorted { $0.uuidString < $1.uuidString },
                       history: g.sortedEvents.map { Event(at: $0.at, kind: $0.kind.rawValue, note: $0.note) })
        }
        let observations = insights.map {
            Observation(kind: $0.kindRaw, subjectID: $0.subjectID, fingerprint: $0.fingerprint, state: $0.state.rawValue,
                        firstSeenAt: $0.firstSeenAt, surfacedAt: $0.surfacedAt, closedAt: $0.closedAt)
        }
        let dailyRuns = runs.map { DailyRunRecord(day: $0.day, briefing: $0.briefing.rawValue, briefingAt: $0.briefingAt, checkIn: $0.checkIn.rawValue, checkInAt: $0.checkInAt) }
        let log = audit.map {
            AuditEntry(at: $0.at, action: $0.action, category: $0.category, target: $0.targetLabel, origin: $0.origin,
                       authorization: $0.authorization, status: $0.status.rawValue, confirmationObtained: $0.confirmationObtained, detail: $0.detail)
        }
        let manifest = Manifest(
            format: format, formatVersion: currentVersion, exportedAt: now, appVersion: appVersion, schemaVersion: WrenStore.schemaVersion,
            timeZone: timeZone.identifier,
            counts: ["items": items.count, "goals": goalRecords.count, "observations": observations.count,
                     "dailyRuns": dailyRuns.count, "activityLog": log.count,
                     "historyEvents": items.reduce(0) { $0 + $1.history.count } + goalRecords.reduce(0) { $0 + $1.history.count }],
            includes: ["Every item with its original wording, interpretation, dates, reminders, status and full history",
                       "Waiting details and follow-up history", "Goals, progress settings and linked items",
                       "Observations you dismissed or resolved", "Briefing and check-in records",
                       "Permissions, standing rules and things you declined", "Activity log (labels only)"],
            excludes: ["Passwords, API keys, tokens and credentials (Wren stores none in its database)",
                       "Local AI models and settings", "Preferences such as the shortcut and notification times",
                       "Internal caches and runtime state"])
        return WrenExport(manifest: manifest, items: items, goals: goalRecords, observations: observations, dailyRuns: dailyRuns,
                          policy: Policy(grantedPermissions: grants, standingRules: rules,
                                         declined: denials.map { .init(action: $0.action, target: $0.targetLabel, reason: $0.reason, at: $0.at) }),
                          activityLog: log)
    }

    // MARK: Encoding

    static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let f = Self.formatter()
        e.dateEncodingStrategy = .custom { d, enc in var c = enc.singleValueContainer(); try c.encode(f.string(from: d)) }
        return try e.encode(self)
    }

    public enum ExportError: Error, LocalizedError, Equatable {
        case notAnExport, unsupportedVersion(Int), destinationExists(String), writeFailed(String)
        public var errorDescription: String? {
            switch self {
            case .notAnExport: "This file isn't a Wren export."
            case let .unsupportedVersion(v): "This export uses format version \(v), which this version of Wren can't read."
            case let .destinationExists(p): "A file already exists at \(p). Choose another name."
            case let .writeFailed(r): "The export couldn't be written: \(r)"
            }
        }
    }

    /// Parses and validates an export (for tools, tests and future import).
    public static func decode(_ data: Data) throws -> WrenExport {
        let d = JSONDecoder()
        let f = formatter()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = f.date(from: s) else { throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)")) }
            return date
        }
        struct Header: Decodable { struct M: Decodable { var format: String; var formatVersion: Int }; var manifest: M }
        guard let h = try? d.decode(Header.self, from: data), h.manifest.format == format else { throw ExportError.notAnExport }
        guard h.manifest.formatVersion <= currentVersion else { throw ExportError.unsupportedVersion(h.manifest.formatVersion) }
        return try d.decode(WrenExport.self, from: data)
    }

    /// Writes atomically. Refuses to replace an existing file unless the user explicitly confirmed replacing it.
    public static func write(_ data: Data, to url: URL, replacingConfirmed: Bool) throws {
        if FileManager.default.fileExists(atPath: url.path), !replacingConfirmed { throw ExportError.destinationExists(url.lastPathComponent) }
        do { try data.write(to: url, options: [.atomic]) } catch { throw ExportError.writeFailed(error.localizedDescription) }
    }
}
