import SwiftUI
import WrenCore

/// Settings › Keyboard shortcuts: every key that opens or does something in Wren, with the user's
/// own capture and push-to-talk combinations (read from Settings, so this page never goes stale).
struct ShortcutsView: View {
    var model: AppModel

    var body: some View {
        let s = model.settings
        VStack(spacing: 0) {
            PaneHeader(model: model, title: "Keyboard shortcuts")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    group("Anywhere on your Mac (Wren running, even with its window closed)", [
                        (s.voiceEnabled ? "Hold \(s.voiceHotKey.display)" : "Push-to-talk off", "Talk to Wren: hold, speak, let go"),
                        (s.hotKeyEnabled ? s.hotKey.display : "Capture shortcut off", "Type to Wren: opens the capture panel"),
                    ], note: "Change or turn these off: push-to-talk in Connectors › Voice, the capture shortcut in Settings.")
                    group("Go to (in Wren's window)", MainWindowView.Section.allCases.enumerated().map { i, sec in ("⌘\(i + 1)", sec.rawValue) })
                    group("Wren", [
                        ("⌘N", "New capture"),
                        ("⌘0", "Open Wren's window"),
                        ("⌘,", "Settings"),
                        ("⌘/", "This page"),
                        ("⌘W", "Close the window (Wren keeps running in the menu bar)"),
                        ("⌘H", "Hide Wren"),
                        ("⌘Q", "Quit Wren (stops recording and email checks; scheduled reminders still arrive)"),
                        ("⌘?", "Help"),
                    ])
                    group("In the capture panel", [
                        ("Return", "Run what's in the field; after a result, Done"),
                        ("Esc", "Cancel a recording, or close the panel"),
                        ("Voice button", "Record with a click instead of holding the keys"),
                    ])
                    group("Menu-bar bird", [
                        ("Click", "Quick list and add field"),
                        ("Right-click or Control-click", "Open Wren, New Capture, Voice Command, Settings, Quit"),
                    ])
                    group("In notifications", [
                        ("Reminder", "Done · Remind me in 1 hour · Remind me at… (type 9pm, tomorrow 10am)"),
                        ("Important email", "Click opens it in Gmail · Show in Wren · Snooze alert · Dismiss"),
                    ])
                    Link("All shortcuts and things to say, on the web", destination: URL(string: "https://wrenai.vercel.app/shortcuts/")!).font(.callout)
                }
                .padding(14)
            }
        }
    }

    func group(_ title: String, _ rows: [(String, String)], note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(rows.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(rows[i].0).font(.callout.monospaced()).frame(width: 190, alignment: .leading)
                    Text(rows[i].1).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
