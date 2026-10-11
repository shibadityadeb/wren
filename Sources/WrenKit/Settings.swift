import Foundation
import Carbon.HIToolbox
import WrenCore

/// A global shortcut as Carbon understands it, plus a display string.
public struct HotKeySpec: Codable, Equatable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32
    public var display: String

    public static let optionSpace = HotKeySpec(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey), display: "⌥ Space")
    /// Default push-to-talk: hold ⌥⇧Space.
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
    var hotKey: HotKeySpec {
        get { (d.data(forKey: "hotKey")).flatMap { try? JSONDecoder().decode(HotKeySpec.self, from: $0) } ?? .optionSpace }
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
    var voiceEnabled: Bool {
        get { d.bool(forKey: "voiceEnabled") }
        set { d.set(newValue, forKey: "voiceEnabled") }
    }
    /// Listen for "Hey Wren" in the background (opt-in, off by default).
    var wakeWordEnabled: Bool {
        get { d.bool(forKey: "wakeWordEnabled") }
        set { d.set(newValue, forKey: "wakeWordEnabled") }
    }
    var voiceHotKey: HotKeySpec {
        get { (d.data(forKey: "voiceHotKey")).flatMap { try? JSONDecoder().decode(HotKeySpec.self, from: $0) } ?? .optionShiftSpace }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "voiceHotKey") }
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
    /// Every preference key Wren writes. "Reset preferences" removes exactly these.
    static let allKeys = ["hotKeyEnabled", "hotKey", "ollamaModel", "useModel", "dateOnlyReminderHour", "captureDraft",
                          "dailySettings", "launchAtLogin", "insightSettings", "notificationPause", "lastAutomaticBackup",
                          "voiceEnabled", "voiceHotKey", "wakeWordEnabled", "chatgptEnabled", "chatgptDestination", "chatgptModel", "openaiModel", "gmailCacheEnabled", "importantSenders"]

    func resetAll() { Self.allKeys.forEach(d.removeObject(forKey:)) }

    /// Unsent text in the capture overlay, kept if the overlay is dismissed by clicking away.
    var captureDraft: String {
        get { d.string(forKey: "captureDraft") ?? "" }
        set { d.set(newValue, forKey: "captureDraft") }
    }
}
