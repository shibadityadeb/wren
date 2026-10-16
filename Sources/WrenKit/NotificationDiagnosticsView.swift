import SwiftUI
import UserNotifications
import WrenCore

/// Settings › Notifications: what macOS really allows and holds, where a reminder would stop, and a
/// real test notification. Every line is read from macOS or Wren's store, never assumed.
struct NotificationDiagnosticsView: View {
    @Bindable var model: AppModel

    var body: some View {
        let h = model.notificationHealth
        let r = model.reminderSync
        let d = model.notificationDiagnosis
        VStack(alignment: .leading, spacing: 6) {
            row("macOS permission", h?.permissionText ?? permissionFallback, warn: !(h?.allowed ?? false))
            if let h, h.allowed { row("Alert style", h.styleText, warn: h.bannersOff) }
            row("Reminders expected", "\(r.expected)")
            row("Pending in macOS", "\(r.pending)" + (r.checkedAt.map { " (checked \($0.formatted(date: .omitted, time: .shortened)))" } ?? ""), warn: r.pending < r.expected)
            row("Next reminder", model.nextReminderText)
            row("Day-before heads-up", model.deadlineAdvance == nil ? "Off" : "On, at \(model.reminderHour):00")
            if let e = r.lastError { row("Last scheduling error", e, warn: true) }
            row("Status", d.stage, warn: d != .ok)
            if let m = d.message { Text(m).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if h?.bannersOff == true {
                Text("Wren's alert style is None, so macOS puts its notifications in Notification Center without showing a banner. Choose Banners or Alerts in System Settings › Notifications › Wren.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Send test notification") { model.sendTestNotification() }
                    .disabled(isTesting)
                Button("Open Notification Settings") { NSWorkspace.shared.open(AppModel.systemNotificationSettingsURL) }
                Button("Focus Settings") { NSWorkspace.shared.open(AppModel.focusSettingsURL) }
                Spacer()
                Button("Refresh") { Task { await model.refreshNotificationHealth() } }.buttonStyle(.link)
            }
            testLine
            Text("Accepted by macOS means it's scheduled. Delivered means macOS put it in Notification Center. During Do Not Disturb or a Focus that doesn't allow Wren, it's delivered without a banner or sound. Allow Wren in System Settings › Focus to see banners then.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let h {
                Text("Settings belong to \(h.bundleID) at \(h.appPath). A copy of Wren built or installed elsewhere has its own notification permission.")
                    .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await model.refreshNotificationHealth() }
    }

    var permissionFallback: String {
        switch model.notificationStatus {
        case .authorized, .provisional: "Allowed"
        case .denied: "Turned off in System Settings"
        default: "Not asked yet"
        }
    }

    var isTesting: Bool { if case .scheduled = model.testNotification { true } else { false } }

    @ViewBuilder var testLine: some View {
        switch model.testNotification {
        case .idle: EmptyView()
        case let .scheduled(_, fireAt, pending):
            Text(pending ? "Accepted by macOS and pending. It should appear at \(fireAt.formatted(date: .omitted, time: .standard))…" : "macOS accepted it but doesn't list it as pending.")
                .font(.caption).foregroundStyle(pending ? Color.secondary : Color.orange)
        case let .delivered(at):
            Text("Delivered at \(at.formatted(date: .omitted, time: .standard)): macOS put it in Notification Center. If no banner appeared, Do Not Disturb, a Focus or the alert style hid it.")
                .font(.caption).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
        case .notDelivered:
            Text("macOS accepted the test but didn't report it delivered. Check that Wren is allowed in System Settings › Notifications.")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case let .refused(m):
            Text("macOS refused the test notification: \(m)").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    func row(_ label: String, _ value: String, warn: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value).font(.caption).foregroundStyle(warn ? Color.orange : Color.primary).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
