import Foundation

// MARK: Classification

/// Practical inbox categories, most pressing first. These are Wren's inferences, shown with reasons.
/// Note: this is about priority, not Gmail's Spam label (Spam and Trash are never triaged at all).
public enum MailCategory: String, Codable, CaseIterable, Sendable, Comparable {
    case urgent, timeSensitive, needsResponse, professional, financial, informational

    public var label: String {
        switch self {
        case .urgent: "Urgent action required"
        case .timeSensitive: "Important and time-sensitive"
        case .needsResponse: "Needs a response"
        case .professional: "Professional (work, recruiting, jobs)"
        case .financial: "Financial or account notice"
        case .informational: "Informational, no action needed"
        }
    }
    public var shortLabel: String {
        switch self {
        case .urgent: "Urgent"
        case .timeSensitive: "Time-sensitive"
        case .needsResponse: "Needs reply"
        case .professional: "Professional"
        case .financial: "Financial"
        case .informational: "Informational"
        }
    }
    var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    /// Categories that make a message "important" for digests and the inbox overview.
    public var isImportant: Bool { self != .informational }
}

/// Per-sender corrections the user made ("always important", "never important").
public enum SenderRule: String, Codable, Sendable { case important, notImportant }

/// Wren's reading of one message. `summary` is factual (Gmail's own snippet); `reasons` and
/// `suggestedAction` are inferred and always labelled as such in the UI.
public struct MailClassification: Codable, Equatable, Sendable {
    public var category: MailCategory
    public var reasons: [String]
    /// Higher is more pressing. Used for ranking and the alert threshold.
    public var score: Int
    public var deadline: Date?
    public var suggestedAction: String
    /// The user set the category by hand.
    public var corrected: Bool = false
}

public struct MailTriageSettings: Equatable, Sendable {
    public var importantSenders: Set<String>
    public var senderRules: [String: SenderRule]
    public init(importantSenders: Set<String> = [], senderRules: [String: SenderRule] = [:]) {
        self.importantSenders = Set(importantSenders.map { $0.lowercased() }); self.senderRules = senderRules
    }
}

/// Deterministic, explainable, on-device triage. Message text is data only: nothing in an email
/// can change Wren's settings, trigger an action or reach an external service.
public enum MailTriage {
    static func has<O>(_ s: String, _ r: Regex<O>) -> Bool { (try? r.firstMatch(in: s)) != nil }

