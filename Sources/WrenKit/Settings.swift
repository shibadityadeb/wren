import Foundation
import Carbon.HIToolbox
import WrenCore

/// A global shortcut as Carbon understands it, plus a display string.
public struct HotKeySpec: Codable, Equatable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32
    public var display: String

    public static let optionSpace = HotKeySpec(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey), display: "⌥ Space")
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
    /// The user's explicit choice. Default false: Wren never adds itself to login items unasked.
    var launchAtLogin: Bool {
        get { d.bool(forKey: "launchAtLogin") }
        set { d.set(newValue, forKey: "launchAtLogin") }
    }
    /// Unsent text in the capture overlay, kept if the overlay is dismissed by clicking away.
    var captureDraft: String {
        get { d.string(forKey: "captureDraft") ?? "" }
        set { d.set(newValue, forKey: "captureDraft") }
    }
}
