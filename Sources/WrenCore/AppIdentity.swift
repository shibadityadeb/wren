import Foundation

/// Which Wren this process is. Release builds are `com.shibadityadeb.wren`. A development build made
/// with `scripts/build-app.sh debug --dev-identity` is "Wren Dev" (`com.shibadityadeb.wren.dev`): a
/// separate app with its own data folder, preferences, Keychain items and URL scheme, so testing
/// never touches the installed Wren or its data, and it never looks like a second copy of Wren.
public enum AppIdentity {
    public static let releaseBundleID = "com.shibadityadeb.wren"
    public static let devBundleID = "com.shibadityadeb.wren.dev"

    public static var bundleID: String { Bundle.main.bundleIdentifier ?? releaseBundleID }
    public static var isDevelopment: Bool { bundleID == devBundleID }
    public static var dataFolderName: String { isDevelopment ? "Wren Dev" : "Wren" }
    public static var keychainService: String { isDevelopment ? "com.shibadityadeb.wren.dev.connectors" : "com.shibadityadeb.wren.connectors" }
    public static var urlSchemes: Set<String> { isDevelopment ? ["wren-dev"] : ["wren"] }
}
