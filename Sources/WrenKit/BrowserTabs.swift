import AppKit
import WrenCore

/// Reads the addresses of ChatGPT tabs in the default browser, through the browser's standard
/// AppleScript dictionary (macOS asks the user once: "Wren wants to control Google Chrome"). Only
/// tabs on chatgpt.com / openai.com are reported, filtered inside the script, so no other address
/// ever reaches Wren. Nothing on the page is read or clicked: no page content, cookies or private
/// ChatGPT interfaces. Used only when the user turned on conversation detection. With "Send it for
/// me" on, it also brings Wren's own ChatGPT tab to the front so a Return key press lands there.
enum BrowserTabs {
    /// Browsers whose tabs carry a stable `id` in AppleScript (Chromium family).
    static let supported: [String: String] = [
        "com.google.chrome": "Google Chrome",
        "com.google.chrome.canary": "Google Chrome Canary",
        "com.brave.browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "org.chromium.chromium": "Chromium",
        "com.vivaldi.vivaldi": "Vivaldi",
    ]

    /// The app that opens https links, if Wren can follow ChatGPT tabs in it.
    static var defaultBrowser: (bundleID: String, name: String)? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: ChatGPTWeb.home),
              let id = Bundle(url: app)?.bundleIdentifier?.lowercased(), let name = supported[id] else { return nil }
        return (id, name)
    }

    /// The default browser's display name, supported or not (for messages).
    static var defaultBrowserName: String {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: ChatGPTWeb.home) else { return "your browser" }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    enum Failure: Error, Equatable { case notPermitted, unavailable(String) }

    /// Brings the tab with this id to the front of its window, the window to the front and the browser
    /// forward. true only if that exact tab is then the front window's active tab.
    static func focus(tabID: String, bundleID: String) async -> Bool {
        guard tabID.allSatisfy(\.isNumber) else { return false }
        let source = """
        tell application id "\(bundleID)"
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    if (id of t as text) is "\(tabID)" then
                        set active tab index of w to i
                        set index of w to 1
                        activate
                        delay 0.3
                        return (id of active tab of front window as text)
                    end if
                end repeat
            end repeat
            return ""
        end tell
        """
        return await withCheckedContinuation { c in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                c.resume(returning: error == nil && result?.stringValue == tabID)
            }
        }
    }

    private static let queue = DispatchQueue(label: "com.shibadityadeb.wren.browser-tabs")

    /// ChatGPT/OpenAI tabs of the browser: id and address only. Runs off the main thread.
    static func chatGPTTabs(bundleID: String) async -> Result<[BrowserTab], Failure> {
        // The separator is made outside the browser's block: inside it, `tab` means the browser's tab
        // object, not a tab character (seen live: Chrome returned the word "tab").
        let source = """
        set sep to (ASCII character 9)
        tell application id "\(bundleID)"
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set u to URL of t
                    if u contains "chatgpt.com" or u contains "openai.com" then set out to out & (id of t as text) & sep & u & linefeed
                end repeat
            end repeat
            return out
        end tell
        """
        return await withCheckedContinuation { c in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
                    // -1743: the user hasn't allowed Wren to control the browser (or turned it off).
                    c.resume(returning: .failure(code == -1743 || code == -1744 ? .notPermitted : .unavailable("AppleScript error \(code)")))
                    return
                }
                let lines = (result?.stringValue ?? "").split(separator: "\n")
                c.resume(returning: .success(lines.compactMap { line in
                    let parts = line.split(separator: "\t", maxSplits: 1)
                    return parts.count == 2 ? BrowserTab(id: String(parts[0]), url: String(parts[1])) : nil
                }))
            }
        }
    }
}

/// Presses Return in the browser for "Send it for me". Needs Accessibility permission, which only the
/// user can grant (System Settings › Privacy & Security › Accessibility). The key goes to that browser's
/// process only, and only while it is the frontmost app, so it can never land in another app.
enum KeyPresser {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own prompt that leads to the Accessibility list. Nothing is granted by Wren.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func pressReturn(inBrowser bundleID: String) -> Bool {
        guard isTrusted, let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier?.lowercased() == bundleID.lowercased() else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else { return false }
        // A plain Return: no modifier still held from the shortcut (⌥ Return would add a new line).
        down.flags = []; up.flags = []
        down.postToPid(app.processIdentifier)
        up.postToPid(app.processIdentifier)
        return true
    }
}
