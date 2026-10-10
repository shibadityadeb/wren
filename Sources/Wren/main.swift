import Foundation
import WrenKit

// `--smoke-test`: verifies this binary (and CPU slice) can start Wren's core in memory, then exits.
// Used by the release pipeline on Apple Silicon and Intel. Touches no user data and shows no UI.
if CommandLine.arguments.contains("--smoke-test") {
    let ok = MainActor.assumeIsolated { WrenMain.smokeTest() }
    exit(ok ? 0 : 1)
}

MainActor.assumeIsolated { WrenMain.run() }
