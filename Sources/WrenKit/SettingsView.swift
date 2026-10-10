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

                    section("Startup") {
                        Toggle("Open Wren when I log in", isOn: Binding(get: { model.settings.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        HStack {
                            Text(model.loginStatus.label).font(.caption).foregroundStyle(model.loginStatus == .enabled || model.loginStatus == .disabled ? Color.secondary : Color.orange)
                            Spacer()
                            Button("Login Items…") { SystemLoginItemService.openSystemSettings() }.controlSize(.small)
                        }
                        Text("Reminders and daily summaries only arrive while Wren is running.").font(.caption).foregroundStyle(.secondary)
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
                            Text(notificationText).font(.callout)
                            Spacer()
                            if model.notificationStatus == .notDetermined {
                                Button("Allow…") { model.requestNotificationPermission() }
                            } else {
                                Button("Open System Settings") {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                                }
                            }
                        }
                        Stepper("Date-only deadlines remind at \(reminderHour):00", value: $reminderHour, in: 6...21)
                            .onChange(of: reminderHour) { model.settings.dateOnlyReminderHour = reminderHour }
                        Text("macOS may hide banners during Focus or Do Not Disturb. Reminders only fire while Wren is running.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    section("Data") {
                        Text(model.store?.storeURL?.path ?? "Unavailable")
                            .font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                        Button("Show in Finder") {
                            if let url = model.store?.storeURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                        Text("Everything stays on this Mac. There is no account and no cloud sync.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
        }
        .onAppear { reminderHour = model.settings.dateOnlyReminderHour; model.refreshLoginStatus() }
        .onDisappear(perform: stopRecording)
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
