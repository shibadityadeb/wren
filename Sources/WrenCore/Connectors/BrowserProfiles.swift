import Foundation

/// One profile of a Chromium-family browser (Chrome, Brave, Edge…), as the browser lists it in its
/// "Local State" file. Each profile has its own cookies, so its own ChatGPT sign-in.
public struct BrowserProfile: Equatable, Sendable, Identifiable {
    /// The folder name the browser uses ("Default", "Profile 1"); what `--profile-directory` takes.
    public var directory: String
    public var name: String
    /// The Google account the profile is signed in to, when there is one.
    public var email: String?
    public var id: String { directory }
    public var label: String { email.map { "\(name) (\($0))" } ?? name }
}

public enum BrowserProfiles {
    /// Where each supported browser keeps its profiles, under ~/Library/Application Support.
    public static let dataFolders: [String: String] = [
        "com.google.chrome": "Google/Chrome",
        "com.google.chrome.canary": "Google/Chrome Canary",
        "com.brave.browser": "BraveSoftware/Brave-Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "org.chromium.chromium": "Chromium",
        "com.vivaldi.vivaldi": "Vivaldi",
    ]

    /// Profiles from a "Local State" file, in the browser's own order when it records one.
    public static func parse(_ localState: Data) -> [BrowserProfile] {
        guard let root = try? JSONSerialization.jsonObject(with: localState) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: [String: Any]] else { return [] }
        let order = (profile["profiles_order"] as? [String]) ?? []
        let dirs = cache.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? Int.max, ib = order.firstIndex(of: b) ?? Int.max
            return ia != ib ? ia < ib : a.localizedStandardCompare(b) == .orderedAscending
        }
        return dirs.compactMap { dir in
            guard isSafeDirectory(dir), let info = cache[dir] else { return nil }
            let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? dir
            let email = (info["user_name"] as? String).flatMap { $0.contains("@") ? $0 : nil }
            return BrowserProfile(directory: dir, name: name, email: email)
        }
    }

    public static func profiles(bundleID: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [BrowserProfile] {
        guard let folder = dataFolders[bundleID.lowercased()] else { return [] }
        let url = home.appendingPathComponent("Library/Application Support/\(folder)/Local State")
        return (try? Data(contentsOf: url)).map(parse) ?? []
    }

    /// The folder names Chromium browsers create ("Default", "Profile 1"…), and nothing else, so a
    /// name can't carry anything else into the browser's arguments.
    static func isSafeDirectory(_ d: String) -> Bool {
        d.range(of: "^(Default|Profile [0-9]{1,5})$", options: .regularExpression) != nil
    }

    /// Arguments for `/usr/bin/open` that open `url` in that profile of the browser at `appPath`. A
    /// running browser receives it in its existing process and uses that profile's window.
    public static func openArguments(appPath: String, profile: String, url: URL) -> [String]? {
        guard isSafeDirectory(profile), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return ["-na", appPath, "--args", "--profile-directory=\(profile)", url.absoluteString]
    }
}
