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

                    section("Local language model") {
                        Toggle("Use Ollama to understand captures", isOn: Binding(get: { model.settings.useModel }, set: { model.setUseModel($0) }))
                        switch model.modelStatus {
                        case let .ready(names):
                            Picker("Model", selection: Binding(get: { model.selectedModel ?? "" }, set: { model.selectModel($0) })) {
                                ForEach(names, id: \.self) { Text($0).tag($0) }
                            }
                        case .noChatModel:
                            setup("Ollama is running but has no chat model. On 8 GB of RAM a 3B model works well:", "ollama pull qwen2.5:3b")
                        case .unreachable:
                            setup("Ollama isn't reachable at 127.0.0.1:11434. Start it, then refresh:", "ollama serve")
                        case .checking: ProgressView().controlSize(.small)
                        case .off: EmptyView()
                        }
                        HStack {
                            Text(model.modelStatus.summary).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Refresh") { Task { await model.refreshModels(); model.processAwaiting() } }.controlSize(.small)
                        }
                        Text("Wren only talks to Ollama on this Mac. Captures are always saved first, and dates are read with built-in rules even without a model. Wren never downloads models.")
                            .font(.caption).foregroundStyle(.secondary)
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
        .onAppear { reminderHour = model.settings.dateOnlyReminderHour }
        .onDisappear(perform: stopRecording)
    }

    var notificationText: String {
        switch model.notificationStatus {
        case .authorized, .provisional: "Allowed"
        case .denied: "Turned off in System Settings"
        default: "Not yet allowed"
        }
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
