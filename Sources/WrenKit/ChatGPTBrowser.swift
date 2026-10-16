import AppKit
import WrenCore
import os

/// Opens ChatGPT pages in the browser profile the user chose (Connectors › ChatGPT › Open ChatGPT in),
/// so a question goes to their personal ChatGPT account, not to whichever profile (school, work) was
/// last in front. Without a choice, or when the browser can't do it, the link opens as usual.
@MainActor
enum ChatGPTBrowser {
    /// Profiles of the default browser, when it's a Chromium browser with more than one.
    static var profiles: [BrowserProfile] {
        guard let b = BrowserTabs.defaultBrowser else { return [] }
        let p = BrowserProfiles.profiles(bundleID: b.bundleID)
        return p.count > 1 ? p : []
    }

    /// true when the page was handed to a browser.
    @discardableResult
    static func open(_ url: URL, profile: String?) -> Bool {
        if let profile, let app = NSWorkspace.shared.urlForApplication(toOpen: url),
           let id = Bundle(url: app)?.bundleIdentifier?.lowercased(), BrowserProfiles.dataFolders[id] != nil,
           BrowserProfiles.profiles(bundleID: id).contains(where: { $0.directory == profile }),
           let args = BrowserProfiles.openArguments(appPath: app.path, profile: profile, url: url) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = args
            do {
                try p.run()
                Logger(subsystem: "com.shibadityadeb.wren", category: "app").notice("ChatGPT opened in the chosen browser profile")
                return true
            } catch {
                Logger(subsystem: "com.shibadityadeb.wren", category: "app").error("couldn't open the chosen profile: \(error.localizedDescription, privacy: .public); opening normally")
            }
        }
        return NSWorkspace.shared.open(url)
    }
}

extension AppModel {
    /// Every ChatGPT page Wren opens goes through here.
    @discardableResult
    func openChatGPTPage(_ url: URL) -> Bool { ChatGPTBrowser.open(url, profile: settings.chatgptBrowserProfile) }
}
