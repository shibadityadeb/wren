import AppKit
import UserNotifications
import WrenCore
import os

/// Native notifications. Delivery is best effort: Focus modes, Do Not Disturb and
/// System Settings can suppress banners, and Wren never claims otherwise.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate, WrenNotifier {
    enum Category: String { case reminder = "WREN_REMINDER", briefing = "WREN_BRIEFING", checkIn = "WREN_CHECKIN", checkInItem = "WREN_CHECKIN_ITEM" }
    enum Action: String {
        case done = "WREN_DONE", snoozeHour = "WREN_SNOOZE_1H", later = "WREN_LATER", tomorrow = "WREN_TOMORROW"
        case openBriefing = "WREN_OPEN_BRIEFING", review = "WREN_REVIEW", dismissCheckIn = "WREN_DISMISS_CHECKIN"
    }

    enum Response {
        case done(UUID), snoozeHour(UUID), later(UUID, String), tomorrow(UUID), open(UUID)
        case openBriefing, reviewCheckIn, dismissCheckIn
    }

    /// Resolved lazily: UNUserNotificationCenter requires a real app bundle.
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }
    private let log = Logger(subsystem: "com.shibadityadeb.wren", category: "notifications")
    var onResponse: ((Response) -> Void)?
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
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.reminder.rawValue, actions: [done, hour, later], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.briefing.rawValue, actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.checkIn.rawValue, actions: [review, dismiss], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.checkInItem.rawValue, actions: [done, tomorrow, later, dismiss], intentIdentifiers: []),
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
        content.sound = .default
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
        content.sound = .default
        content.categoryIdentifier = Category.briefing.rawValue
        content.userInfo = ["kind": "briefing", "day": b.day]
        content.threadIdentifier = "daily"
        return await add("briefing-\(b.day)", content)
    }

    func deliverCheckIn(_ c: CheckIn) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = c.title
        content.body = c.notificationBody
        content.sound = .default
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

    func withdrawReminder(id: UUID) {
        center.removeDeliveredNotifications(withIdentifiers: ["reminder-\(id.uuidString)"])
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
        let kind = info["kind"] as? String
        let actionID = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            let r: Response?
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
