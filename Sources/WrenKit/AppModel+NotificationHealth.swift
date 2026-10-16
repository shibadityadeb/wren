import AppKit
import UserNotifications
import WrenCore

/// Where a reminder's journey stops, in the order it happens.
enum NotificationDiagnosis: Equatable {
    case ok
    /// Wren's database isn't available, so nothing was saved to schedule.
    case persistence(String)
    /// macOS permission is missing or off.
    case authorization(String)
    /// macOS refused one or more requests.
    case scheduling(String)
    /// Fewer requests are pending in macOS than Wren's reminders call for.
    case reconciliation(String)
    /// The test notification was accepted but macOS never reported it delivered.
    case delivery(String)

    var stage: String {
        switch self {
        case .ok: "Working"
        case .persistence: "Saving"
        case .authorization: "Permission"
        case .scheduling: "Scheduling"
        case .reconciliation: "Check against macOS"
        case .delivery: "Delivery"
        }
    }
    var message: String? {
        switch self {
        case .ok: nil
        case let .persistence(m), let .authorization(m), let .scheduling(m), let .reconciliation(m), let .delivery(m): m
        }
    }
}

enum TestNotificationState: Equatable {
    case idle
    case scheduled(id: String, fireAt: Date, pending: Bool)
    /// macOS lists it in Notification Center: delivered. A banner may still have been hidden by Focus.
    case delivered(at: Date)
    /// Accepted and its time passed, but macOS doesn't list it as delivered.
    case notDelivered
    case refused(String)
}

@MainActor
extension AppModel {
    static let systemNotificationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(AppIdentity.bundleID)")!
    static let focusSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!

    func refreshNotificationHealth() async {
        // UNUserNotificationCenter needs a real app bundle (design snapshots run without one).
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let h = await notifications.health()
        notificationHealth = h
        notificationStatus = h.status
        await reconcileReminders()
    }

    var notificationDiagnosis: NotificationDiagnosis {
        if let storeError { return .persistence("Wren's database isn't available (\(storeError)), so reminders can't be saved or scheduled.") }
        switch notificationStatus {
        case .denied: return .authorization("macOS notifications are turned off for Wren. Reminders can only show inside Wren until you turn them on in System Settings › Notifications › Wren.")
        case .notDetermined: return .authorization("Wren hasn't been allowed to send notifications yet. Choose Allow…")
        default: break
        }
        let r = reminderSync
        if !r.failed.isEmpty { return .scheduling("macOS refused \(r.failed.count) reminder request\(r.failed.count == 1 ? "" : "s")\(r.lastError.map { ": \($0)" } ?? "."). Wren retries on the next change or launch.") }
        if r.pending < r.expected { return .reconciliation("Wren expects \(r.expected) scheduled notification\(r.expected == 1 ? "" : "s") but macOS holds \(r.pending).") }
        if case .notDelivered = testNotification { return .delivery("macOS accepted the test notification but never reported it delivered.") }
        return .ok
    }

    /// Schedules a real notification `seconds` ahead, then checks with macOS that it was delivered.
    func sendTestNotification(after seconds: TimeInterval = 10) {
        Task {
            if notificationStatus == .notDetermined { _ = await notifications.requestPermission(); notificationStatus = notifications.status }
            let r = await notifications.scheduleTest(after: seconds)
            guard r.accepted else { testNotification = .refused(r.error ?? "macOS refused it."); return }
            let fireAt = Date().addingTimeInterval(seconds)
            testNotification = .scheduled(id: r.id, fireAt: fireAt, pending: r.pending)
            log.notice("test notification scheduled for \(Int(seconds), privacy: .public) s; pending=\(r.pending, privacy: .public)")
            try? await Task.sleep(nanoseconds: UInt64((seconds + 4) * 1_000_000_000))
            let delivered = await notifications.wasDelivered(r.id)
            testNotification = delivered ? .delivered(at: fireAt) : .notDelivered
            log.notice("test notification delivered=\(delivered, privacy: .public)")
            await refreshNotificationHealth()
        }
    }

    /// One line for "next reminder".
    var nextReminderText: String {
        guard let d = reminderSync.nextFire else { return "None scheduled" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}
