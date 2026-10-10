import Foundation

public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    /// Registered, but the user must allow it in System Settings › General › Login Items.
    case requiresApproval
    case unavailable(String)

    public var label: String {
        switch self {
        case .enabled: "Wren opens when you log in."
        case .disabled: "Off"
        case .requiresApproval: "Waiting for your approval in System Settings › General › Login Items."
        case let .unavailable(r): "Unavailable: \(r)"
        }
    }
}

/// Wraps the OS mechanism (SMAppService in the app) so the policy is testable.
@MainActor
public protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// Applies the user's explicit choice. Default is off: Wren never adds itself to login items unasked.
@MainActor
public struct LoginItemController {
    public let service: LoginItemService
    public init(service: LoginItemService) { self.service = service }

    /// User flipped the toggle.
    public func set(enabled: Bool) -> LoginItemStatus {
        do {
            switch (enabled, service.status) {
            case (true, .enabled), (true, .requiresApproval), (false, .disabled): break
            case (true, _): try service.register()
            case (false, _): try service.unregister()
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
        return service.status
    }

    /// On launch: if the user wanted login launch but macOS lost the registration (for
    /// example after the app was moved or replaced), register again. Never registers
    /// when the user didn't ask for it.
    public func reconcileOnLaunch(userWantsEnabled: Bool) -> LoginItemStatus {
        guard userWantsEnabled else { return service.status }
        if service.status == .disabled {
            do { try service.register() } catch { return .unavailable(error.localizedDescription) }
        }
        return service.status
    }
}