    public static func classify(_ m: EmailMessage, settings: MailTriageSettings = .init(), now: Date, calendar: Calendar) -> MailClassification {
        let subject = m.subject.lowercased(), text = (m.subject + " " + m.snippet).lowercased()
        let sender = m.senderAddress
        var reasons: [String] = []
        var score = 0

        // Who it's from.
        let rule = settings.senderRules[sender]
        let starredSender = settings.importantSenders.contains { sender.contains($0) || m.from.lowercased().contains($0) }
        if rule == .important || starredSender { reasons.append("from a sender you marked important"); score += 40 }
        let bulk = m.isBulk == true || m.labels.contains { ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_FORUMS"].contains($0) }
        let automated = has(sender, /^(no-?reply|do-?not-?reply|notifications?|mailer-daemon|newsletter|news|marketing|info)@/)
        if m.labels.contains("IMPORTANT") { reasons.append("Gmail marked it important"); score += 15 }
        if m.labels.contains("STARRED") { reasons.append("you starred it"); score += 20 }

        // What it says (subject and Gmail's snippet).
        let security = has(text, /\b(security alert|new sign-?in|sign-?in attempt|suspicious (?:activity|sign-?in)|unusual activity|password (?:was )?(?:changed|reset)|2-step verification|account (?:was )?(?:locked|compromised))\b/)
        let urgentWords = has(text, /\b(urgent|asap|as soon as possible|immediately|action required|immediate action|final notice|final reminder|last chance to respond|time-?sensitive|deadline today|due today|expires today|by end of (?:day|today)|eod)\b/)
        let request = has(text, /\b(could you|can you|would you|please (?:confirm|reply|respond|let me know|send|review|sign|approve)|let me know|are you able|need you to|kindly|your (?:input|approval|feedback|confirmation) (?:is )?(?:needed|required)|awaiting your|waiting for your)\b/) || m.subject.hasSuffix("?")
        let professional = has(text, /\b(recruit\w*|interview\w*|hiring|job (?:offer|opportunity|application)|offer letter|your application|candidate|position|role at|opportunity at|talent|headhunt\w*|linkedin)\b/)
        let financial = has(text, /\b(invoice|payment (?:due|failed|declined|received|reminder)|amount due|bill(?:ing)?|statement (?:is )?(?:ready|available)|receipt|refund|charged?|transaction|bank|card ending|overdue balance|subscription (?:renew\w*|expir\w*)|tax)\b/)
        let meetingChange = has(subject, /\b(rescheduled|moved to|time change|updated invitation|invitation updated|cancel+ed|postponed|new time)\b/)
        var deadline: Date?
        if has(text, /\b(due|deadline|by|before|until|expires?|no later than)\b/), let p = DateParser(calendar: calendar).parse(m.subject + " " + m.snippet, now: m.date) {
            deadline = p.date
        }
        let hoursToDeadline = deadline.map { $0.timeIntervalSince(now) / 3600 }

        if security { reasons.append("security notice about your account"); score += 50 }
        if urgentWords && !bulk { reasons.append("says it's urgent"); score += 30 }
        if let h = hoursToDeadline {
            if h < -24 { /* long past: not a reason by itself */ }
            else if h <= 24 { reasons.append("deadline within a day (\(DueText.describe(deadline!, hasTime: false, now: now, calendar: calendar)))"); score += 35 }
            else if h <= 72 { reasons.append("deadline soon (\(DueText.describe(deadline!, hasTime: false, now: now, calendar: calendar)))"); score += 20 }
            else { reasons.append("mentions a date (\(DueText.describe(deadline!, hasTime: false, now: now, calendar: calendar)))"); score += 5 }
        }
        if meetingChange { reasons.append("a meeting changed"); score += 25 }
        if request && !bulk && !automated { reasons.append("asks you something"); score += 20 }
        if professional && !bulk { reasons.append("work or recruiting"); score += 15 }
        if financial { reasons.append("bill, payment or account notice"); score += 15 }
        if bulk { score -= 20 }
        if rule == .notImportant { score = min(score, 0); reasons = ["you marked this sender not important"] }

        let category: MailCategory
        if rule == .notImportant { category = .informational }
        else if security || (urgentWords && !bulk) || (hoursToDeadline.map { $0 >= -24 && $0 <= 24 } ?? false && !bulk) { category = .urgent }
        else if meetingChange || (hoursToDeadline.map { $0 > 24 && $0 <= 72 } ?? false && !bulk) { category = .timeSensitive }
        else if request && !bulk && !automated { category = .needsResponse }
        else if professional && !bulk { category = .professional }
        else if financial { category = .financial }
        else if rule == .important || starredSender || m.labels.contains("STARRED") { category = .needsResponse }
        else { category = .informational }
        if reasons.isEmpty { reasons = [bulk ? "newsletter, promotion or automated update" : "no sign it needs action"] }

        let action: String = switch category {
        case .urgent: security ? "Check your account security" : (deadline.map { "Handle before \(DueText.describe($0, hasTime: false, now: now, calendar: calendar))" } ?? "Look at this today")
        case .timeSensitive: meetingChange ? "Check the new meeting time" : "Plan for the deadline"
        case .needsResponse: "Reply"
        case .professional: "Review and reply if interested"
        case .financial: "Review the amount or account notice"
        case .informational: "Read when convenient, or ignore"
        }
        return MailClassification(category: category, reasons: reasons, score: max(0, score), deadline: deadline, suggestedAction: action)
    }
}

// MARK: Local mailbox state

/// One message Wren knows about, with what it did about it.
public struct MailItem: Codable, Equatable, Sendable, Identifiable {
    public var message: EmailMessage
    public var classification: MailClassification
    public var firstSeenAt: Date
    /// Present in the inbox when monitoring started (never alerted as "new").
    public var baseline: Bool
    public var alertedAt: Date?
    /// The category it was alerted with; a later escalation may justify one more alert.
    public var alertedCategory: MailCategory?
    /// Held during quiet hours; delivered (as one summary) after.
    public var heldForQuietHours: Bool = false
    /// The user dismissed Wren's alert. Gmail is unchanged.
    public var dismissedAt: Date?
    public var snoozedUntil: Date?
    public var lastActionError: String?
    public var id: String { message.id }

