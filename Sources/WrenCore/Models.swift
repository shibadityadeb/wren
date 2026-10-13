import Foundation
import SwiftData

/// Lifecycle of a commitment. Only `pending` items can produce reminders.
public enum CommitmentStatus: String, Codable, CaseIterable, Sendable {
    /// `archived`: put away by the user (review, conversion to a goal). Reversible with reopen.
    case pending, completed, dropped, archived
}

/// What kind of thing the user captured. Only `.commitment` gets reminders.
/// `.unsorted` means nobody (model or user) has classified it yet.
public enum CaptureKind: String, Codable, CaseIterable, Sendable {
    case commitment, idea, question, waiting, research, goal, unsorted

    public var label: String {
        switch self {
        case .commitment: "Commitment"
        case .idea: "Idea"
        case .question: "Question"
        case .waiting: "Waiting on"
        case .research: "Research"
        case .goal: "Goal idea"
        case .unsorted: "Unsorted"
        }
    }
}

public enum Priority: Int, Codable, CaseIterable, Sendable, Comparable {
    case low = 0, normal = 1, high = 2
    public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    public var label: String { ["Low", "Normal", "High"][rawValue] }
}

public enum CaptureSource: String, Codable, Sendable {
    case hotkey, popover, manual, notificationReply, urlScheme, voice
}

/// Where the language model is in understanding a capture.
public enum ProcessingState: String, Codable, Sendable {
    /// Saved, not yet sent to the model (or the model was unavailable).
    case awaiting
    /// Model output was validated and applied.
    case processed
    /// Model returned something invalid. Raw text is untouched.
    case failed
    /// The user edited it by hand; the model will not overwrite it.
    case manual
}

public enum EventKind: String, Codable, Sendable {
    case captured, interpreted, interpretationFailed, edited
    case reminderScheduled, reminderSent, snoozed, completed, dropped, reopened
    // Milestone 3
    /// The deadline was moved later. Counts as a postponement, like `snoozed`.
    case deadlineMoved
    case archived, linkedToGoal, unlinkedFromGoal, convertedToGoal, split
    case waitingUpdated, followUpScheduled, followedUp
    /// The user answered a "moved several times" observation (kept the date, etc.).
    case postponementReviewed
    // Milestone 8
    /// One occurrence of a repeating reminder was marked done; the series continues.
    case occurrenceDone
}

/// One captured thing. Stores the verbatim text forever, plus the interpreted fields.
/// Enums are stored as raw values so future schema changes stay lightweight.
@Model
public final class Commitment {
    @Attribute(.unique) public var id: UUID
    public var originalText: String
    public var title: String
    public var details: String?
    public var createdAt: Date
    /// IANA zone the capture was made in, so relative phrases can be re-read later.
    public var timeZoneID: String
    public var deadline: Date?
    /// False for "by Friday", true for "Friday at 5pm".
    public var deadlineHasTime: Bool
    public var nextReminderAt: Date?
    /// True when nextReminderAt was derived from the deadline rather than chosen by the user.
    /// Lets a later interpretation withdraw it without touching user-chosen reminders.
    public var reminderFromDeadline: Bool = false
    public var lastReminderAt: Date?
    public var snoozeCount: Int
    /// Last time the user explicitly put this off (snooze, "leave for tomorrow").
    public var deferredAt: Date?
    public var completedAt: Date?
    public var droppedAt: Date?
    public var archivedAt: Date?
    // Goals (Milestone 3). Optional/defaulted so v2 records load unchanged.
    public var goal: Goal?
    public var isMilestone: Bool = false
    // Waiting items (Milestone 3).
    /// Person or organisation being waited on, when known.
    public var waitingOn: String?
    /// What response or event is expected.
    public var expectedResponse: String?
    public var waitingSince: Date?
    public var followUpAt: Date?
    /// When the user last acknowledged a due follow-up. A follow-up is due again only for a later followUpAt.
    public var followUpAcknowledgedAt: Date?
    /// Private items are left out of anything sent outside the Mac unless included each time.
    public var isPrivate: Bool = false
    // Reminders that macOS delivers (schema v5). Optional so v4 records load unchanged.
    /// JSON `RecurrenceRule` for repeating reminders; nil for one-off ones.
    public var recurrenceRaw: String?
    /// Identifiers of the macOS notification requests currently scheduled for this item.
    public var notificationIDsRaw: String?
    var statusRaw: String
    var kindRaw: String
    var priorityRaw: Int
    var sourceRaw: String
    var processingRaw: String
    public var processingNote: String?
    public var modelName: String?
    @Relationship(deleteRule: .cascade, inverse: \ActivityEvent.commitment)
    public var events: [ActivityEvent] = []

