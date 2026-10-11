import AppKit
import Carbon.HIToolbox

/// Global shortcut via Carbon's RegisterEventHotKey. It needs no Accessibility or
/// Input Monitoring permission, consumes only the registered key combination, and
/// never observes any other keystrokes.
final class HotKeyService {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private let hotKeyID: UInt32

    /// `id` distinguishes several hotkeys (1 = capture, 2 = push-to-talk). Release events are
    /// delivered too, for hold-to-talk.
    init(id: UInt32 = 1, onPress: @escaping () -> Void, onRelease: @escaping () -> Void = {}) {
        self.onPress = onPress; self.onRelease = onRelease; hotKeyID = id
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<HotKeyService>.fromOpaque(userData).takeUnretainedValue()
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard hk.id == service.hotKeyID else { return OSStatus(eventNotHandledErr) }
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            DispatchQueue.main.async { released ? service.onRelease() : service.onPress() }
            return noErr
        }, 2, &specs, selfPtr, &handlerRef)
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Returns nil on success, or a human-readable reason.
    func register(_ spec: HotKeySpec) -> String? {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x5752_454E), id: hotKeyID) // 'WREN'
        let status = RegisterEventHotKey(spec.keyCode, spec.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        switch status {
        case noErr: return nil
        case OSStatus(eventHotKeyExistsErr):
            hotKeyRef = nil
            return "\(spec.display) is already used by another app. Choose a different shortcut."
        default:
            hotKeyRef = nil
            return "macOS refused the shortcut (error \(status))."
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    var isRegistered: Bool { hotKeyRef != nil }

    // MARK: Converting a recorded key event

    static func spec(from event: NSEvent) -> HotKeySpec? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Require a real modifier so ordinary typing can never be captured as the shortcut.
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Escape: "Esc",
                                    kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→"]
        let key = names[Int(event.keyCode)] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        return HotKeySpec(keyCode: UInt32(event.keyCode), carbonModifiers: carbon, display: "\(symbols) \(key)")
    }
}