    public init(message: EmailMessage, classification: MailClassification, firstSeenAt: Date, baseline: Bool) {
        self.message = message; self.classification = classification; self.firstSeenAt = firstSeenAt; self.baseline = baseline
    }

    public func isSnoozed(at now: Date) -> Bool { snoozedUntil.map { $0 > now } ?? false }
}

/// A record of a Gmail change Wren made (or tried), without message contents.
public struct MailActionRecord: Codable, Equatable, Sendable {
    public var at: Date
    public var action: String
    public var messageID: String
    public var succeeded: Bool
    public var detail: String
    public init(at: Date, action: String, messageID: String, succeeded: Bool, detail: String) {
        self.at = at; self.action = action; self.messageID = messageID; self.succeeded = succeeded; self.detail = detail
    }
}

public enum DigestState: String, Codable, Sendable { case pending, delivered, undelivered, empty }

public struct DigestEntry: Codable, Equatable, Sendable, Identifiable {
    public var messageIDs: [String]
    public var threadID: String
    public var sender: String
    public var subject: String
    /// Factual: Gmail's snippet of the latest message.
    public var summary: String
    /// Inferred.
    public var category: MailCategory
    public var reason: String
    public var suggestedAction: String
    public var count: Int
    public var link: URL
    public var id: String { threadID }
}

public struct DigestRecord: Codable, Equatable, Sendable, Identifiable {
    /// The scheduled slot ("2026-10-12" in the digest's time zone). One digest per slot, ever.
    public var key: String
    public var createdAt: Date
    public var coveredFrom: Date
    public var coveredTo: Date
    public var entries: [DigestEntry]
    public var state: DigestState
    /// Built after the scheduled time because the Mac was asleep or Wren wasn't running.
    public var late: Bool
    public var id: String { key }
}

/// Everything Wren keeps about the mailbox: headers, labels and Gmail snippets of recent inbox mail,
/// the sync cursor, alert and digest bookkeeping. Stored as a private file outside Wren's database,
/// so it's never in backups or exports, and deleted on disconnect or "Remove all data".
public struct MailboxState: Codable, Equatable, Sendable {
    public var account: String?
    public var historyID: String?
    public var monitoringSince: Date?
    public var lastSyncAt: Date?
    public var lastFullSyncAt: Date?
    public var lastError: String?
    public var lastErrorAt: Date?
    public var items: [String: MailItem] = [:]
    public var senderRules: [String: SenderRule] = [:]
    public var digests: [DigestRecord] = []
    public var actions: [MailActionRecord] = []
    public init() {}

    public var inbox: [MailItem] { items.values.sorted { ($0.classification.score, $0.message.date) > ($1.classification.score, $1.message.date) } }
    public var lastDigest: DigestRecord? { digests.max { $0.createdAt < $1.createdAt } }

    public mutating func record(_ a: MailActionRecord) {
        actions.append(a)
        if actions.count > 200 { actions.removeFirst(actions.count - 200) }
    }
}

public struct MailboxStore: Sendable {
    public let url: URL
    public init(directory: URL) { url = directory.appendingPathComponent("Mail/mailbox.json") }

    public func load() -> MailboxState {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? d.decode(MailboxState.self, from: $0) } ?? MailboxState()
    }

