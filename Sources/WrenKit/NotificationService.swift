import AppKit
import UserNotifications
import os

/// Native notifications. Delivery is best effort: Focus modes, Do Not Disturb and
/// System Settings can suppress banners, and Wren never claims otherwise.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let category = "WREN_REMINDER"
    enum Action: String { case done = "WREN_DONE", snoozeHour = "WREN_SNOOZE_1H", later = "WREN_LATER" }

    enum Response {
        case done(UUID), snoozeHour(UUID), later(UUID, String), open(UUID)
    }

    /// Resolved lazily: UNUserNotificationCenter requires a real app bundle, and
    /// offscreen rendering tools construct this service without one.
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
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [done, hour, later],
                                                                 intentIdentifiers: [], options: [])])
    }

    @discardableResult
    func refreshStatus() async -> UNAuthorizationStatus {
        status = await center.notificationSettings().authorizationStatus
        return status
    }

    /// Shows the macOS permission prompt (only the first time; afterwards macOS answers silently).
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

    var canDeliver: Bool { status == .authorized || status == .provisional }

    /// Hands a reminder to macOS. Returns true only if macOS accepted the request.
    func deliverReminder(id: UUID, title: String, body: String, late: Bool) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.userInfo = ["commitmentID": id.uuidString]
        content.threadIdentifier = "reminders"
        if late { content.subtitle = "Missed while your Mac was asleep or Wren wasn't running" }
        let request = UNNotificationRequest(identifier: "reminder-\(id.uuidString)", content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            log.error("add failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func deliverInfo(_ title: String, _ body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        try? await center.add(UNNotificationRequest(identifier: "info-\(UUID().uuidString)", content: content, trigger: nil))
    }

    /// Removes a delivered reminder from Notification Center once the item is closed or rescheduled.
    func withdraw(id: UUID) {
        center.removeDeliveredNotifications(withIdentifiers: ["reminder-\(id.uuidString)"])
    }

    // MARK: Delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["commitmentID"] as? String, let id = UUID(uuidString: raw) else { return }
        let actionID = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            let r: Response
            switch actionID {
            case Action.done.rawValue: r = .done(id)
            case Action.snoozeHour.rawValue: r = .snoozeHour(id)
            case Action.later.rawValue: r = .later(id, text ?? "")
            default: r = .open(id)
            }
            onResponse?(r)
        }
    }
}
