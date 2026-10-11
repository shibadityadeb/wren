import AppKit
import UniformTypeIdentifiers
import WrenCore

/// Export, backups, restore, reset and notification pause. Destructive steps go through the
/// broker and its confirmation alert.
@MainActor
extension AppModel {
    func registerAppActions() {
        guard let broker else { return }
        let settingsRef = settings
        let login = loginItems
        broker.register(BlockActionHandler(
            ActionDescriptor(id: BuiltInAction.resetPreferences, category: .localDestructive, permission: .manageItems, confirmation: .always,
                             summary: "Reset Wren's preferences (shortcut, times, AI choice, pause). Items are kept",
                             verification: "Preferences back to defaults"),
            execute: { _ in
                _ = login.set(enabled: false)
                settingsRef.resetAll()
                return nil
            },
            verify: { _ in settingsRef.pause == nil && settingsRef.hotKey == .optionSpace && !settingsRef.launchAtLogin }))
    }

    func reloadPreferences() {
        hotKeyDisplay = settings.hotKey.display
        hotKeyEnabled = settings.hotKeyEnabled
        selectedModel = settings.modelName
        daily = settings.daily
        insightSettings = settings.insights
        pause = settings.pause
        loginStatus = loginItems.service.status
        applyHotKey()
        Task { await refreshAI() }
        scheduleTick()
    }

    // MARK: Pause

    func pauseNotifications(_ option: NotificationPause.Option) {
        let p = NotificationPause.make(option, now: clock.now, calendar: clock.calendar)
        settings.pause = p
        pause = p
        resumeNote = nil
        log.notice("notifications paused: \(option.rawValue, privacy: .public)")
        scheduleTick()
    }

    func resumeNotifications() {
        Task {
            guard let engine else { return }
            let r = await engine.resume()
            pause = settings.pause
            resumeNote = r.summarizedAfterPause > 0
                ? "\(r.summarizedAfterPause) reminder\(r.summarizedAfterPause == 1 ? "" : "s") came due while paused (sent as one summary)."
                : "Notifications resumed."
            reload()
            scheduleTick()
        }
    }

    var pauseLabel: String? { pause.map { $0.label(now: clock.now, calendar: clock.calendar) } }

    // MARK: Export

    func exportData() {
        guard let store else { banner = "Wren's database isn't available."; return }
        let panel = NSSavePanel()
        panel.title = "Export Wren data"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let day = clock.calendar.dayKey(for: clock.now)
        panel.nameFieldStringValue = "Wren Export \(day).json"
        panel.message = "A readable JSON file with your items, goals, history, review decisions and permissions. No passwords or keys."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try WrenExport.make(from: store, appVersion: Self.appVersion, now: clock.now, timeZone: clock.calendar.timeZone).encoded()
            // The save panel already asked before replacing an existing file.
            try WrenExport.write(data, to: url, replacingConfirmed: true)
            banner = "Exported to \(url.lastPathComponent)."
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            banner = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: Backups

    func refreshBackups() { backupList = backups.list() }

    func backupNow() {
        do {
            let b = try backups.createBackup(reason: .manual, appVersion: Self.appVersion, now: clock.now)
            banner = "Backed up \(b.manifest?.counts["items"] ?? 0) items."
        } catch { banner = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        refreshBackups()
    }

    /// One automatic backup a day while Wren runs.
    func automaticBackupIfDue() {
        guard store != nil, (settings.lastAutomaticBackup.map { clock.now.timeIntervalSince($0) > 20 * 3600 } ?? true) else { return }
        if (try? backups.createBackup(reason: .automatic, appVersion: Self.appVersion, now: clock.now)) != nil {
            settings.lastAutomaticBackup = clock.now
        }
    }

    func previewBackup(_ e: BackupEntry) {
        do { backupPreview = try backups.preview(e) } catch {
            backupPreview = nil
            banner = "This backup can't be used: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }

    func restore(_ e: BackupEntry) {
        Task { await run(ActionRequest(action: BuiltInAction.restoreBackup, target: e.targetRef, origin: .user(.settings), createdAt: clock.now)) }
    }

    func deleteBackup(_ e: BackupEntry) {
        Task { await run(ActionRequest(action: BuiltInAction.deleteBackup, target: e.targetRef, origin: .user(.settings), createdAt: clock.now)) }
    }

    func revealBackups() {
        try? FileManager.default.createDirectory(at: backups.backupsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([backups.backupsDirectory])
    }

    // MARK: Reset

    func eraseAllData(backupFirst: Bool) {
        if backupFirst {
            do { try backups.createBackup(reason: .preReset, appVersion: Self.appVersion, now: clock.now) } catch {
                banner = "Couldn't back up first, so nothing was removed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
                return
            }
            refreshBackups()
        }
        Task { await run(ActionRequest(action: BuiltInAction.eraseAllData, target: BuiltInAction.allDataTarget, origin: .user(.settings), createdAt: clock.now)) }
    }

    func resetPreferences() {
        Task { await run(ActionRequest(action: BuiltInAction.resetPreferences, target: TargetRef(kind: "preferences", id: "all", label: "Wren preferences"),
                                       origin: .user(.settings), createdAt: clock.now)) }
    }

    /// Starts a fresh copy of Wren (which waits for this one to quit) so a staged restore is applied
    /// before the database opens.
    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = ["--relaunch"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            Task { @MainActor in
                if let error { self.banner = "Restart Wren to finish restoring (\(error.localizedDescription))."; return }
                NSApp.terminate(nil)
            }
        }
    }
}