    public func save(_ s: MailboxState) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try e.encode(s).write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Deletes all cached mail and mail bookkeeping.
    public func clear() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

// MARK: Sync

public struct MailSyncResult: Equatable, Sendable {
    public enum Mode: String, Sendable { case full, incremental, fullAfterExpiredCursor }
    public var mode: Mode
    /// Messages that arrived since the previous sync (candidates for alerts). Empty on a first sync.
    public var newMessageIDs: [String] = []
    public var updated = 0
    public var removed = 0
}

/// Keeps `MailboxState` in line with the inbox: a bounded full read the first time (or when Gmail's
/// history cursor expires), then only the changes since the last sync.
public enum MailSync {
    /// What a full read covers: recent inbox mail, plus older unread mail Gmail marked important.
    public static let fullQuery = "newer_than:7d OR (is:unread is:important newer_than:30d)"
    public static let fullLimit = 150
    public static let keepDays: TimeInterval = 30

    public static func sync(_ state: inout MailboxState, api: GmailAPI, settings: MailTriageSettings, now: Date, calendar: Calendar) async throws -> MailSyncResult {
        var triage = settings; triage.senderRules.merge(state.senderRules) { _, s in s }
        let profile = try await api.profile()
        if state.account != nil, state.account != profile.email {
            // Another Google account: nothing from the previous mailbox carries over.
            state = MailboxState()
        }
        state.account = profile.email
        var result: MailSyncResult
        if let cursor = state.historyID {
            do {
                result = try await incremental(&state, api: api, since: cursor, settings: triage, now: now, calendar: calendar)
            } catch GmailSyncError.historyExpired {
                result = try await full(&state, api: api, settings: triage, now: now, calendar: calendar, historyID: profile.historyID, afterExpiry: true)
            }
        } else {
            result = try await full(&state, api: api, settings: triage, now: now, calendar: calendar, historyID: profile.historyID, afterExpiry: false)
        }
        // Forget old, settled mail.
        let cutoff = now.addingTimeInterval(-keepDays * 86400)
        for (id, item) in state.items where item.message.date < cutoff { state.items[id] = nil; result.removed += 1 }
        state.lastSyncAt = now; state.lastError = nil; state.lastErrorAt = nil
        if state.monitoringSince == nil { state.monitoringSince = now }
        return result
    }

    static func add(_ ms: [EmailMessage], to state: inout MailboxState, account: String?, settings: MailTriageSettings, now: Date, calendar: Calendar, baseline: Bool) -> [String] {
        var new: [String] = []
        for var m in ms where !m.isSpamOrTrash && m.labels.contains("INBOX") {
            m.account = account
            let c = MailTriage.classify(m, settings: settings, now: now, calendar: calendar)
            if var existing = state.items[m.id] {
                existing.message = m
                if !existing.classification.corrected { existing.classification = c }
                state.items[m.id] = existing
            } else {
                state.items[m.id] = MailItem(message: m, classification: c, firstSeenAt: now, baseline: baseline)
                if !baseline { new.append(m.id) }
            }
        }
        return new
    }

    static func full(_ state: inout MailboxState, api: GmailAPI, settings: MailTriageSettings, now: Date, calendar: Calendar,
                     historyID: String, afterExpiry: Bool) async throws -> MailSyncResult {
        let ids = try await api.inboxMessageIDs(query: fullQuery, limit: fullLimit)
        var ms: [EmailMessage] = []
        for id in ids { if let m = try? await api.metadata(id) { ms.append(m) } }
        let present = Set(ids)
        var removed = 0
        // Anything Wren had that's no longer in the inbox (read elsewhere stays; archived/spam/trash goes).
        for id in state.items.keys where !present.contains(id) && state.items[id]!.message.date > now.addingTimeInterval(-7 * 86400) {
            state.items[id] = nil; removed += 1
        }
        // First sync: everything already there is the baseline (no "new mail" alerts for it).
        // After an expired cursor: messages newer than the last sync are still treated as new.
        let isFirst = state.lastSyncAt == nil
        var newIDs: [String] = []
        if isFirst {
            _ = add(ms, to: &state, account: state.account, settings: settings, now: now, calendar: calendar, baseline: true)
        } else {
            let since = state.lastSyncAt ?? now
            let fresh = ms.filter { $0.date > since }, old = ms.filter { $0.date <= since }
            _ = add(old, to: &state, account: state.account, settings: settings, now: now, calendar: calendar, baseline: true)
            newIDs = add(fresh, to: &state, account: state.account, settings: settings, now: now, calendar: calendar, baseline: false)
        }
        state.historyID = historyID
        state.lastFullSyncAt = now
        return MailSyncResult(mode: afterExpiry ? .fullAfterExpiredCursor : .full, newMessageIDs: newIDs, updated: ms.count, removed: removed)
    }

