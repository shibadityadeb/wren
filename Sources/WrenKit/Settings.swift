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

/// What the experimental `?q=` link did in the user's browser, as they reported it.
enum PrefillCheck: String {
    case filledAndSent, filledNotSent, notFilled
    var filledIn: Bool { self != .notFilled }
    var label: String {
        switch self {
        case .filledAndSent: "You saw it filled in and sent"
        case .filledNotSent: "You saw it filled in, not sent"
        case .notFilled: "You saw an empty chat: the link doesn't work in your browser"
        }
    }
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
    /// A heads-up the day before a task's deadline, at the default reminder time. On unless turned off.
    var deadlineDayBefore: Bool {
        get { d.object(forKey: "deadlineDayBefore") as? Bool ?? true }
        set { d.set(newValue, forKey: "deadlineDayBefore") }
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
    /// Wren may open ChatGPT in the browser with your request (on by default since 0.11, when the
    /// website became where "ask GPT" goes; the old opt-in key was "chatgptEnabled").
    var chatgptHandoffEnabled: Bool {
        get { d.object(forKey: "chatgptWebEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "chatgptWebEnabled") }
    }
    /// Where an explicit "ask GPT" request runs. Default: the ChatGPT website.
    var chatgptMode: ChatGPTMode {
        get { d.string(forKey: "chatgptMode").flatMap(ChatGPTMode.init(rawValue:)) ?? .web }
        set { d.set(newValue.rawValue, forKey: "chatgptMode") }
    }
    /// Open ChatGPT with the question in its message box (`chatgpt.com/?q=`, undocumented by OpenAI;
    /// checked live on 2026-10-14: the question is taken in, not sent). On by default; off means
    /// copy-and-paste.
    var chatgptPrefill: Bool {
        get { d.object(forKey: "chatgptPrefillLink") as? Bool ?? true }
        set { d.set(newValue, forKey: "chatgptPrefillLink") }
    }
    /// Watch only the ChatGPT tab Wren opened (its address, via the browser's AppleScript) to know
    /// when the question was really sent and save the real conversation link. Opt-in.
    var chatgptDetectConversation: Bool {
        get { d.bool(forKey: "chatgptDetectConversation") }
        set { d.set(newValue, forKey: "chatgptDetectConversation") }
    }
    /// What the user saw when Wren opened a test link: nil until checked.
    var chatgptPrefillCheck: PrefillCheck? {
        get { d.string(forKey: "chatgptPrefillCheck").flatMap(PrefillCheck.init(rawValue:)) }
        set { d.set(newValue?.rawValue, forKey: "chatgptPrefillCheck") }
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
                          "voiceEnabled", "voiceHotKey", "pushToTalkEnabled", "pushToTalkHotKey", "voiceCheckBeforeRunning", "wakeWordEnabled", "macCalendarEnabled", "chatgptEnabled", "chatgptDestination", "chatgptModel", "openaiModel", "gmailCacheEnabled", "importantSenders", "mailPreferences", "voiceReviewFirst", "notificationSounds", "chatgptWebEnabled", "chatgptMode", "chatgptPrefill", "chatgptPrefillCheck", "chatgptPrefillLink", "chatgptDetectConversation", "deadlineDayBefore"]

    func resetAll() { Self.allKeys.forEach(d.removeObject(forKey:)) }

    /// Unsent text in the capture overlay, kept if the overlay is dismissed by clicking away.
    var captureDraft: String {
        get { d.string(forKey: "captureDraft") ?? "" }
        set { d.set(newValue, forKey: "captureDraft") }
    }
}
