import AppKit
import SwiftUI
import WrenCore
import os
import UserNotifications

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
    #if DEBUG
    private var debugProposal: ContextProposal?
    #endif

    func applicationDidFinishLaunching(_ note: Notification) {
        // One Wren at a time: a login launch plus a manual open must not run two schedulers.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
            appLog.notice("another Wren instance is running; exiting")
            NSApp.terminate(nil)
            return
        }
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
                        cancel: { [weak self] in self?.cancelCapture() },
                        confirm: { [weak self] in self?.confirmProposal($0) },
                        choose: { [weak self] c, p in self?.chooseCandidate(c, p) },
                        saveAsNew: { [weak self] in self?.saveAsNew($0) })
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
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !captureState.busy else { return }
        captureState.busy = true
        Task {
            let reply = await model.submitFromCapture(text)
            captureState.busy = false
            switch reply {
            case .saved: closeCapture()
            case let .resolution(r): captureState.reply = r
            case let .failed(msg): captureState.status = msg
            }
        }
    }

    private func confirmProposal(_ p: ContextProposal) {
        Task {
            let r = await model.confirmProposal(p)
            if r?.status == .succeeded || r?.status == .unverified { closeCapture() }
            else { captureState.reply = .notFound(r?.message ?? "That didn't work."); captureState.status = r?.message ?? "" }
        }
    }

    private func chooseCandidate(_ c: Candidate, _ p: PendingCommand) { captureState.reply = model.choose(c, for: p) }

    private func saveAsNew(_ text: String) {
        if model.capture(text, source: .hotkey) { closeCapture() }
    }

    private func closeCapture() {
        captureState.text = ""
        captureState.reply = nil
        captureState.status = ""
        model.settings.captureDraft = ""
        panel.orderOut(nil)
    }

    private func cancelCapture() {
        if case let .proposal(p)? = captureState.reply { model.cancelProposal(p) }
        closeCapture()
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
            appLog.notice("debug notifications=\(self.model.notificationStatus.rawValue, privacy: .public) model=\(self.model.modelStatus.summary, privacy: .public) briefing=\(self.model.todayRun.briefing.rawValue, privacy: .public) checkIn=\(self.model.todayRun.checkIn.rawValue, privacy: .public) login=\(self.model.loginStatus.label, privacy: .public)")
            let rules = self.model.policy.rules.map(\.rawValue).sorted().joined(separator: ",")
            let grants = self.model.policy.grants.map(\.rawValue).sorted().joined(separator: ",")
            appLog.notice("debug policy rules=\(rules, privacy: .public) grants=\(grants, privacy: .public)")
            for a in self.model.audit.prefix(8) {
                appLog.notice("debug audit \(a.action, privacy: .public) \(a.status.rawValue, privacy: .public) by=\(a.origin, privacy: .public) auth=\(a.authorization ?? "-", privacy: .public)")
            }
        case "/delivered":
            Task {
                let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
                let ids = delivered.map(\.request.identifier).joined(separator: ",")
                appLog.notice("debug delivered count=\(delivered.count, privacy: .public) ids=\(ids, privacy: .public)")
            }
        case "/checkin":
            // Force-evaluate today's check-in with the time moved to now (debug only).
            let minutes = Calendar.current.component(.hour, from: .now) * 60 + Calendar.current.component(.minute, from: .now)
            if minutes >= 15 * 60 && minutes < 23 * 60 { model.updateDaily { $0.checkInMinutes = minutes } }
            model.scheduleTick()
        case "/login":
            let on = q.first(where: { $0.name == "on" })?.value == "1"
            model.setLaunchAtLogin(on)
            appLog.notice("debug login on=\(on, privacy: .public) status=\(self.model.loginStatus.label, privacy: .public)")
        case "/command":
            // Debug only: run a contextual command as if typed in the capture panel.
            if let text = q.first(where: { $0.name == "text" })?.value {
                Task {
                    let reply = await model.submitFromCapture(text)
                    switch reply {
                    case .saved: appLog.notice("debug command saved as new capture")
                    case let .failed(m): appLog.notice("debug command failed: \(m, privacy: .public)")
                    case let .resolution(r):
                        switch r {
                        case let .proposal(p):
                            debugProposal = p
                            appLog.notice("debug command proposal: \(p.preview, privacy: .public) origin=\(p.request.origin.label, privacy: .public)")
                        case let .clarify(q, c, _): appLog.notice("debug command clarify: \(q, privacy: .public) candidates=\(c.count, privacy: .public)")
                        case let .answer(t, l): appLog.notice("debug command answer: \(t, privacy: .public) lines=\(l.count, privacy: .public)")
                        case let .notFound(m), let .needsDate(m): appLog.notice("debug command: \(m, privacy: .public)")
                        case .notACommand: break
                        }
                    }
                }
            }
        case "/submit-unconfirmed":
            // Debug only: submit the last proposal WITHOUT confirming, to show the broker refuses.
            if let p = debugProposal {
                Task {
                    let r = await model.broker?.submit(p.request)
                    appLog.notice("debug unconfirmed submit status=\(r?.status.rawValue ?? "-", privacy: .public)")
                }
            }
        case "/confirm":
            if let p = debugProposal {
                Task {
                    let r = await model.confirmProposal(p)
                    appLog.notice("debug confirmed status=\(r?.status.rawValue ?? "-", privacy: .public) auth=\(r?.authorization?.label ?? "-", privacy: .public)")
                }
            }
        case "/insights":
            model.reload()
            for i in model.insights { appLog.notice("debug insight \(i.kind.rawValue, privacy: .public): \(i.message, privacy: .public)") }
            appLog.notice("debug goals=\(self.model.goals.count, privacy: .public) insights=\(self.model.insights.count, privacy: .public)")
        case "/delete-first":
            if let c = model.pending.last { model.delete(c) }
            appLog.notice("debug delete requested; confirmation pending=\(self.model.confirmation != nil, privacy: .public)")
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