    static func incremental(_ state: inout MailboxState, api: GmailAPI, since: String, settings: MailTriageSettings, now: Date, calendar: Calendar) async throws -> MailSyncResult {
        let h = try await api.history(since: since)
        var result = MailSyncResult(mode: .incremental)
        // Label changes on messages Wren knows: read/unread elsewhere, archived, moved to spam or trash.
        for (id, added) in h.labelsAdded {
            guard var item = state.items[id] else { continue }
            if added.contains("SPAM") || added.contains("TRASH") { state.items[id] = nil; result.removed += 1; continue }
            item.message.labels = Array(Set(item.message.labels).union(added)).sorted()
            state.items[id] = item; result.updated += 1
        }
        for (id, removed) in h.labelsRemoved {
            guard var item = state.items[id] else { continue }
            if removed.contains("INBOX") { state.items[id] = nil; result.removed += 1; continue }
            item.message.labels = item.message.labels.filter { !removed.contains($0) }
            state.items[id] = item; result.updated += 1
        }
        for id in h.deleted where state.items[id] != nil { state.items[id] = nil; result.removed += 1 }
        let toFetch = h.added.filter { state.items[$0] == nil && !h.deleted.contains($0) }
        var ms: [EmailMessage] = []
        for id in toFetch { if let m = try? await api.metadata(id) { ms.append(m) } }
        result.newMessageIDs = add(ms, to: &state, account: state.account, settings: settings, now: now, calendar: calendar, baseline: false)
        state.historyID = h.historyID
        return result
    }
}

// MARK: Alerts

public enum MailAlertLevel: String, Codable, CaseIterable, Sendable {
    case urgentOnly, important, needsMe
    public var label: String {
        switch self {
        case .urgentOnly: "Only urgent mail"
        case .important: "Urgent and time-sensitive mail"
        case .needsMe: "Anything that needs me (includes replies)"
        }
    }
    func includes(_ c: MailCategory) -> Bool {
        switch self {
        case .urgentOnly: c == .urgent
        case .important: c == .urgent || c == .timeSensitive
        case .needsMe: c == .urgent || c == .timeSensitive || c == .needsResponse
        }
    }
}

public struct QuietHours: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var startMinutes: Int
    public var endMinutes: Int
    public init(enabled: Bool = true, startMinutes: Int = 22 * 60, endMinutes: Int = 7 * 60) {
        self.enabled = enabled; self.startMinutes = startMinutes; self.endMinutes = endMinutes
    }
    public func contains(_ d: Date, calendar: Calendar) -> Bool {
        guard enabled, startMinutes != endMinutes else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: d)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return startMinutes < endMinutes ? (m >= startMinutes && m < endMinutes) : (m >= startMinutes || m < endMinutes)
    }
}

public struct MailAlertDecision: Equatable, Sendable {
    /// Alert individually (most pressing first, at most `maxIndividual`).
    public var individual: [String] = []
    /// Several more at once: one summary instead of a burst.
    public var summarized: [String] = []
    /// Held for the end of quiet hours.
    public var held: [String] = []
}

/// Decides which newly arrived messages deserve an alert: above the user's threshold, unread, not
/// dismissed or snoozed, once per message, and once per conversation unless it became more urgent.
public enum MailAlertPolicy {
    public static let maxIndividual = 3
    /// Within this time, another message in an alerted conversation doesn't alert again unless more urgent.
    public static let threadQuiet: TimeInterval = 6 * 3600

