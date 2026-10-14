import SwiftUI
import WrenCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var recording = false
    @State private var monitor: Any?
    @State private var reminderHour = 10

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { stopRecording(); model.route = .list } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Text("Settings").font(.headline)
                Spacer()
                Color.clear.frame(width: 50, height: 1)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Daily rhythm") {
                        Toggle("Morning briefing", isOn: Binding(get: { model.daily.briefingEnabled }, set: { v in model.updateDaily { $0.briefingEnabled = v } }))
                        if model.daily.briefingEnabled {
                            timePicker("Briefing at", minutes: model.daily.briefingMinutes, range: DailySettings.briefingRange) { v in model.updateDaily { $0.briefingMinutes = v } }
                        }
                        Toggle("Evening check-in", isOn: Binding(get: { model.daily.checkInEnabled }, set: { v in model.updateDaily { $0.checkInEnabled = v } }))
                        if model.daily.checkInEnabled {
                            timePicker("Check-in at", minutes: model.daily.checkInMinutes, range: DailySettings.checkInRange) { v in model.updateDaily { $0.checkInMinutes = v } }
                        }
                        Toggle("Send even when there's nothing to report", isOn: Binding(get: { model.daily.sendEmptySummaries }, set: { v in model.updateDaily { $0.sendEmptySummaries = v } }))
                        Text("Each runs at most once a day. If your Mac was asleep, a briefing is sent on wake until the check-in time, and a check-in until 11 PM; after that it's skipped, never sent the next day.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    section("Review") {
                        Stepper("Ask after \(model.insightSettings.postponeThreshold) postponements", value: Binding(
                            get: { model.insightSettings.postponeThreshold }, set: { v in model.updateInsightSettings { $0.postponeThreshold = v } }), in: 2...10)
                        Stepper("Tasks are quiet after \(model.insightSettings.staleTaskDays) days", value: Binding(
                            get: { model.insightSettings.staleTaskDays }, set: { v in model.updateInsightSettings { $0.staleTaskDays = v } }), in: 3...90)
                        Stepper("Ideas are quiet after \(model.insightSettings.staleIdeaDays) days", value: Binding(
                            get: { model.insightSettings.staleIdeaDays }, set: { v in model.updateInsightSettings { $0.staleIdeaDays = v } }), in: 7...365, step: 7)
                        Stepper("Goals are quiet after \(model.insightSettings.staleGoalDays) days", value: Binding(
                            get: { model.insightSettings.staleGoalDays }, set: { v in model.updateInsightSettings { $0.staleGoalDays = v } }), in: 3...90)
                        Stepper("Mention goals \(model.insightSettings.goalApproachDays) days before target", value: Binding(
                            get: { model.insightSettings.goalApproachDays }, set: { v in model.updateInsightSettings { $0.goalApproachDays = v } }), in: 1...30)
                        Text("Items with an upcoming deadline or reminder are never “quiet”. Review only suggests; it never archives or deletes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    section("Voice, GPT and Gmail") {
                        ExecutorSettings(model: model)
                    }

                    section("Startup") {
                        Toggle("Open Wren when I log in", isOn: Binding(get: { model.settings.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        HStack {
                            Text(model.loginStatus.label).font(.caption).foregroundStyle(model.loginStatus == .enabled || model.loginStatus == .disabled ? Color.secondary : Color.orange)
                            Spacer()
                            Button("Login Items…") { SystemLoginItemService.openSystemSettings() }.controlSize(.small)
                        }
                        Text("Closing Wren's window keeps it running in the menu bar, so the shortcuts, the Voice button, email checks, the briefing and the check-in keep working. Quit with ⌘Q or Wren › Quit Wren to stop everything: any recording, email checks and running work. Reminders are scheduled with macOS, so they still arrive after you quit.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }

                    section("Permissions") {
                        ForEach(StandingRuleKind.allCases) { k in
                            let locked = PolicySnapshot.protectedRules.contains(k)
                            Toggle(isOn: Binding(get: { model.policy.rules.contains(k) }, set: { model.setRule(k, $0) })) {
                                HStack(spacing: 4) {
                                    Text(k.title)
                                    if locked { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                                }
                            }
                            .disabled(locked)
                        }
                        DisclosureGroup("What Wren may do") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(model.broker?.allDescriptors ?? [], id: \.id) { d in
                                    HStack(alignment: .firstTextBaseline) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(d.summary)
                                            Text("\(d.category.label) · \(d.effectiveConfirmation == .always ? "always asks first" : "no extra prompt")")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(model.policy.grants.contains(d.permission) ? "Allowed" : "Not granted")
                                            .font(.caption).foregroundStyle(model.policy.grants.contains(d.permission) ? Color.secondary : Color.orange)
                                    }
                                }
                                Text("External permissions (email, AI services) can't be granted yet; those integrations don't exist.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            .padding(.top, 4)
                        }
                        let denials = model.denials
                        if !denials.isEmpty {
                            DisclosureGroup("Things you declined (\(denials.count))") {
                                ForEach(denials) { d in
                                    HStack {
                                        Text("\(d.action) · \(d.targetLabel)").font(.caption).lineLimit(1)
                                        Spacer()
                                        Button("Allow again") { model.liftDenial(d.key) }.controlSize(.small)
                                    }
                                }
                            }
                        }
                        Button("Activity log…") { model.route = .activity }
                        Text("Wren acts only on your instruction, a rule above, or your confirmation. Model suggestions and text inside emails or pages never count as permission.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    section("Capture shortcut") {
                        Toggle("Enable global shortcut", isOn: Binding(get: { model.hotKeyEnabled }, set: { model.setHotKeyEnabled($0) }))
                        HStack {
                            Text(recording ? "Press the new shortcut…" : model.hotKeyDisplay)
                                .font(.body.monospaced())
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            Button(recording ? "Cancel" : "Change…") { recording ? stopRecording() : startRecording() }
                                .disabled(!model.hotKeyEnabled)
                            Button("Reset") { model.setHotKey(.optionSpace) }.disabled(!model.hotKeyEnabled)
                        }
                        if let e = model.hotKeyError { Text(e).font(.caption).foregroundStyle(.orange) }
                        Text("Uses a standard macOS hotkey. Wren never reads other keystrokes or other apps' content. If the shortcut is unavailable, use the capture button in this menu.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    section("Connectors") {
                        HStack {
                            let sum = model.hub.registry.summary
                            Text("\(sum[.connected] ?? 0) connected · \(sum[.needsSetup] ?? 0) need your attention · \(sum[.planned] ?? 0) not implemented").font(.callout)
                            Spacer()
                            Button("Connectors…") { model.route = .connectors }
                        }
                        Text("ChatGPT, voice, Gmail, Notion, Google Calendar. Each shows its real status, permissions and privacy.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    section("Local AI") {
                        HStack {
                            Text(model.ai.title).font(.callout)
                            Spacer()
                            Button("Set up and test…") { model.route = .aiSetup }
                        }
                        Text("Runs on this Mac through Ollama. Optional: everything works without it.").font(.caption).foregroundStyle(.secondary)
                    }

                    section("Notifications") {
                        HStack {
                            if let p = model.pauseLabel {
                                Label(p, systemImage: "bell.slash").font(.callout)
                                Spacer()
                                Button("Resume now") { model.resumeNotifications() }
                            } else {
                                Text("Pause Wren's reminders, briefing and check-in").font(.callout)
                                Spacer()
                                Menu("Pause") {
                                    ForEach(NotificationPause.Option.allCases, id: \.self) { o in Button(o.label) { model.pauseNotifications(o) } }
                                }.fixedSize()
                            }
                        }
                        Text("While paused, nothing is delivered and nothing is changed: deadlines and schedules stay as they are. When you resume, anything that came due arrives as one summary, not a burst. Notifications macOS already showed can't be taken back.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text(notificationText).font(.callout)
                            Spacer()
                            if model.notificationStatus == .notDetermined {
                                Button("Allow…") { model.requestNotificationPermission() }
                            } else {
                                Button("Open System Settings") {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(AppIdentity.bundleID)")!)
                                }
                            }
                        }
                        Toggle("Play notification sounds", isOn: Binding(get: { model.settings.notificationSounds }, set: { model.settings.notificationSounds = $0; model.connectorsChanged() }))
                        Text("Applies to reminders, GPT results, email alerts and digests. Reminders macOS already has keep the setting they were scheduled with until they're next rescheduled.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Stepper("Date-only deadlines remind at \(reminderHour):00", value: $reminderHour, in: 6...21)
                            .onChange(of: reminderHour) { model.settings.dateOnlyReminderHour = reminderHour; model.scheduleReconcile() }
                        Toggle("Also remind me the day before a deadline", isOn: Binding(get: { model.settings.deadlineDayBefore }, set: { model.setDeadlineDayBefore($0) }))
                        Text("For a task with a deadline set at least a day ahead: one heads-up the day before at \(reminderHour):00, then the reminder on the day. A reminder time you choose yourself replaces both. Each is scheduled once and withdrawn when the task is done.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(reminderSyncText).font(.caption).foregroundStyle(model.reminderSync.authorized && model.reminderSync.failed.isEmpty ? Color.secondary : Color.orange)
                        Text("Reminders are handed to macOS ahead of time, so they arrive even when Wren isn't running. macOS may hide banners during Focus or Do Not Disturb. Briefings and check-ins need Wren running.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }

                    section("Your data") {
                        HStack {
                            Button("Export…") { model.exportData() }
                            Button("Back Up Now") { model.backupNow() }
                            Spacer()
                            Button("Show Backups") { model.revealBackups() }.buttonStyle(.link)
                        }
                        Text("Export writes one readable JSON file (items, history, goals, follow-ups, review decisions, permissions). Backups are full copies of Wren's database, made daily while Wren runs and before upgrades, restores and resets. Neither contains passwords or keys.")
                            .font(.caption).foregroundStyle(.secondary)
                        BackupsList(model: model)
                        Text(model.store?.storeURL?.path ?? "Unavailable")
                            .font(.caption2.monospaced()).textSelection(.enabled).foregroundStyle(.tertiary)
                    }

                    section("Reset") {
                        ResetControls(model: model)
                    }
                }
                .padding(14)
            }
        }
        .onAppear { reminderHour = model.settings.dateOnlyReminderHour; model.refreshLoginStatus(); model.refreshBackups() }
        .onDisappear(perform: stopRecording)
    }

    var reminderSyncText: String {
        let r = model.reminderSync
        if !r.authorized { return "Notifications are off, so reminders can only show inside Wren." }
        if !r.failed.isEmpty { return "macOS didn't accept \(r.failed.count) reminder notification\(r.failed.count == 1 ? "" : "s"). Wren will retry." }
        let n = model.pending.filter { !$0.scheduledNotificationIDs.isEmpty }.count
        return n == 0 ? "No reminders scheduled." : "\(n) reminder\(n == 1 ? "" : "s") scheduled with macOS."
    }

    var notificationText: String {
        switch model.notificationStatus {
        case .authorized, .provisional: "Allowed"
        case .denied: "Turned off in System Settings"
        default: "Not yet allowed"
        }
    }

    func timePicker(_ label: String, minutes: Int, range: ClosedRange<Int>, set: @escaping (Int) -> Void) -> some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let lower = today.addingTimeInterval(TimeInterval(range.lowerBound * 60))
        let upper = today.addingTimeInterval(TimeInterval(range.upperBound * 60))
        return DatePicker(label, selection: Binding(
            get: { cal.time(minutesAfterMidnight: minutes, on: .now) },
            set: { d in let c = cal.dateComponents([.hour, .minute], from: d); set((c.hour ?? 0) * 60 + (c.minute ?? 0)) }),
            in: lower...upper, displayedComponents: .hourAndMinute)
    }

    func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    func setup(_ text: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.callout)
            HStack {
                Text(command).font(.callout.monospaced()).textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }.controlSize(.small)
            }
            .padding(8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Records one key combination using a local monitor that exists only while recording.
    func startRecording() {
        recording = true
        model.hotKeyError = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil } // Esc cancels
            if let spec = HotKeyService.spec(from: event) {
                model.setHotKey(spec)
                stopRecording()
            } else {
                model.hotKeyError = "Include ⌘, ⌥ or ⌃ in the shortcut."
            }
            return nil
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

struct BackupsList: View {
    var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.backupList.isEmpty {
                Text("No backups yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.backupList.prefix(12)) { e in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.callout)
                            Text("\(e.reasonLabel)\(e.manifest.map { " · \($0.counts["items"] ?? 0) items · v\($0.appVersion)" } ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Preview") { model.previewBackup(e) }.controlSize(.small)
                    }
                    if let p = model.backupPreview, p.entry.id == e.id {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Verified: checksum and database integrity OK", systemImage: "checkmark.seal").font(.caption).foregroundStyle(WrenTheme.accent)
                            Text("\(p.counts["items"] ?? 0) items · \(p.counts["goals"] ?? 0) goals · \(p.counts["historyEvents"] ?? 0) history events").font(.caption)
                            if !p.newestItemTitles.isEmpty {
                                Text("Newest: " + p.newestItemTitles.prefix(3).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            HStack {
                                Button("Restore…") { model.restore(e) }
                                Button("Delete…", role: .destructive) { model.deleteBackup(e) }
                                Spacer()
                                Button("Close") { model.backupPreview = nil }.buttonStyle(.link)
                            }.controlSize(.small)
                            Text("Restoring backs up your current data first, then restarts Wren. If the backup can't be opened, your current data is kept.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }
}

struct ResetControls: View {
    var model: AppModel
    @State private var backupFirst = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reset preferences").font(.callout)
                    Text("Shortcut, briefing and check-in times, review thresholds, AI model choice, pause and open-at-login go back to defaults. Items, goals and history are kept.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Reset…") { model.resetPreferences() }
            }
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove all Wren data").font(.callout)
                    Text("Deletes every item, goal, history entry, review decision and briefing record, and resets permissions to defaults. Wren itself, Ollama models and backups are not touched.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Back up first", isOn: $backupFirst).toggleStyle(.checkbox).font(.caption)
                }
                Spacer()
                Button("Remove…", role: .destructive) { model.eraseAllData(backupFirst: backupFirst) }
            }
            Text("Wren can't reliably tell test entries from real ones, so it doesn't offer a one-click “clear test data”. Drop or archive those items individually.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// One place to see and change how Wren's tools are set up: voice, the ChatGPT plan, Google and
/// email alerts. Every state shown comes from the connector's real result, not a guess.
struct ExecutorSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        let _ = model.connectorVersion
        let speech = LocalSpeechModel.status()
        VStack(alignment: .leading, spacing: 10) {
            row("Voice", detail: model.settings.voiceEnabled ? "Shortcut \(model.settings.voiceHotKey.display) · Voice button in the panel and popover" : "Shortcut off · Voice button in the panel and popover",
                state: speech.isReady ? "Ready" : speech.label, ok: speech.isReady, open: .voice)
            Text("Microphone: \(model.hub.voicePermissions.microphone.rawValue) · Speech recognition: \(model.hub.voicePermissions.speech.rawValue) · Model: \(speech.label). Wren never listens in the background; there's no setting for that.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let gpt = model.hub.chatgpt.state
            row("ChatGPT", detail: model.hub.chatgpt.email.map { "Signed in as \($0)" } ?? "Sign in with ChatGPT; uses your plan's allowance, never an API key",
                state: gpt.label, ok: gpt.isUsable, open: .chatgpt)
            if let d = gpt.detail { Text(d).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            let google = model.hub.gmail.state
            row("Google", detail: scopesText, state: google.label, ok: google.isUsable, open: .gmail)
            if model.gmailUsable {
                DisclosureGroup("Email alerts, quiet hours and morning email digest") { MailSettingsView(model: model).padding(.top, 4) }
                    .font(.callout)
            } else {
                Text("Email alerts, quiet hours and the morning email digest appear here once Google is connected.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Notion and Calendar are set up under Connectors. Integrations marked “Coming soon” there aren't available yet.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    var scopesText: String {
        let g = model.hub.google
        guard !g.grantedScopes.isEmpty else { return "Not connected" }
        var parts: [String] = []
        if g.canReadMail { parts.append(g.canMarkRead ? "Gmail: read and Mark as read" : "Gmail: read-only") }
        if g.grantedScopes.contains(ConnectorCatalog.calendarScope) { parts.append("Calendar: read-only") }
        return parts.joined(separator: " · ")
    }

    func row(_ name: String, detail: String, state: String, ok: Bool, open: ConnectorID) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(state).font(.caption.weight(.semibold)).foregroundStyle(ok ? WrenTheme.accent : .orange)
            Button("Manage…") { model.route = .connector(open) }.controlSize(.small)
        }
    }
}
