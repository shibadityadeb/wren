import ServiceManagement
import WrenCore

/// macOS 13+ login item for the main app bundle via SMAppService.
@MainActor
final class SystemLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval
        // macOS reports notFound for an app that has simply never been registered.
        // Treat it as off; a real failure surfaces when register() throws.
        case .notFound: .disabled
        @unknown default: .unavailable("Unknown login item status.")
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
