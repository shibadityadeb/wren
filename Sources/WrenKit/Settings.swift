import Foundation
import Carbon.HIToolbox
import WrenCore

/// A global shortcut as Carbon understands it, plus a display string.
public struct HotKeySpec: Codable, Equatable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32
    public var display: String

    /// Default push-to-talk shortcut: hold ⌥ Space to speak, release to run.
    public static let optionSpace = HotKeySpec(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey), display: "⌥ Space")
    /// Fallback typed-capture shortcut when push-to-talk uses ⌥⇧ Space.
    public static let controlOptionSpace = HotKeySpec(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey), display: "⌃⌥ Space")
    /// Default typed-capture shortcut since 0.10.1 (it was ⌥ Space before push-to-talk took that).
    public static let optionShiftSpace = HotKeySpec(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey | shiftKey), display: "⌥⇧ Space")
}

/// User preferences, persisted in UserDefaults. Personal data never goes here.
@MainActor
final class WrenSettings {
    private let d = UserDefaults.standard

    var hotKeyEnabled: Bool {
        get { d.object(forKey: "hotKeyEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "hotKeyEnabled") }
    }
    /// The typed-capture shortcut. A saved one that clashes with push-to-talk (⌥ Space was the old
    /// default) gives way to ⌥⇧ Space, so the two never fight over one key combination.
    var hotKey: HotKeySpec {
        get {
            let saved = (d.data(forKey: "hotKey")).flatMap { try? JSONDecoder().decode(HotKeySpec.self, from: $0) }
            let wanted = saved ?? .optionShiftSpace
            guard voiceEnabled, wanted == voiceHotKey else { return wanted }
            return [HotKeySpec.optionShiftSpace, .controlOptionSpace].first { $0 != voiceHotKey } ?? .controlOptionSpace
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "hotKey") }
    }
    var modelName: String? {
        get { d.string(forKey: "ollamaModel") }
        set { d.set(newValue, forKey: "ollamaModel") }
    }
    var useModel: Bool {
        get { d.object(forKey: "useModel") as? Bool ?? true }
        set { d.set(newValue, forKey: "useModel") }
    }
    var dateOnlyReminderHour: Int {
        get { d.object(forKey: "dateOnlyReminderHour") as? Int ?? 10 }
        set { d.set(min(max(newValue, 6), 21), forKey: "dateOnlyReminderHour") }
    }
    var daily: DailySettings {
        get { (d.data(forKey: "dailySettings")).flatMap { try? JSONDecoder().decode(DailySettings.self, from: $0) } ?? DailySettings() }
        set { d.set(try? JSONEncoder().encode(newValue.normalized()), forKey: "dailySettings") }
    }
    var insights: InsightSettings {
        get { (d.data(forKey: "insightSettings")).flatMap { try? JSONDecoder().decode(InsightSettings.self, from: $0) } ?? InsightSettings() }
        set { d.set(try? JSONEncoder().encode(newValue.normalized()), forKey: "insightSettings") }
    }
    /// The user's explicit choice. Default false: Wren never adds itself to login items unasked.
    var launchAtLogin: Bool {
        get { d.bool(forKey: "launchAtLogin") }
        set { d.set(newValue, forKey: "launchAtLogin") }
    }
    var pause: NotificationPause? {
        get { (d.data(forKey: "notificationPause")).flatMap { try? JSONDecoder().decode(NotificationPause.self, from: $0) } }
        set {
            if let newValue { d.set(try? JSONEncoder().encode(newValue), forKey: "notificationPause") } else { d.removeObject(forKey: "notificationPause") }
        }
    }
    var lastAutomaticBackup: Date? {
        get { d.object(forKey: "lastAutomaticBackup") as? Date }
        set { d.set(newValue, forKey: "lastAutomaticBackup") }
    }
    /// Push-to-talk shortcut on (default since 0.10.1; the old "voiceEnabled" key defaulted to off).
    var voiceEnabled: Bool {
        get { d.object(forKey: "pushToTalkEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "pushToTalkEnabled") }
    }
    /// Read calendars from macOS (EventKit).
    var macCalendarEnabled: Bool {
        get { d.bool(forKey: "macCalendarEnabled") }
        set { d.set(newValue, forKey: "macCalendarEnabled") }
    }
    /// Before 0.10 Wren could listen for "Hey Wren" in the background. That listener was removed:
    /// voice now starts only from the shortcut or a Voice button. The old preference is deleted so
    /// nothing can turn continuous listening back on.
    /// Also drops the 0.10.0 voice keys, replaced by push-to-talk's (different defaults).
    func removeRetiredPreferences() { ["wakeWordEnabled", "voiceEnabled", "voiceHotKey", "voiceReviewFirst"].forEach(d.removeObject(forKey:)) }
    /// Play a sound with Wren's notifications (reminders, GPT results, email alerts, digests).
    var notificationSounds: Bool {
        get { d.object(forKey: "notificationSounds") as? Bool ?? true }
        set { d.set(newValue, forKey: "notificationSounds") }
    }
    var voiceHotKey: HotKeySpec {
        get { (d.data(forKey: "pushToTalkHotKey")).flatMap { try? JSONDecoder().decode(HotKeySpec.self, from: $0) } ?? .optionSpace }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "pushToTalkHotKey") }
    }
    /// The optional copy-and-open handoff fallback (key kept from earlier versions).
    var chatgptHandoffEnabled: Bool {
        get { d.bool(forKey: "chatgptEnabled") }
        set { d.set(newValue, forKey: "chatgptEnabled") }
    }
    /// "app" (ChatGPT for Mac, if installed) or "browser".
    var chatgptDestination: String {
        get { d.string(forKey: "chatgptDestination") ?? "browser" }
        set { d.set(newValue, forKey: "chatgptDestination") }
    }
    /// The model slug chosen from the list ChatGPT returned for this account.
    var chatgptModel: String? {
        get { d.string(forKey: "chatgptModel") }
        set { d.set(newValue, forKey: "chatgptModel") }
    }
    var gmailCacheEnabled: Bool {
        get { d.bool(forKey: "gmailCacheEnabled") }
        set { d.set(newValue, forKey: "gmailCacheEnabled") }
    }
    var importantSenders: [String] {
        get { d.stringArray(forKey: "importantSenders") ?? [] }
        set { d.set(newValue, forKey: "importantSenders") }
    }
    /// Off (default): a clearly heard command runs as soon as it's transcribed. On: the transcript waits
    /// for Return. (A low-confidence transcript always waits.)
    var voiceReviewFirst: Bool {
        get { d.object(forKey: "voiceCheckBeforeRunning") as? Bool ?? false }
        set { d.set(newValue, forKey: "voiceCheckBeforeRunning") }
    }
    var mail: MailPreferences {
        get { (d.data(forKey: "mailPreferences")).flatMap { try? JSONDecoder().decode(MailPreferences.self, from: $0) } ?? MailPreferences() }
        set { d.set(try? JSONEncoder().encode(newValue.normalized()), forKey: "mailPreferences") }
    }
    /// Every preference key Wren writes. "Reset preferences" removes exactly these.
    static let allKeys = ["hotKeyEnabled", "hotKey", "ollamaModel", "useModel", "dateOnlyReminderHour", "captureDraft",
                          "dailySettings", "launchAtLogin", "insightSettings", "notificationPause", "lastAutomaticBackup",
                          "voiceEnabled", "voiceHotKey", "pushToTalkEnabled", "pushToTalkHotKey", "voiceCheckBeforeRunning", "wakeWordEnabled", "macCalendarEnabled", "chatgptEnabled", "chatgptDestination", "chatgptModel", "openaiModel", "gmailCacheEnabled", "importantSenders", "mailPreferences", "voiceReviewFirst", "notificationSounds"]

    func resetAll() { Self.allKeys.forEach(d.removeObject(forKey:)) }

    /// Unsent text in the capture overlay, kept if the overlay is dismissed by clicking away.
    var captureDraft: String {
        get { d.string(forKey: "captureDraft") ?? "" }
        set { d.set(newValue, forKey: "captureDraft") }
    }
}
