import AppKit
import UserNotifications
import WrenCore
import os

/// Native notifications. Delivery is best effort: Focus modes, Do Not Disturb and
/// System Settings can suppress banners, and Wren never claims otherwise.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate, WrenNotifier, ReminderNotificationCenter {
    enum Category: String {
        case reminder = "WREN_REMINDER", briefing = "WREN_BRIEFING", checkIn = "WREN_CHECKIN", checkInItem = "WREN_CHECKIN_ITEM"
        /// The heads-up the day before a deadline: Done only, so snoozing it can't move the real reminder.
        case advance = "WREN_ADVANCE"
        case delegation = "WREN_DELEGATION", mail = "WREN_MAIL", mailWithRead = "WREN_MAIL_READ", digest = "WREN_DIGEST"
        /// "N more important emails": no Snooze or Mark as read (it isn't one message).
        case mailSummary = "WREN_MAIL_SUMMARY"
    }
    enum Action: String {
        case done = "WREN_DONE", snoozeHour = "WREN_SNOOZE_1H", later = "WREN_LATER", tomorrow = "WREN_TOMORROW"
        case openBriefing = "WREN_OPEN_BRIEFING", review = "WREN_REVIEW", dismissCheckIn = "WREN_DISMISS_CHECKIN"
        case viewResult = "WREN_VIEW_RESULT"
        case openMail = "WREN_OPEN_MAIL", markRead = "WREN_MARK_READ", dismissMail = "WREN_DISMISS_MAIL", openDigest = "WREN_OPEN_DIGEST"
        case snoozeMail = "WREN_SNOOZE_MAIL", openInGmail = "WREN_OPEN_IN_GMAIL"
    }

    /// What a click on a mail alert asked for. Mark as read is only offered when Google granted it.
    /// `openInGmail` opens that exact conversation in Gmail (a click on the alert); `open` shows it in Wren.
    enum MailResponse: Equatable { case open(String), openInGmail(String), markRead(String), dismiss(String), snooze(String), openDigest(String) }

    enum Response {
        case done(UUID), snoozeHour(UUID), later(UUID, String), tomorrow(UUID), open(UUID)
        case openBriefing, reviewCheckIn, dismissCheckIn
        case openDelegation(UUID)
        case mail(MailResponse)
    }

    /// Resolved lazily: UNUserNotificationCenter requires a real app bundle.
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }
    private let log = Logger(subsystem: "com.shibadityadeb.wren", category: "notifications")
    var onResponse: ((Response) -> Void)?
    /// The Notification sounds preference. Off: banners stay, sounds don't play.
    var soundsEnabled: () -> Bool = { true }
    private var sound: UNNotificationSound? { soundsEnabled() ? .default : nil }
    private(set) var status: UNAuthorizationStatus = .notDetermined

    /// Registers the delegate and action buttons. Called once by the running app.
    func activate() {
        center.delegate = self
        let done = UNNotificationAction(identifier: Action.done.rawValue, title: "Done")
        let hour = UNNotificationAction(identifier: Action.snoozeHour.rawValue, title: "Remind me in 1 hour")
        let later = UNTextInputNotificationAction(identifier: Action.later.rawValue, title: "Remind me at…",
                                                  textInputButtonTitle: "Remind", textInputPlaceholder: "9pm, tomorrow 10am, in 2 hours")
        let tomorrow = UNNotificationAction(identifier: Action.tomorrow.rawValue, title: "Leave for tomorrow")
        let open = UNNotificationAction(identifier: Action.openBriefing.rawValue, title: "Open briefing", options: [.foreground])
        let review = UNNotificationAction(identifier: Action.review.rawValue, title: "Review", options: [.foreground])
        let dismiss = UNNotificationAction(identifier: Action.dismissCheckIn.rawValue, title: "Dismiss for today")
        let openMail = UNNotificationAction(identifier: Action.openMail.rawValue, title: "Show in Wren", options: [.foreground])
        let openInGmail = UNNotificationAction(identifier: Action.openInGmail.rawValue, title: "Open in Gmail", options: [.foreground])
        let snoozeMail = UNNotificationAction(identifier: Action.snoozeMail.rawValue, title: "Snooze alert for 1 hour")
        let markRead = UNNotificationAction(identifier: Action.markRead.rawValue, title: "Mark as read in Gmail")
        let dismissMail = UNNotificationAction(identifier: Action.dismissMail.rawValue, title: "Dismiss alert")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.reminder.rawValue, actions: [done, hour, later], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.briefing.rawValue, actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.checkIn.rawValue, actions: [review, dismiss], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.checkInItem.rawValue, actions: [done, tomorrow, later, dismiss], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.delegation.rawValue,
                                   actions: [UNNotificationAction(identifier: Action.viewResult.rawValue, title: "View result", options: [.foreground])], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.mail.rawValue, actions: [openInGmail, openMail, snoozeMail, dismissMail], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.mailWithRead.rawValue, actions: [openInGmail, openMail, markRead, snoozeMail, dismissMail], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.advance.rawValue, actions: [done], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.mailSummary.rawValue,
                                   actions: [UNNotificationAction(identifier: Action.openMail.rawValue, title: "Open Inbox", options: [.foreground]), dismissMail], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.digest.rawValue,
                                   actions: [UNNotificationAction(identifier: Action.openDigest.rawValue, title: "Open digest", options: [.foreground])], intentIdentifiers: []),
        ])
    }

    @discardableResult
    func refreshStatus() async -> UNAuthorizationStatus {
        status = await center.notificationSettings().authorizationStatus
        return status
    }

    func requestPermission() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            await refreshStatus()
            return granted
        } catch {
            log.error("authorization request failed: \(error.localizedDescription, privacy: .public)")
            await refreshStatus()
            return false
        }
    }

    var canDeliverNow: Bool { status == .authorized || status == .provisional }

    // MARK: WrenNotifier

    func canDeliver() async -> Bool { await refreshStatus(); return canDeliverNow }

    func deliverReminder(_ p: ReminderPayload) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = p.title
        content.body = p.body
        content.sound = sound
        content.categoryIdentifier = Category.reminder.rawValue
        content.userInfo = ["commitmentID": p.id.uuidString]
        content.threadIdentifier = "reminders"
        if p.late { content.subtitle = "Missed while your Mac was asleep or Wren wasn't running" }
        return await add("reminder-\(p.id.uuidString)", content)
    }

    func deliverBriefing(_ b: Briefing) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = b.title
        content.body = b.notificationBody
        content.sound = sound
        content.categoryIdentifier = Category.briefing.rawValue
        content.userInfo = ["kind": "briefing", "day": b.day]
        content.threadIdentifier = "daily"
        return await add("briefing-\(b.day)", content)
    }

    func deliverCheckIn(_ c: CheckIn) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = c.title
        content.body = c.notificationBody
        content.sound = sound
        content.threadIdentifier = "daily"
        if let item = c.singleItem {
            content.categoryIdentifier = Category.checkInItem.rawValue
            content.userInfo = ["kind": "checkIn", "day": c.day, "commitmentID": item.id.uuidString]
        } else {
            content.categoryIdentifier = Category.checkIn.rawValue
            content.userInfo = ["kind": "checkIn", "day": c.day]
        }
        return await add("checkin-\(c.day)", content)
    }

    /// One notification for everything that came due while paused.
    func deliverPauseSummary(_ items: [ReminderPayload], pausedSince: Date) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = "While notifications were paused"
        let names = items.prefix(3).map { "“\($0.title)”" }.joined(separator: ", ")
        content.body = items.count == 1 ? "\(names) came due." : "\(items.count) reminders came due, including \(names). Open Wren to review."
        content.sound = sound
        content.userInfo = ["kind": "pauseSummary"]
        content.threadIdentifier = "reminders"
        return await add("pause-summary-\(Int(Date().timeIntervalSince1970))", content)
    }

    /// "GPT finished: [query]. View result." The query is the user's own words, truncated.
    func deliverDelegation(_ r: DelegationRecord) async -> Bool {
        let content = UNMutableNotificationContent()
        let q = String(r.task.prefix(90)) + (r.task.count > 90 ? "…" : "")
        switch r.status {
        case .completed: content.title = "GPT has finished"; content.body = DelegationText.notificationLine(r)
        case .partial: content.title = "GPT stopped early: \(q)"; content.body = "Part of the answer was kept. View result or retry."
        case .cancelled: content.title = "GPT request cancelled: \(q)"; content.body = "View request."
        default: content.title = "GPT request failed: \(q)"; content.body = (r.error.map { String($0.prefix(140)) } ?? "View details.") + (r.canRetry ? " You can retry it." : "")
        }
        content.sound = sound
        content.categoryIdentifier = Category.delegation.rawValue
        content.userInfo = ["kind": "delegation", "delegationID": r.id.uuidString]
        content.threadIdentifier = "delegations"
        return await add("delegation-\(r.id.uuidString)-\(r.attempts)", content)
    }

    /// One new-mail alert: sender, subject and Wren's reason (never the body).
    func deliverMailAlert(id: String, title: String, body: String, canMarkRead: Bool, isSummary: Bool = false) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = sound
        content.categoryIdentifier = (isSummary ? Category.mailSummary : canMarkRead ? Category.mailWithRead : Category.mail).rawValue
        content.userInfo = ["kind": "mail", "messageID": id]
        content.threadIdentifier = "mail"
        return await add("mail-\(id)", content)
    }

    func deliverDigest(key: String, title: String, body: String) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = sound
        content.categoryIdentifier = Category.digest.rawValue
        content.userInfo = ["kind": "digest", "digestKey": key]
        content.threadIdentifier = "daily"
        return await add("digest-\(key)", content)
    }

    func withdrawMailAlert(id: String) { center.removeDeliveredNotifications(withIdentifiers: ["mail-\(id)"]) }

    /// Removes shown reminder notifications for an item (the immediate kind and the scheduled kinds).
    func withdrawReminder(id: UUID) {
        let scheduledPrefix = ReminderScheduler.prefix + id.uuidString
        center.getDeliveredNotifications { list in
            let ids = list.map(\.request.identifier).filter { $0 == "reminder-\(id.uuidString)" || $0.hasPrefix(scheduledPrefix) }
            if !ids.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    // MARK: ReminderNotificationCenter (requests macOS delivers on its own, even when Wren isn't running)

    func isAuthorized() async -> Bool { await refreshStatus(); return canDeliverNow }

    func pendingReminderIDs() async -> Set<String> {
        Set(await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(ReminderScheduler.prefix) })
    }

    func schedule(_ r: ReminderRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = r.title
        content.body = r.body
        content.sound = sound
        content.categoryIdentifier = (r.isAdvance ? Category.advance : Category.reminder).rawValue
        content.userInfo = ["commitmentID": r.commitmentID.uuidString]
        content.threadIdentifier = "reminders"
        let trigger: UNCalendarNotificationTrigger
        switch r.trigger {
        case let .at(date):
            // An exact instant: full date components in the current zone.
            var comps = Calendar.current.dateComponents(in: TimeZone.current, from: date)
            comps.nanosecond = nil
            trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        case let .repeating(comps):
            // Wall-clock components only, so it follows daylight-saving and time-zone changes.
            trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        }
        try await center.add(UNNotificationRequest(identifier: r.id, content: content, trigger: trigger))
    }

    func cancel(ids: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Debug and diagnostics: pending reminder requests with their next fire dates.
    func pendingReminderSummary() async -> [(String, Date?)] {
        await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(ReminderScheduler.prefix) }
            .map { ($0.identifier, ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()) }
    }

    func deliverInfo(_ title: String, _ body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        _ = await add("info-\(UUID().uuidString)", content)
    }

    private func add(_ id: String, _ content: UNMutableNotificationContent) async -> Bool {
        do { try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)); return true } catch {
            log.error("add failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: Delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let id = (info["commitmentID"] as? String).flatMap(UUID.init(uuidString:))
        let delegationID = (info["delegationID"] as? String).flatMap(UUID.init(uuidString:))
        let messageID = info["messageID"] as? String
        let digestKey = info["digestKey"] as? String
        let kind = info["kind"] as? String
        let actionID = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            let r: Response?
            if let delegationID, actionID == Action.viewResult.rawValue || actionID == UNNotificationDefaultActionIdentifier {
                onResponse?(.openDelegation(delegationID)); return
            }
            if let messageID {
                switch actionID {
                case Action.markRead.rawValue: onResponse?(.mail(.markRead(messageID)))
                case Action.dismissMail.rawValue: onResponse?(.mail(.dismiss(messageID)))
                case Action.snoozeMail.rawValue: onResponse?(.mail(.snooze(messageID)))
                case Action.openMail.rawValue: onResponse?(.mail(.open(messageID)))
                // A click on the alert opens that conversation in Gmail (the "N more" summary opens Wren's Inbox).
                case Action.openInGmail.rawValue, UNNotificationDefaultActionIdentifier:
                    onResponse?(.mail(messageID.hasPrefix("summary-") ? .open(messageID) : .openInGmail(messageID)))
                default: break
                }
                return
            }
            if let digestKey, actionID == Action.openDigest.rawValue || actionID == UNNotificationDefaultActionIdentifier {
                onResponse?(.mail(.openDigest(digestKey))); return
            }
            switch (actionID, id) {
            case (Action.done.rawValue, let id?): r = .done(id)
            case (Action.snoozeHour.rawValue, let id?): r = .snoozeHour(id)
            case (Action.later.rawValue, let id?): r = .later(id, text ?? "")
            case (Action.tomorrow.rawValue, let id?): r = .tomorrow(id)
            case (Action.openBriefing.rawValue, _): r = .openBriefing
            case (Action.review.rawValue, _): r = .reviewCheckIn
            case (Action.dismissCheckIn.rawValue, _): r = .dismissCheckIn
            case (UNNotificationDefaultActionIdentifier, _) where kind == "briefing": r = .openBriefing
            case (UNNotificationDefaultActionIdentifier, _) where kind == "checkIn": r = .reviewCheckIn
            case (UNNotificationDefaultActionIdentifier, let id?): r = .open(id)
            default: r = nil
            }
            if let r { onResponse?(r) }
        }
    }
}
