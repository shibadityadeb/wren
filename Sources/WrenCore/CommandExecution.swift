import Foundation

/// What creating a task or reminder really did, read back from the store and from what macOS
/// accepted. The deadline, the reminder time, the notifications and the status are separate facts.
public struct ScheduledOutcome: Equatable, Sendable {
    public var itemID: UUID
    public var title: String
    public var status: CommitmentStatus
    /// When the task is due. nil when the user gave no deadline (a reminder time is not one).
    public var deadline: Date?
    public var deadlineHasTime: Bool
    /// The item's own reminder time (the user's, or the one that follows the deadline).
    public var reminderAt: Date?
    /// Every notification Wren wants macOS to hold for this item (the reminder, the day-before heads-up).
    public var planned: [ReminderRequest]
    /// Identifiers macOS has accepted, read back after scheduling.
    public var accepted: Set<String>
    public var notificationsAuthorized: Bool
    public var paused: Bool

    /// Everything planned is held by macOS, so it arrives even when Wren isn't running.
    public var allScheduled: Bool { !planned.isEmpty && planned.allSatisfy { accepted.contains($0.id) } }
    /// Planned, allowed and not paused, yet macOS didn't take it: a real failure, never reported as success.
    public var schedulingFailed: Bool { !planned.isEmpty && notificationsAuthorized && !paused && !allScheduled }
}

/// A failed operation: what went wrong and what the user can do about it.
public struct ExecutionFailure: Error, Equatable, Sendable {
    public var message: String
    public var recovery: String?
    public init(_ message: String, recovery: String? = nil) { self.message = message; self.recovery = recovery }
}

/// Runs the item operations the router chose (CreateTask, CreateReminder). Shared by every entry
/// point; each step goes through the broker (permission checks, audit) and the result is read back
/// from the store and the notification center, so success is never assumed.
@MainActor
public enum ItemExecution {
    /// "I need to submit the assignment by Friday": the words are saved first, then the task is set
    /// up from them (title, the deadline exactly as said or none), deadline reminders are scheduled
    /// as the user's settings say, and what macOS accepted is read back.
    public static func createTask(_ draft: TaskDraft, text: String, source: CaptureSource, store: WrenStore, broker: ActionBroker,
                                  scheduler: ReminderScheduler?, autoRemind: Bool, reminderHour: Int, now: Date) async -> Result<ScheduledOutcome, ExecutionFailure> {
        let c: Commitment
        do { c = try store.capture(text, source: source, now: now) } catch {
            return .failure(ExecutionFailure("Couldn't save: \(error.localizedDescription)", recovery: "Your text is still in the field. Try again."))
        }
        let note = draft.deadline?.isApproximate == true ? "“\(draft.deadline!.phrase)” is approximate; adjust if needed." : nil
        let reading = Interpretation(kind: .commitment, title: draft.title, priority: .normal, deadline: draft.deadline?.date,
                                     deadlineHasTime: draft.deadline?.hasTime ?? false, note: note)
        let applied = await broker.submit(ActionRequest(action: BuiltInAction.applyInterpretation, target: c.targetRef,
                                                        parameters: reading.parameters(model: nil, state: .processed, dateOnlyReminderHour: reminderHour, scheduleReminders: autoRemind),
                                                        origin: .system("command router"), createdAt: now))
        guard applied.status == .succeeded || applied.status == .unverified, let task = try? store.item(id: c.id) else {
            return .failure(ExecutionFailure("Your words were saved, but Wren couldn't set them up as a task (\(applied.message ?? applied.status.rawValue)).",
                                             recovery: "Find them in your list and set the deadline there."))
        }
        return .success(await readBack(task, scheduler: scheduler, now: now))
    }

    /// "Remind me to call Sam tomorrow at 10 AM": created through the broker (audited), then scheduled
    /// with macOS and read back. A stated deadline ("by Friday") is stored as the deadline; otherwise
    /// the item has a reminder time and no deadline.
    public static func createReminder(text: String, title: String, when: ReminderWhen, deadline: ParsedDate?, source: CaptureSource,
                                      origin: ActionOrigin, store: WrenStore, broker: ActionBroker, scheduler: ReminderScheduler?,
                                      now: Date) async -> Result<ScheduledOutcome, ExecutionFailure> {
        let id = UUID()
        let req = ActionRequest(action: BuiltInAction.createReminder, target: TargetRef(kind: "commitment", id: id.uuidString, label: title),
                                parameters: BuiltInAction.createReminderParameters(text: text, title: title, when: when, source: source, deadline: deadline),
                                origin: origin, createdAt: now)
        let result = await broker.submit(req)
        guard result.status == .succeeded || result.status == .unverified, let c = try? store.item(id: id) else {
            return .failure(ExecutionFailure(result.message ?? "The reminder wasn't saved.", recovery: "Your words are still in the field. Try again."))
        }
        return .success(await readBack(c, scheduler: scheduler, now: now))
    }

    /// Schedules (reconciling everything, so nothing is duplicated) and reports what is really held.
    public static func readBack(_ c: Commitment, scheduler: ReminderScheduler?, now: Date) async -> ScheduledOutcome {
        let report = await scheduler?.reconcile() ?? ReconcileReport()
        let planned = scheduler?.requests(for: c, now: now) ?? []
        return ScheduledOutcome(itemID: c.id, title: c.title, status: c.status, deadline: c.deadline, deadlineHasTime: c.deadlineHasTime,
                                reminderAt: c.nextReminderAt, planned: planned, accepted: Set(c.scheduledNotificationIDs),
                                notificationsAuthorized: report.authorized, paused: report.paused)
    }
}