    public init(originalText: String, source: CaptureSource, now: Date = .now,
                timeZone: TimeZone = .current) {
        id = UUID()
        self.originalText = originalText
        title = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        createdAt = now
        timeZoneID = timeZone.identifier
        deadlineHasTime = false
        snoozeCount = 0
        statusRaw = CommitmentStatus.pending.rawValue
        kindRaw = CaptureKind.unsorted.rawValue
        priorityRaw = Priority.normal.rawValue
        sourceRaw = source.rawValue
        processingRaw = ProcessingState.awaiting.rawValue
    }

    public var recurrence: RecurrenceRule? {
        get { recurrenceRaw.flatMap { try? JSONDecoder().decode(RecurrenceRule.self, from: Data($0.utf8)) } }
        set { recurrenceRaw = newValue.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } }
    }

    public var scheduledNotificationIDs: [String] {
        get { notificationIDsRaw?.split(separator: "\n").map(String.init) ?? [] }
        set { notificationIDsRaw = newValue.isEmpty ? nil : newValue.sorted().joined(separator: "\n") }
    }

    public var status: CommitmentStatus {
        get { CommitmentStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }
    public var kind: CaptureKind {
        get { CaptureKind(rawValue: kindRaw) ?? .unsorted }
        set { kindRaw = newValue.rawValue }
    }
    public var priority: Priority {
        get { Priority(rawValue: priorityRaw) ?? .normal }
        set { priorityRaw = newValue.rawValue }
    }
    public var source: CaptureSource {
        get { CaptureSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }
    public var processing: ProcessingState {
        get { ProcessingState(rawValue: processingRaw) ?? .awaiting }
        set { processingRaw = newValue.rawValue }
    }
    public var sortedEvents: [ActivityEvent] { events.sorted { $0.at < $1.at } }

    /// Snoozes plus deadline moves, from history. Postponement insight input.
    public var postponementCount: Int { events.filter { $0.kind == .snoozed || $0.kind == .deadlineMoved }.count }

    /// Latest recorded activity of any kind (falls back to creation).
    public var lastActivityAt: Date { events.map(\.at).max() ?? createdAt }

    /// When waiting started: explicit, else creation.
    public var effectiveWaitingSince: Date { waitingSince ?? createdAt }
}

public enum GoalStatus: String, Codable, CaseIterable, Sendable {
    case active, paused, completed, archived
    public var label: String { rawValue.capitalized }
}

/// How a goal's progress is measured. The user chooses; Wren never assumes tasks are equal-sized.
public enum ProgressMethod: String, Codable, CaseIterable, Sendable {
    /// The user sets a percentage.
    case manual
    /// Completed linked tasks ÷ linked tasks (dropped and archived not counted).
    case linkedTasks
    /// Completed milestones ÷ milestones.
    case milestones

    public var label: String {
        switch self {
        case .manual: "Set by me"
        case .linkedTasks: "Linked tasks done"
        case .milestones: "Milestones done"
        }
    }
}

public enum GoalEventKind: String, Codable, Sendable {
    case created, edited, statusChanged, progressChanged, methodChanged, targetDateChanged, taskLinked, taskUnlinked
}

@Model
public final class Goal {
    @Attribute(.unique) public var id: UUID
    public var title: String
    /// What the user originally wrote, if the goal came from a capture.
    public var originalText: String
    public var details: String?
    public var targetDate: Date?
    var statusRaw: String = GoalStatus.active.rawValue
    var methodRaw: String = ProgressMethod.manual.rawValue
    /// 0…1, used only with the manual method.
    public var manualProgress: Double = 0
    public var createdAt: Date
    public var updatedAt: Date
    /// Last time progress moved (manual change, or a linked task completed).
    public var lastProgressAt: Date?
    public var completedAt: Date?
    @Relationship(deleteRule: .nullify, inverse: \Commitment.goal) public var tasks: [Commitment] = []
    @Relationship(deleteRule: .cascade, inverse: \GoalEvent.goal) public var events: [GoalEvent] = []

    public init(title: String, originalText: String, targetDate: Date?, now: Date) {
        id = UUID(); self.title = title; self.originalText = originalText; self.targetDate = targetDate
        createdAt = now; updatedAt = now
    }

    public var status: GoalStatus {
        get { GoalStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }
    public var method: ProgressMethod {
        get { ProgressMethod(rawValue: methodRaw) ?? .manual }
        set { methodRaw = newValue.rawValue }
    }
    public var sortedEvents: [GoalEvent] { events.sorted { $0.at < $1.at } }
    public var milestones: [Commitment] { tasks.filter(\.isMilestone) }

    /// Latest activity on the goal or any linked task.
    public var lastActivityAt: Date {
        ([updatedAt, lastProgressAt ?? createdAt] + tasks.map(\.lastActivityAt)).max() ?? createdAt
    }
}

@Model
public final class GoalEvent {
    public var id: UUID
    public var at: Date
    var kindRaw: String
    public var note: String?
    public var goal: Goal?
    public init(kind: GoalEventKind, at: Date, note: String? = nil) {
        id = UUID(); self.at = at; kindRaw = kind.rawValue; self.note = note
    }
    public var kind: GoalEventKind { GoalEventKind(rawValue: kindRaw) ?? .edited }
}

public enum InsightState: String, Codable, Sendable { case open, dismissed, resolved }

/// Remembers what Wren has already pointed out, so an unchanged situation isn't raised again.
/// Keyed by kind + subject + fingerprint; the fingerprint changes when the situation does.
@Model
public final class InsightRecord {
    @Attribute(.unique) public var key: String
    public var kindRaw: String
    public var subjectID: String
    public var fingerprint: String
    var stateRaw: String = InsightState.open.rawValue
    public var firstSeenAt: Date
    /// When it was included in a briefing or check-in notification.
    public var surfacedAt: Date?
    public var closedAt: Date?

    public init(key: String, kind: String, subjectID: String, fingerprint: String, at: Date) {
        self.key = key; kindRaw = kind; self.subjectID = subjectID; self.fingerprint = fingerprint; firstSeenAt = at
    }
    public var state: InsightState {
        get { InsightState(rawValue: stateRaw) ?? .open }
        set { stateRaw = newValue.rawValue }
    }
}

/// Append-only history: why Wren did what it did to an item.
@Model
public final class ActivityEvent {
    public var id: UUID
    public var at: Date
    var kindRaw: String
    public var note: String?
    public var commitment: Commitment?

    public init(kind: EventKind, at: Date, note: String? = nil) {
        id = UUID()
        self.at = at
        kindRaw = kind.rawValue
        self.note = note
    }
    public var kind: EventKind { EventKind(rawValue: kindRaw) ?? .edited }
}

/// What happened to one day's briefing or check-in. Written before delivery so a
/// restart can never send the same day's event twice (at-most-once).
public enum DailyEventState: String, Codable, Sendable {
    case pending
    /// Handed to macOS notifications.
    case sent
    /// Nothing worth reporting, and empty summaries are off.
    case skippedEmpty
    /// Wren wasn't running (or the Mac was asleep) for the whole window.
    case missed
    /// Notifications unavailable; the summary is still viewable in the menu.
    case undelivered
    /// Check-in only: the user finished or dismissed it.
    case completed, dismissed
    /// Turned off in settings at the time it would have run.
    case disabled
}

@Model
public final class DailyRun {
    @Attribute(.unique) public var day: String
    var briefingRaw: String = DailyEventState.pending.rawValue
    public var briefingAt: Date?
    var checkInRaw: String = DailyEventState.pending.rawValue
    public var checkInAt: Date?

    public init(day: String) { self.day = day }

    public var briefing: DailyEventState {
        get { DailyEventState(rawValue: briefingRaw) ?? .pending }
        set { briefingRaw = newValue.rawValue }
    }
    public var checkIn: DailyEventState {
        get { DailyEventState(rawValue: checkInRaw) ?? .pending }
        set { checkInRaw = newValue.rawValue }
    }
}

public enum DelegationDestination: String, Codable, Sendable, CaseIterable {
    /// `openaiAPI` is kept only so older history records still read; it's never offered.
    case chatgptPlan, chatgptHandoff, openaiAPI, localModel, notionSearch, gmailSearch, calendarLookup
    public var label: String {
        switch self {
        case .chatgptPlan: "ChatGPT (your plan)"
        case .chatgptHandoff: "ChatGPT (copy and open)"
        case .openaiAPI: "OpenAI API (no longer available)"
        case .localModel: "Local model"
        case .notionSearch: "Notion search"
        case .gmailSearch: "Gmail search"
        case .calendarLookup: "Calendar"
        }
    }
    public var leavesMac: Bool { self == .chatgptPlan || self == .chatgptHandoff || self == .openaiAPI }
}

public enum DelegationStatus: String, Codable, Sendable {
    /// Prompt prepared and shown; nothing has left the Mac.
    case prepared
    /// Copied and ChatGPT opened. Not sent by Wren: the user submits it in ChatGPT and pastes the answer.
    case handedOff
    /// Sent to the provider; no final answer yet. Persisted before anything leaves the Mac.
    case running
    /// The user pasted an answer for a handoff (Wren can't see the model or mode).
    case responseImported
    /// The provider reported a complete answer (`response.completed`).
    case completed
    /// The provider stopped early; the partial text is kept. Retryable.
    case partial
    case cancelled, failed
    public var label: String {
        switch self {
        case .prepared: "Prepared (not sent)"
        case .handedOff: "Awaiting submission: copied and opened ChatGPT; you send it there and paste the answer back"
        case .running: "Running"
        case .responseImported: "Answer pasted by you"
        case .completed: "Completed"
        case .partial: "Incomplete answer"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }
    /// Finished one way or another (no request in flight).
    public var isFinal: Bool { self != .running && self != .prepared && self != .handedOff }
}

/// Why a delegation didn't complete, so the UI can offer the right recovery.
public enum DelegationFailure: String, Codable, Sendable {
    case notConnected, reauthorizationRequired, planNotAuthorized, usageLimit, unavailable, rejected, interrupted, needsReview, other
    public var retryable: Bool {
        switch self {
        case .usageLimit, .unavailable, .interrupted: true
        default: false
        }
    }
}

/// One delegated task and its result. Never stores credentials.
@Model
public final class DelegationRecord {
    @Attribute(.unique) public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var task: String
    var destinationRaw: String
    var statusRaw: String
    var depthRaw: String = HandoffDepth.normal.rawValue
    /// Exactly what left (or would leave) the Mac.
    public var prompt: String?
    public var response: String?
    /// Where the answer came from, as known: "Pasted by you from ChatGPT" or "ChatGPT plan · requested model …".
    public var responseSource: String?
    public var summary: String?
    public var error: String?
    public var linkedItemID: UUID?
    // Schema v6: tracked, notified delegations. Optional/defaulted so v5 records load unchanged.
    /// Exactly what the user typed or said (the prompt is the cleaned request).
    public var original: String?
    public var channelRaw: String?
    public var requestedModel: String?
    /// The model the completed response named, when it did.
    public var reportedModel: String?
    public var startedAt: Date?
    public var completedAt: Date?
    public var attempts: Int = 0
    var failureRaw: String?
    /// When Wren told the user it finished (notification or in-app entry), so it's announced once.
    public var notifiedAt: Date?
    /// When the user opened the result in Wren.
    public var seenAt: Date?
    /// A provider web link to the conversation, only if the provider actually returned one. The
    /// ChatGPT-plan Responses call (`store: false`) returns none, so this stays nil; never fabricated.
    public var providerURL: String?
    /// The user explicitly included private content in this prompt (needed again to retry it).
    public var includesPrivate: Bool = false

    public init(task: String, destination: DelegationDestination, depth: HandoffDepth, now: Date) {
        id = UUID(); createdAt = now; updatedAt = now; self.task = task
        destinationRaw = destination.rawValue; statusRaw = DelegationStatus.prepared.rawValue; depthRaw = depth.rawValue
    }
    public var destination: DelegationDestination { DelegationDestination(rawValue: destinationRaw) ?? .localModel }
    public var status: DelegationStatus {
        get { DelegationStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }
    public var depth: HandoffDepth { HandoffDepth(rawValue: depthRaw) ?? .normal }
    public var failure: DelegationFailure? {
        get { failureRaw.flatMap(DelegationFailure.init(rawValue:)) }
        set { failureRaw = newValue?.rawValue }
    }
    public var channel: UserChannel? { channelRaw.flatMap(UserChannel.init(rawValue:)) }
    /// Retry is offered only for a failure that may succeed later; a completed request never re-runs.
    public var canRetry: Bool {
        switch status {
        case .partial: true
        case .failed, .cancelled: failure?.retryable ?? (status == .cancelled)
        default: false
        }
    }
}
