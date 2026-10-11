import Foundation

/// App-level integration settings that Wren's maintainers register with each provider and inject into
/// the app bundle at build time (`scripts/build-app.sh` writes them to Info.plist from an uncommitted
/// file or CI secrets). Users never see or enter any of this. A missing value means this copy of Wren
/// was built without that provider, which is reported as a blocker for the maintainers, not as a
/// setup task for the user.
public struct ProviderConfig: Equatable, Sendable {
    public var google: GoogleOAuthConfig?
    public var notion: NotionOAuthConfig?

    public init(google: GoogleOAuthConfig? = nil, notion: NotionOAuthConfig? = nil) { self.google = google; self.notion = notion }

    public enum Key {
        public static let googleClientID = "WrenGoogleClientID"
        public static let notionClientID = "WrenNotionClientID"
        public static let notionRelay = "WrenNotionOAuthRelay"
    }

    /// Reads and validates the injected values. Anything malformed counts as not configured.
    public static func from(_ info: [String: Any]) -> ProviderConfig {
        func value(_ k: String) -> String? {
            guard let v = (info[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty, !v.hasPrefix("$(") else { return nil }
            return v
        }
        var out = ProviderConfig()
        if let id = value(Key.googleClientID) {
            let c = GoogleOAuthConfig(clientID: id)
            if c.isPlausible { out.google = c }
        }
        if let id = value(Key.notionClientID), let relay = value(Key.notionRelay).flatMap(URL.init(string:)) {
            let c = NotionOAuthConfig(clientID: id, relay: relay)
            if c.isPlausible { out.notion = c }
        }
        return out
    }

    public static var bundled: ProviderConfig { from(Bundle.main.infoDictionary ?? [:]) }

    /// Plain-language blocker shown when a provider isn't in this build.
    public static func notInBuild(_ provider: String, feature: String) -> String {
        "This copy of Wren was built without \(provider) sign-in, so \(feature) can't be connected here. There's nothing for you to set up: Wren's maintainers have to enable it in the build you download."
    }
}
