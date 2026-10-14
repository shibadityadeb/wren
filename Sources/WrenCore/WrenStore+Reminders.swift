import Foundation

public extension WrenStore {
    /// Creates a reminder from an explicit request. Saved before anything is reported.
    /// The reminder time is not a deadline: only `deadline` (the user said "by Friday", "before Monday")
    /// sets one. A deadline, a reminder time and the notifications scheduled for them stay separate.
    func createReminder(text: String, title: String, when: ReminderWhen, source: CaptureSource, id: UUID? = nil,
                        deadline: ParsedDate? = nil, calendar: Calendar = .current, now: Date = .now) throws -> Commitment {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !title.isEmpty else { throw StoreError.emptyText }
        let c = Commitment(originalText: text, source: source, now: now, timeZone: calendar.timeZone)
        if let id { c.id = id }
        context.insert(c)
        log(c, .captured, at: now, note: source.rawValue)
        c.kind = .commitment
        c.title = title
        // The user's own explicit words: a later model pass must not reinterpret them.
        c.processing = .manual
        c.reminderFromDeadline = false
        switch when {
        case let .once(d):
            guard d > now else { context.delete(c); throw StoreError.invalidTransition(from: .pending, action: "set a reminder in the past") }
            if let deadline {
                c.deadline = deadline.date
                c.deadlineHasTime = deadline.hasTime
            }
            c.nextReminderAt = d
            log(c, .reminderScheduled, at: now, note: Self.stamp(d))
        case let .repeating(rule):
            c.recurrence = rule
            c.nextReminderAt = rule.next(after: now, calendar: calendar)
            log(c, .reminderScheduled, at: now, note: rule.label(calendar: calendar))
        }
        try save()
        return c
    }

    /// Marks one occurrence of a repeating reminder as done; the series continues.
    func completeOccurrence(_ c: Commitment, calendar: Calendar = .current, now: Date = .now) throws {
        try requirePending(c, "complete an occurrence of")
        guard let rule = c.recurrence else { return try complete(c, now: now) }
        c.lastReminderAt = max(c.lastReminderAt ?? now, now)
        c.nextReminderAt = rule.next(after: now, calendar: calendar)
        log(c, .occurrenceDone, at: now, note: c.nextReminderAt.map { "next \(Self.stamp($0))" })
        try save()
    }

    /// Makes a reminder repeat (or stop repeating). Stopping keeps the next occurrence as a one-off.
    func setRepeat(_ c: Commitment, _ rule: RecurrenceRule?, calendar: Calendar = .current, now: Date = .now) throws {
        try requirePending(c, "change how often to remind about")
        c.recurrence = rule
        c.reminderFromDeadline = false
        if let rule {
            c.nextReminderAt = rule.next(after: now, calendar: calendar)
            log(c, .reminderScheduled, at: now, note: rule.label(calendar: calendar))
        } else {
            log(c, .edited, at: now, note: "stopped repeating")
        }
        try save()
    }

    /// Recomputes the next occurrence of repeating reminders (after a time zone or clock change).
    @discardableResult
    func refreshRecurrences(calendar: Calendar = .current, now: Date = .now) throws -> Int {
        var n = 0
        for c in try pending() {
            guard let rule = c.recurrence else { continue }
            let next = rule.next(after: now, calendar: calendar)
            // A pending snooze is a time that isn't an occurrence in the zone the reminder was last
            // scheduled in; keep it. Otherwise follow the rule's wall-clock time in the current zone.
            var previous = calendar
            if let tz = TimeZone(identifier: c.timeZoneID) { previous.timeZone = tz }
            if let cur = c.nextReminderAt, cur > now, !rule.matches(cur, calendar: previous) { continue }
            if c.timeZoneID != calendar.timeZone.identifier { c.timeZoneID = calendar.timeZone.identifier; n += 1 }
            if c.nextReminderAt != next { c.nextReminderAt = next; n += 1 }
        }
        if n > 0 { try save() }
        return n
    }
}
