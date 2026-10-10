import AppKit
import SwiftUI

/// A borderless, non-activating panel. Because it never activates Wren, the app you
/// were using stays frontmost, and closing the panel returns you straight to it.
final class CapturePanel: NSPanel {
    var onCancel: (() -> Void)?
    var onResign: (() -> Void)?

    init<Content: View>(@ViewBuilder content: () -> Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 120),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                   backing: .buffered, defer: true)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        let host = NSHostingView(rootView: content())
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape.
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// Clicking elsewhere dismisses the panel (the draft is kept).
    override func resignKey() {
        super.resignKey()
        if isVisible { onResign?(); orderOut(nil) }
    }

    func present() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = contentView?.fittingSize ?? frame.size
            setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.66))
        }
        makeKeyAndOrderFront(nil)
    }
}
