import Foundation
import SwiftData

/// Lifecycle of a commitment. Only `pending` items can produce reminders.
public enum CommitmentStatus: String, Codable, CaseIterable, Sendable {
    case pending, completed, dropped
}

/// What kind of thing the user captured. Only `.commitment` gets reminders.
/// `.unsorted` means nobody (model or user) has classified it yet.
public enum CaptureKind: String, Codable, CaseIterable, Sendable {
    case commitment, idea, question, waiting, research, unsorted

    public var label: String {
        switch self {
        case .commitment: "Commitment"
        case .idea: "Idea"
        case .question: "Question"
        case .waiting: "Waiting on"
        case .research: "Research"
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
    case hotkey, popover, manual, notificationReply, urlScheme
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
    public var completedAt: Date?
    public var droppedAt: Date?
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
