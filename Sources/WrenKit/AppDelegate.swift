import AppKit
import SwiftUI
import WrenCore
import os

private let appLog = Logger(subsystem: "com.shibadityadeb.wren", category: "app")

/// Menu-bar agent: a status item with a popover, a global shortcut, and the capture panel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var panel: CapturePanel!
    private let captureState = CaptureState()
    private var hotKeys: HotKeyService!

    func applicationDidFinishLaunching(_ note: Notification) {
        model = AppModel()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = WrenMark.menuBarImage()
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        statusItem.button?.setAccessibilityLabel("Wren")

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))

        panel = CapturePanel {
            CaptureView(state: captureState, submit: { [weak self] in self?.submitCapture($0) },
                        cancel: { [weak self] in self?.cancelCapture() })
        }
        panel.onCancel = { [weak self] in self?.cancelCapture() }
        panel.onResign = { [weak self] in
            guard let self else { return }
            self.model.settings.captureDraft = self.captureState.text
        }

        hotKeys = HotKeyService { [weak self] in self?.showCapture() }
        model.openCapturePanel = { [weak self] in self?.popover.performClose(nil); self?.showCapture() }
        model.showPopover = { [weak self] in self?.openPopover() }
        model.applyHotKey = { [weak self] in self?.applyHotKey() }
        applyHotKey()
        model.start()
    }

    // MARK: Hotkey

    private func applyHotKey() {
        guard model.settings.hotKeyEnabled else { hotKeys.unregister(); model.hotKeyError = nil; return }
        model.hotKeyError = hotKeys.register(model.settings.hotKey)
        if let e = model.hotKeyError {
            appLog.error("hotkey \(self.model.settings.hotKey.display, privacy: .public) not registered: \(e, privacy: .public)")
        } else {
            appLog.notice("hotkey \(self.model.settings.hotKey.display, privacy: .public) registered")
        }
    }

    // MARK: Capture panel

    func showCapture() {
        if panel.isVisible { panel.makeKey(); return }
        captureState.text = model.settings.captureDraft
        captureState.status = model.modelStatus.isReady ? "" : "Saved locally even without a model"
        captureState.presentations += 1
        panel.present()
    }

    private func submitCapture(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if model.capture(text, source: .hotkey) {
            captureState.text = ""
            model.settings.captureDraft = ""
            panel.orderOut(nil)
        } else {
            captureState.status = "Couldn't save. Your text is still here."
        }
    }

    private func cancelCapture() {
        captureState.text = ""
        model.settings.captureDraft = ""
        panel.orderOut(nil)
    }

    // MARK: Popover

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : openPopover()
    }

    func openPopover() {
        guard let button = statusItem.button else { return }
        model.reload()
        Task { await model.refreshModels(); model.notificationStatus = await model.notifications.refreshStatus() }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        if model.route == .settings { model.route = .list }
    }

    // MARK: URL scheme fallback: `open wren://capture`

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "wren" {
            switch url.host {
            case "capture": showCapture()
            #if DEBUG
            case "debug": debugURL(url)
            #endif
            default: openPopover()
            }
        }
    }

    #if DEBUG
    /// Debug builds only: lets automated checks capture text without a keyboard.
    /// Compiled out of release builds so nothing outside Wren can inject captures.
    private func debugURL(_ url: URL) {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.path {
        case "/capture":
            if let text = q.first(where: { $0.name == "text" })?.value {
                let ok = model.capture(text, source: .urlScheme)
                appLog.notice("debug capture saved=\(ok, privacy: .public)")
            }
        case "/state":
            model.reload()
            for c in model.pending + model.closed {
                appLog.notice("debug item kind=\(c.kind.rawValue, privacy: .public) status=\(c.status.rawValue, privacy: .public) processing=\(c.processing.rawValue, privacy: .public) deadline=\(c.deadline?.description ?? "nil", privacy: .public) next=\(c.nextReminderAt?.description ?? "nil", privacy: .public) last=\(c.lastReminderAt?.description ?? "nil", privacy: .public)")
            }
            appLog.notice("debug notifications=\(self.model.notificationStatus.rawValue, privacy: .public) model=\(self.model.modelStatus.summary, privacy: .public)")
        default: break
        }
    }
    #endif
}

/// Entry point used by the `Wren` executable.
public enum WrenMain {
    @MainActor private static var delegate: AppDelegate?

    @MainActor public static func run() {
        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
