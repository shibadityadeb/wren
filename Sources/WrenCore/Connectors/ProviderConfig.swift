import Foundation

/// App-level integration settings that Wren's maintainers register with each provider and inject into
/// the app bundle at build time (`scripts/build-app.sh` writes them to Info.plist from an uncommitted
/// file or CI secrets). Users never see or enter any of this. A missing value means this copy of Wren
/// was built without that provider, which is reported as a blocker for the maintainers, not as a
/// setup task for the user.
public struct ProviderConfig: Equatable, Sendable {
    public var google: GoogleOAuthConfig?
    /// Where Wren's Google app is in Google's process. It decides what Wren tells users to expect.
    public var googleStatus: GoogleAppStatus = .testing
    public var googleVerified: Bool { googleStatus == .verified }

    public init(google: GoogleOAuthConfig? = nil) { self.google = google }

    public enum Key {
        public static let googleClientID = "WrenGoogleClientID"
        public static let googleClientSecret = "WrenGoogleClientSecret"
        public static let googleStatus = "WrenGoogleStatus"
    }

    /// Reads and validates the injected values. Anything malformed counts as not configured.
    public static func from(_ info: [String: Any]) -> ProviderConfig {
        func value(_ k: String) -> String? {
            guard let v = (info[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty, !v.hasPrefix("$(") else { return nil }
            return v
        }
        var out = ProviderConfig()
        if let id = value(Key.googleClientID) {
            let c = GoogleOAuthConfig(clientID: id, clientSecret: value(Key.googleClientSecret))
            if c.isPlausible { out.google = c }
        }
        out.googleStatus = value(Key.googleStatus).flatMap(GoogleAppStatus.init(rawValue:)) ?? .testing
        return out
    }

    public static var bundled: ProviderConfig { from(Bundle.main.infoDictionary ?? [:]) }

    /// Plain-language blocker shown when a provider isn't in this build.
    public static func notInBuild(_ provider: String, feature: String) -> String {
        "This copy of Wren was built without \(provider) sign-in, so \(feature) can't be connected here. There's nothing for you to set up: Wren's maintainers have to enable it in the build you download."
    }
}

/// Google's publishing state for Wren's OAuth app.
public enum GoogleAppStatus: String, Sendable, Equatable {
    /// Only listed test users can connect, and Google asks them to reconnect every 7 days.
    case testing
    /// Published but not verified: anyone can connect (Google caps it at 100 users) after Google's
    /// "Google hasn't verified this app" screen.
    case unverified
    /// Google approved Wren's verification.
    case verified

    /// What users should expect, in plain words. nil when there's nothing to say.
    public var userNotice: String? {
        switch self {
        case .testing:
            "Wren's Google connection is in testing. Only Google accounts the Wren team added can connect, and Google asks you to connect again every 7 days."
        case .unverified:
            "Google will show “Google hasn't verified this app”. That's expected for a small app like Wren: choose Advanced, then Go to Wren, to continue. You can disconnect at any time."
        case .verified:
            nil
        }
    }
}