    public static func decide(_ state: inout MailboxState, candidates: [String], level: MailAlertLevel, quiet: QuietHours,
                              now: Date, calendar: Calendar) -> MailAlertDecision {
        var out = MailAlertDecision()
        let inQuiet = quiet.contains(now, calendar: calendar)
        // Held messages come back once quiet hours are over.
        let held = inQuiet ? [] : state.items.values.filter(\.heldForQuietHours).map(\.id)
        var pool = Array(Set(candidates + held))
        pool.sort { (state.items[$0]?.classification.score ?? 0) > (state.items[$1]?.classification.score ?? 0) }
        var chosen: [String] = []
        for id in pool {
            guard var item = state.items[id] else { continue }
            item.heldForQuietHours = false
            defer { state.items[id] = item }
            let c = item.classification.category
            guard item.message.unread, item.dismissedAt == nil, !item.isSnoozed(at: now), level.includes(c) else { continue }
            if let prev = item.alertedCategory, !(c < prev) { continue }   // already alerted, no new evidence
            let sameThread = state.items.values.contains {
                $0.id != id && $0.message.threadId == item.message.threadId && $0.alertedAt.map { now.timeIntervalSince($0) < threadQuiet } == true
                    && !(c < ($0.alertedCategory ?? .informational))
            }
            if sameThread { continue }
            if inQuiet { item.heldForQuietHours = true; out.held.append(id); continue }
            item.alertedAt = now; item.alertedCategory = c
            chosen.append(id)
        }
        out.individual = Array(chosen.prefix(maxIndividual))
        out.summarized = Array(chosen.dropFirst(maxIndividual))
        return out
    }
}

// MARK: Digest

public struct DigestSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var minutesAfterMidnight: Int
    /// nil: follow the Mac's time zone.
    public var timeZoneID: String?
    public init(enabled: Bool = true, minutesAfterMidnight: Int = 8 * 60, timeZoneID: String? = nil) {
        self.enabled = enabled; self.minutesAfterMidnight = minutesAfterMidnight; self.timeZoneID = timeZoneID
    }
    public func calendar(base: Calendar) -> Calendar {
        var c = base
        if let id = timeZoneID, let tz = TimeZone(identifier: id) { c.timeZone = tz }
        return c
    }
}

/// The daily email digest: due once per day at the chosen time (or as soon as Wren runs after it),
/// covering unread inbox mail since the previous digest plus older important unread mail.
public enum MailDigest {
    /// Older unread mail stays in digests until read, dismissed, or this old.
    public static let importantCarryDays: TimeInterval = 14

