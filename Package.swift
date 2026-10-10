// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wren",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Wren", targets: ["Wren"]),
        .executable(name: "wren-tools", targets: ["WrenTools"]),
    ],
    targets: [
        // Models, persistence, date parsing, reminder rules, Ollama client. No UI.
        .target(name: "WrenCore"),
        // SwiftUI views, AppKit services (hotkey, panel, notifications), brand geometry.
        .target(name: "WrenKit", dependencies: ["WrenCore"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        // Thin executable entry point. Packaged into Wren.app by scripts/build-app.sh.
        .executableTarget(name: "Wren", dependencies: ["WrenKit"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // Dev-only: generates brand assets and renders UI snapshots for inspection.
        .executableTarget(name: "WrenTools", dependencies: ["WrenKit", "WrenCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "WrenCoreTests", dependencies: ["WrenCore"]),
    ]
)