    public static func key(_ d: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The most recent scheduled slot at or before `now`.
    public static func latestSlot(_ s: DigestSettings, now: Date, base: Calendar) -> Date {
        let cal = s.calendar(base: base)
        let today = cal.time(minutesAfterMidnight: s.minutesAfterMidnight, on: now)
        return today <= now ? today : cal.time(minutesAfterMidnight: s.minutesAfterMidnight, on: cal.date(byAdding: .day, value: -1, to: now)!)
    }

    public static func nextSlot(_ s: DigestSettings, now: Date, base: Calendar) -> Date {
        let cal = s.calendar(base: base)
        let today = cal.time(minutesAfterMidnight: s.minutesAfterMidnight, on: now)
        return today > now ? today : cal.time(minutesAfterMidnight: s.minutesAfterMidnight, on: cal.date(byAdding: .day, value: 1, to: now)!)
    }

    /// The slot that's due now and hasn't had a digest yet, if any. Missed slots collapse into one.
    public static func due(_ state: MailboxState, settings s: DigestSettings, now: Date, base: Calendar) -> (key: String, slot: Date, late: Bool)? {
        guard s.enabled else { return nil }
        let slot = latestSlot(s, now: now, base: base)
        let k = key(slot, calendar: s.calendar(base: base))
        guard !state.digests.contains(where: { $0.key == k }) else { return nil }
        // Before monitoring started there's nothing to cover.
        if let since = state.monitoringSince, slot < since.addingTimeInterval(-86400) { return nil }
        return (k, slot, now.timeIntervalSince(slot) > 15 * 60)
    }

    /// Builds (and records, before any delivery) the digest for `key`. Recording first means a
    /// restart can't deliver the same digest twice.
    public static func build(_ state: inout MailboxState, key: String, slot: Date, late: Bool, now: Date) -> DigestRecord {
        let from = state.lastDigest?.coveredTo ?? now.addingTimeInterval(-86400)
        let carry = now.addingTimeInterval(-importantCarryDays * 86400)
        let pick = state.items.values.filter { item in
            guard item.message.unread, item.dismissedAt == nil, !item.isSnoozed(at: now) else { return false }
            if item.message.date > from { return true }
            return item.classification.category.isImportant && item.message.date > carry
        }
        // One entry per conversation, led by its most pressing, newest message.
        var groups: [String: [MailItem]] = [:]
        for i in pick { groups[i.message.threadId.isEmpty ? i.id : i.message.threadId, default: []].append(i) }
        let entries: [DigestEntry] = groups.map { thread, items in
            let lead = items.max { ($0.classification.score, $0.message.date) < ($1.classification.score, $1.message.date) }!
            let cat = items.map(\.classification.category).min()!
            return DigestEntry(messageIDs: items.sorted { $0.message.date > $1.message.date }.map(\.id), threadID: thread,
                               sender: lead.message.senderName, subject: lead.message.subject, summary: lead.message.snippet,
                               category: cat, reason: lead.classification.reasons.joined(separator: "; "),
                               suggestedAction: lead.classification.suggestedAction, count: items.count, link: lead.message.webURL)
        }.sorted { ($0.category, $0.subject) < ($1.category, $1.subject) }
        let rec = DigestRecord(key: key, createdAt: now, coveredFrom: from, coveredTo: now, entries: entries,
                               state: entries.isEmpty ? .empty : .pending, late: late)
        state.digests.append(rec)
        if state.digests.count > 30 { state.digests.removeFirst(state.digests.count - 30) }
        return rec
    }

    public static func mark(_ state: inout MailboxState, key: String, _ s: DigestState) {
        if let i = state.digests.firstIndex(where: { $0.key == key }) { state.digests[i].state = s }
    }

    /// Notification text: counts by category, the top three senders. Never message bodies.
    public static func notification(_ d: DigestRecord) -> (title: String, body: String) {
        let important = d.entries.filter { $0.category.isImportant }
        let title = important.isEmpty ? "Email digest: \(d.entries.count) unread, nothing urgent" : "Email digest: \(important.count) need attention"
        let top = (important.isEmpty ? d.entries : important).prefix(3).map { "\($0.sender): \($0.subject)" }
        return (d.late ? title + " (late)" : title, top.joined(separator: "\n"))
    }
}

// MARK: Preferences

/// The user's mail settings. Email content is processed on this Mac only: there is deliberately no
/// setting that sends email to ChatGPT or any other AI service.
public struct MailPreferences: Codable, Equatable, Sendable {
    public var digest = DigestSettings()
    /// Minutes between checks while Wren runs (2…60).
    public var pollingMinutes = 5
    public var alertsEnabled = true
    public var alertLevel: MailAlertLevel = .important
    public var quietHours = QuietHours()
    public init() {}
    public func normalized() -> MailPreferences {
        var p = self
        p.pollingMinutes = min(60, max(2, pollingMinutes))
        p.digest.minutesAfterMidnight = min(23 * 60 + 59, max(0, digest.minutesAfterMidnight))
        if let id = p.digest.timeZoneID, TimeZone(identifier: id) == nil { p.digest.timeZoneID = nil }
        return p
    }
}

/// Applies a user's correction and re-reads every message from that sender (unless corrected by hand).
public enum MailCorrections {
    public static func setCategory(_ state: inout MailboxState, id: String, _ c: MailCategory) {
        guard var item = state.items[id] else { return }
        item.classification.category = c
        item.classification.corrected = true
        item.classification.reasons = ["you set this to “\(c.shortLabel)”"]
        state.items[id] = item
    }

    public static func setSenderRule(_ state: inout MailboxState, sender: String, _ rule: SenderRule?, settings: MailTriageSettings, now: Date, calendar: Calendar) {
        let s = sender.lowercased()
        state.senderRules[s] = rule
        var t = settings; t.senderRules.merge(state.senderRules) { _, x in x }
        if rule == nil { t.senderRules[s] = nil }
        for (id, item) in state.items where item.message.senderAddress == s && !item.classification.corrected {
            state.items[id]?.classification = MailTriage.classify(item.message, settings: t, now: now, calendar: calendar)
        }
    }
}
