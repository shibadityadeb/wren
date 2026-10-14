import SwiftUI
import WrenCore

/// All connectors, their real state, and an honest summary.
struct ConnectorsView: View {
    @Bindable var model: AppModel
    @Environment(\.wrenInWindow) private var inWindow

    var body: some View {
        let _ = model.connectorVersion
        let reg = model.hub.registry
        VStack(spacing: 0) {
            if !inWindow { PaneHeader(model: model, title: "Connectors") ; Divider() }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary(reg)
                    if reg.summary[.connected] == nil {
                        Text("Nothing is connected yet. Everything in Wren works without connectors; each one adds something specific and asks before anything leaves your Mac.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(ConnectorCatalog.all) { d in ConnectorRow(model: model, descriptor: d, state: reg.state(d.id)) }
                    HStack {
                        Spacer()
                        Button("Check all again") { model.refreshConnectors() }.controlSize(.small)
                    }
                }
                .padding(14)
            }
        }
    }

    func summary(_ reg: ConnectorRegistry) -> some View {
        let s = reg.summary
        return HStack(spacing: 10) {
            chip("\(s[.connected] ?? 0) connected", WrenTheme.accent)
            chip("\(s[.needsSetup] ?? 0) need your attention", .orange)
            chip("\(s[.unavailable] ?? 0) unavailable", .red)
            chip("\(s[.notConnected] ?? 0) available to connect", .secondary)
            chip("\(s[.planned] ?? 0) not implemented", .secondary)
        }
        .font(.caption)
    }

    func chip(_ t: String, _ c: Color) -> some View {
        Text(t).padding(.horizontal, 8).padding(.vertical, 3).background(c.opacity(0.12), in: Capsule()).foregroundStyle(c == .secondary ? Color.secondary : c)
    }
}

struct StateBadge: View {
    let state: ConnectorState
    var color: Color {
        switch state.bucket {
        case .connected: WrenTheme.accent
        case .needsSetup: .orange
        case .unavailable: .red
        case .notConnected, .planned: .secondary
        }
    }
    var body: some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 7, height: 7); Text(state.label) }
            .font(.caption).foregroundStyle(color == .secondary ? Color.secondary : color)
    }
}

struct ConnectorRow: View {
    var model: AppModel
    let descriptor: ConnectorDescriptor
    let state: ConnectorState
    var body: some View {
        Button { model.route = .connector(descriptor.id) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: descriptor.systemImage).font(.title3).frame(width: 28).foregroundStyle(descriptor.isPlanned ? .secondary : WrenTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(descriptor.name).font(.body.weight(.medium))
                        Spacer()
                        StateBadge(state: state)
                    }
                    Text(descriptor.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if let d = state.detail { Text(d).font(.caption2).foregroundStyle(.tertiary).lineLimit(2) }
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One connector: what it does, its real state, permissions, privacy, and the right actions.
struct ConnectorDetailView: View {
    @Bindable var model: AppModel
    let id: ConnectorID
    @State private var working = false
    @State private var recordingVoiceKey = false
    @State private var detectionNote: String?
    @State private var voiceKeyMonitor: Any?

    var descriptor: ConnectorDescriptor { ConnectorCatalog.descriptor(id) }

    var body: some View {
        let _ = model.connectorVersion
        let state = model.hub.registry.state(id)
        let status = model.hub.statusStore.status(id)
        VStack(spacing: 0) {
            HStack {
                Button { model.route = .connectors } label: { Label("Connectors", systemImage: "chevron.left") }.buttonStyle(.borderless)
                Spacer()
                StateBadge(state: state)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: descriptor.systemImage).font(.largeTitle).foregroundStyle(WrenTheme.accent)
                        VStack(alignment: .leading) {
                            Text(descriptor.name).font(.title2.weight(.semibold))
                            if let d = state.detail { Text(d).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                    Text(descriptor.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                    if descriptor.isPlanned {
                        Notice(text: "Not implemented yet. There's nothing to connect, and Wren doesn't offer it anywhere until it works.", systemImage: "clock")
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        setup(state)
                    }
                    section("What it can do") {
                        ForEach(descriptor.capabilities) { c in
                            Label {
                                Text(c.name + (c.external ? " · leaves your Mac" : " · on this Mac")).font(.callout)
                            } icon: {
                                Image(systemName: c.implemented ? "checkmark.circle" : "clock").foregroundStyle(c.implemented ? WrenTheme.accent : .secondary)
                            }
                            .foregroundStyle(c.implemented ? .primary : .secondary)
                        }
                        Text("Clock icon: not built yet.").font(.caption2).foregroundStyle(.tertiary)
                    }
                    section("Sign-in") { Text(descriptor.auth.label).font(.callout) }
                    if !descriptor.permissions.isEmpty {
                        section("Wren permissions") {
                            ForEach(descriptor.permissions, id: \.self) { p in
                                HStack {
                                    Text(p.rawValue).font(.caption.monospaced())
                                    Spacer()
                                    Text(model.policy.grants.contains(p) ? "Granted" : "Not granted").font(.caption)
                                        .foregroundStyle(model.policy.grants.contains(p) ? WrenTheme.accent : .secondary)
                                }
                            }
                            Text("Granted while connected, removed when you disconnect. Writes and anything leaving your Mac still ask each time.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    section("Privacy") {
                        Text(descriptor.privacy).font(.callout).fixedSize(horizontal: false, vertical: true)
                        if !descriptor.cleanup.isEmpty { Text(descriptor.cleanup).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    if status.lastSuccessfulSync != nil || status.lastError != nil {
                        section("Status") {
                            if let s = status.lastSuccessfulSync { Text("Last successful check: \(s.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                            if let e = status.lastError { Text("Last error: \(e)").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder func setup(_ state: ConnectorState) -> some View {
        switch id {
        case .gmail, .googleCalendar: googleSetup(state)
        case .macCalendar: macCalendarSetup(state)
        case .notion: notionSetup(state)
        case .chatgpt: chatgptSetup(state)
        case .voice: voiceSetup(state)
        case .localFiles, .shortcuts, .slack: EmptyView()
        }
    }

    func connectedActions(_ state: ConnectorState) -> some View {
        HStack {
            Button("Check again") { working = true; Task { await model.hub.registry.connector(id)?.refresh(); model.connectorsChanged(); working = false } }
            Button("Disconnect", role: .destructive) { model.disconnect(id) }
            if working { ProgressView().controlSize(.small) }
        }
        .controlSize(.small)
    }

    /// A provider this build doesn't include: say so plainly, with nothing for the user to configure.
    func notInBuild(_ state: ConnectorState) -> some View {
        Notice(text: state.detail ?? "Maintainer setup required.", systemImage: "shippingbox")
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder func googleSetup(_ state: ConnectorState) -> some View {
        let c = id == .gmail ? model.hub.gmail : model.hub.calendar
        VStack(alignment: .leading, spacing: 10) {
            if !c.isConfigured {
                notInBuild(state)
            } else {
                GoogleAccountCard(model: model, focus: id)
                if state.isUsable {
                    if id == .gmail {
                        Toggle("Keep a 7-day local cache of headers and previews", isOn: Binding(get: { model.settings.gmailCacheEnabled }, set: {
                            model.settings.gmailCacheEnabled = $0
                            model.hub.gmail.emailCache = $0 ? EmailCache(directory: WrenStore.defaultDirectory) : nil
                            if !$0 { EmailCache(directory: WrenStore.defaultDirectory).clear() }
                        })).font(.callout)
                        Text("Off by default: mail is fetched when you ask and not stored.").font(.caption).foregroundStyle(.secondary)
                        ImportantSendersEditor(model: model)
                    }
                    Toggle("Include in the morning briefing", isOn: Binding(get: { model.policy.rules.contains(.includeConnectedSourcesInBriefing) },
                                                                          set: { model.setRule(.includeConnectedSourcesInBriefing, $0) })).font(.callout)
                    if id == .googleCalendar { CalendarPeek(model: model) }
                }
            }
        }
    }

    @ViewBuilder func macCalendarSetup(_ state: ConnectorState) -> some View {
        let m = model.hub.macCalendar
        VStack(alignment: .leading, spacing: 8) {
            if state.isUsable {
                connectedActions(state)
                Toggle("Include in the morning briefing", isOn: Binding(get: { model.policy.rules.contains(.includeConnectedSourcesInBriefing) },
                                                                      set: { model.setRule(.includeConnectedSourcesInBriefing, $0) })).font(.callout)
                CalendarPeek(model: model)
                Text("To add a Google calendar here, add your Google account in System Settings › Internet Accounts and turn on Calendars.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Wren reads the calendars already on this Mac in Apple's Calendar app: iCloud, Google, Outlook and others you added in System Settings › Internet Accounts. Read-only, and nothing leaves your Mac. No sign-in: macOS asks once for access.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(m.enabled && m.status != .notDetermined ? "Check again" : "Use this Mac's calendars") {
                        if m.enabled && m.status != .notDetermined { Task { await m.refresh(); model.connectorsChanged() } } else { model.connectMacCalendar() }
                    }.buttonStyle(.borderedProminent).tint(WrenTheme.accent)
                    if case .missingPermissions = state {
                        Button("Privacy Settings…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!) }
                    }
                }
            }
        }
    }

    @ViewBuilder func notionSetup(_ state: ConnectorState) -> some View {
        let n = model.hub.notion
        VStack(alignment: .leading, spacing: 8) {
            if state.isUsable {
                if let w = n.workspace { Text("Connected to the workspace “\(w)”").font(.callout) }
                connectedActions(state)
                NotionPeek(model: model)
            } else {
                Text("Wren opens Notion's sign-in page in your browser. Sign in, choose the workspace, and allow access. You come back to Wren automatically. There's nothing to set up in Notion first.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("Wren uses Notion's official connection for apps (Notion MCP). It reads pages when you ask and creates a page only after you confirm. Notion asks you to connect again after 30 days without use.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(state == .connecting ? "Waiting for Notion…" : (n.isSignedIn ? "Reconnect" : "Connect Notion")) { model.connectNotion() }
                        .disabled(state == .connecting).buttonStyle(.borderedProminent).tint(WrenTheme.accent)
                    if n.isSignedIn { Button("Disconnect", role: .destructive) { model.disconnect(id) } }
                }
                if let e = n.lastConnectError { Text(e).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }
            if let note = n.disconnectNote { Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
    }

    @ViewBuilder func chatgptSetup(_ state: ConnectorState) -> some View {
        let c = model.hub.chatgpt
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(c.account.title).font(.callout.weight(.semibold))
                if let r = c.account.reason, c.account != .planEnabled { Text(r).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let e = c.email, c.account != .notConnected {
                    Text("Account: \(e)\(c.planType.map { " · plan reported by ChatGPT: \($0.capitalized)" } ?? "")").font(.caption)
                }
                if c.isUsingPlan {
                    HStack(spacing: 10) {
                        Label("Using ChatGPT plan", systemImage: "checkmark.seal.fill").font(.caption.weight(.medium)).foregroundStyle(WrenTheme.accent)
                        Link("Manage usage", destination: SIWC.manageUsageURL).font(.caption)
                    }
                }
            }
            switch c.account {
            case .notConnected, .connecting:
                Button(c.account == .connecting ? "Waiting for ChatGPT…" : "Continue with ChatGPT") { model.connectChatGPT() }
                    .disabled(c.account == .connecting).buttonStyle(.borderedProminent).tint(WrenTheme.accent)
                Text("Opens OpenAI's sign-in page in your browser. Approve Wren there, including use of your ChatGPT plan. No API key, no setup.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .accountOnly:
                HStack {
                    Button("Allow plan usage…") { model.connectChatGPT(reconsent: true) }.buttonStyle(.borderedProminent).tint(WrenTheme.accent)
                    Button("Disconnect", role: .destructive) { model.disconnect(id) }
                }.controlSize(.small)
            case .reauthorizationRequired:
                HStack {
                    Button("Reconnect") { model.connectChatGPT() }.buttonStyle(.borderedProminent).tint(WrenTheme.accent)
                    Button("Disconnect", role: .destructive) { model.disconnect(id) }
                }.controlSize(.small)
            case .usageLimitReached:
                Link("Manage usage in ChatGPT", destination: SIWC.manageUsageURL).font(.callout)
                connectedActions(state)
            case .planEnabled, .temporarilyUnavailable:
                if !c.models.isEmpty {
                    Picker("Model", selection: Binding(get: { c.selectedModel ?? "" }, set: { c.selectedModel = $0.isEmpty ? nil : $0; model.connectorsChanged() })) {
                        ForEach(c.models) { Text($0.displayName).tag($0.slug) }
                    }
                    .frame(maxWidth: 360)
                    Text("Models ChatGPT lists for your account.").font(.caption2).foregroundStyle(.tertiary)
                }
                connectedActions(state)
            }
            Text("Sign-in powers “Run with connected ChatGPT in Wren”. It uses your ChatGPT plan's allowance; Wren never switches to paid API billing, background tasks never use your plan, and Wren can't see your ChatGPT conversations or memories.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let note = c.disconnectNote { Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Divider()
            Text("When you ask GPT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Picker("“Ask GPT …” goes to", selection: Binding(get: { model.settings.chatgptMode }, set: { model.settings.chatgptMode = $0; model.connectorsChanged() })) {
                ForEach(ChatGPTMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text(model.settings.chatgptMode == .web
                 ? "The ChatGPT website (default): Wren opens ChatGPT in your browser with your request, and you send it there. It becomes a normal ChatGPT conversation you can continue and find in your history. OpenAI offers no supported way for an app to create that conversation or read its answer, so Wren shows it as awaiting your submission and never as done. Link the conversation to return to it in one click."
                 : "Connected ChatGPT in Wren: Wren sends the request through your plan (Sign in with ChatGPT above) and shows the real answer and completion here. The request and answer are stored in Wren; they aren't a ChatGPT conversation and don't appear in ChatGPT's history.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Let Wren open ChatGPT in my browser with my request", isOn: Binding(get: { c.handoffEnabled }, set: { c.handoffEnabled = $0; model.connectorsChanged() }))
                .font(.callout)
            if c.handoffEnabled {
                Picker("Open in", selection: Binding(get: { model.settings.chatgptDestination }, set: { model.settings.chatgptDestination = $0; model.connectorsChanged() })) {
                    Text("Default browser (chatgpt.com)").tag("browser")
                    Text(ConnectorHub.chatGPTAppURL == nil ? "ChatGPT for Mac (not installed)" : "ChatGPT for Mac (paste the request there)").tag("app")
                }
                .frame(maxWidth: 380)
                prefillSetup
            }
            Button("Open Delegate") { model.route = .delegate }.controlSize(.small)
        }
    }

    /// How "Ask in ChatGPT" reaches the website: the question in the message box (`?q=`), and
    /// optional detection of the conversation it starts.
    @ViewBuilder var prefillSetup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Put my question in ChatGPT's message box", isOn: Binding(get: { model.settings.chatgptPrefill }, set: { model.settings.chatgptPrefill = $0; model.connectorsChanged() }))
                .disabled(model.settings.chatgptDestination == "app")
            Text("Uses a chatgpt.com/?q=… link. OpenAI doesn't document it and may change it. Checked in Chrome on 14 October 2026: ChatGPT takes the question in but doesn't send it, so you press Enter there. Off, or for questions over \(ChatGPTWeb.maxPrefillCharacters) characters, Wren copies the question for you to paste.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Detect when I send it, and save the conversation link", isOn: Binding(get: { model.settings.chatgptDetectConversation }, set: { on in
                if on { Task { detectionNote = await model.detectConversationPermission(); model.connectorsChanged() } }
                else { model.settings.chatgptDetectConversation = false; model.connectorsChanged() }
            }))
            .disabled(BrowserTabs.defaultBrowser == nil || !model.settings.chatgptPrefill)
            Text(BrowserTabs.defaultBrowser.map { "Wren reads only the address of the ChatGPT tab it opened, through \($0.name)'s standard scripting. When it turns into a chatgpt.com/c/… conversation, your question was really sent, and Wren saves that link. No page content, other tabs, cookies or passwords. macOS asks you once." }
                 ?? "Available when your default browser is Chrome, Brave, Edge, Chromium or Vivaldi (yours is \(BrowserTabs.defaultBrowserName)). Link conversations yourself instead.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let detectionNote { Text(detectionNote).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.leading, 18)
    }

    @ViewBuilder func voiceSetup(_ state: ConnectorState) -> some View {
        let speech = LocalSpeechModel.status()
        VStack(alignment: .leading, spacing: 10) {
            Text("Push-to-talk: hold \(model.settings.voiceHotKey.display) anywhere, say what you need, and let go. Wren turns the microphone off the moment you release, transcribes on this Mac, shows what it heard and runs it. It never listens in the background.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { model.startVoice() } label: { Label(model.voicePhase.isCapturingPhase ? "Stop recording" : "Start a voice command", systemImage: "mic.fill") }
                    .buttonStyle(.borderedProminent).tint(WrenTheme.accent)
                HStack(spacing: 6) {
                    Circle().fill(voiceDotColor).frame(width: 8, height: 8)
                    Text(voiceStatusText).font(.caption)
                }
            }
            Divider()
            Toggle("Push-to-talk shortcut (hold to speak)", isOn: Binding(get: { model.settings.voiceEnabled }, set: { model.setVoiceEnabled($0) }))
            HStack {
                Text(recordingVoiceKey ? "Press the new shortcut…" : model.settings.voiceHotKey.display)
                    .font(.body.monospaced()).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                Button(recordingVoiceKey ? "Cancel" : "Change…") { recordingVoiceKey ? stopVoiceKeyRecording() : startVoiceKeyRecording() }
                    .disabled(!model.settings.voiceEnabled)
                Button("Reset") { model.setVoiceHotKey(.optionSpace) }.disabled(!model.settings.voiceEnabled)
            }
            if let e = model.voiceHotKeyError { Text(e).font(.caption).foregroundStyle(.orange) }
            Text("Hold it while you speak; letting go of either key ends the recording. Escape cancels. Pressing it again while a command is being transcribed or run does nothing, so one utterance never runs twice. Works with Wren's window closed. Typed capture uses \(model.hotKeyDisplay). The Voice button in the capture panel, the menu-bar popover and the menu-bar item's menu records too (click, speak, pause), even with the shortcut off.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Check what I said before Wren acts", isOn: Binding(get: { model.settings.voiceReviewFirst }, set: { model.settings.voiceReviewFirst = $0; model.connectorsChanged() }))
            Text("Off (default): a clearly heard command runs right after it's transcribed. On: the words wait in the panel until you press Return. Either way, Wren asks first when it isn't sure it heard you, and never runs an empty recording.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Local transcription model").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                Image(systemName: speech.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(speech.isReady ? WrenTheme.accent : .orange)
                Text(speech.label).font(.callout)
                Spacer()
                Button("Check again") { model.connectorsChanged() }.controlSize(.small)
                if !speech.isReady { Button("Dictation Settings…") { NSWorkspace.shared.open(LocalSpeechModel.dictationSettingsURL) }.controlSize(.small) }
            }
            Text("Wren uses Apple's on-device speech model. macOS downloads, updates and removes it (System Settings › Keyboard › Dictation, choose the language); Wren adds no model of its own, needs no account, and refuses server recognition. Audio goes straight to the on-device recogniser and is never saved or sent anywhere.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Microphone: \(model.hub.voicePermissions.microphone.rawValue)").font(.caption)
                Text("Speech recognition: \(model.hub.voicePermissions.speech.rawValue)").font(.caption)
                Spacer()
                Button("Privacy Settings…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }.controlSize(.small)
            }
            .foregroundStyle(.secondary)
        }
    }

    var voiceDotColor: Color {
        switch model.voicePhase {
        case .listening: .red
        case .failed: .orange
        default: .secondary
        }
    }

    var voiceStatusText: String {
        switch model.voicePhase {
        case .idle, .cancelled, .completed, .needsClarification: "Microphone off"
        case .requestingPermission: "Waiting for macOS permission (microphone off)"
        case .listening: "Recording a command (microphone on)"
        case .transcribing: "Transcribing on this Mac (microphone off)"
        case .transcriptReady, .processing: "Working on your command (microphone off)"
        case let .failed(e): e.localizedDescription
        }
    }

    func startVoiceKeyRecording() {
        recordingVoiceKey = true
        model.voiceHotKeyError = nil
        voiceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopVoiceKeyRecording(); return nil }
            if let spec = HotKeyService.spec(from: event) { model.setVoiceHotKey(spec); stopVoiceKeyRecording() }
            else { model.voiceHotKeyError = "Include ⌘, ⌥ or ⌃ in the shortcut." }
            return nil
        }
    }

    func stopVoiceKeyRecording() {
        if let voiceKeyMonitor { NSEvent.removeMonitor(voiceKeyMonitor) }
        voiceKeyMonitor = nil
        recordingVoiceKey = false
    }
}

struct ImportantSendersEditor: View {
    var model: AppModel
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Important senders (always flagged)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("e.g. priya@acme.com, @school.edu", text: $text).textFieldStyle(.roundedBorder).controlSize(.small)
                .onSubmit { model.settings.importantSenders = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                .onAppear { text = model.settings.importantSenders.joined(separator: ", ") }
        }
    }
}

/// Today's events from Calendar, to show the connection is real.
struct CalendarPeek: View {
    var model: AppModel
    @State private var events: [CalendarEvent] = []
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Today and tomorrow").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            ForEach(events) { e in
                HStack {
                    Text("\(e.timeText(calendar: model.clock.calendar, now: model.clock.now)) · \(e.title)").font(.caption).lineLimit(1)
                    Spacer()
                    Button("Remind me") { model.reminderFromEvent(e) }.controlSize(.mini)
                }
            }
            if events.isEmpty && error == nil { Text("No events.").font(.caption).foregroundStyle(.secondary) }
        }
        .task {
            let cal = model.clock.calendar
            do { events = try await model.fetchEvents(from: model.clock.now, to: cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: model.clock.now))!, origin: .user(.popover)) }
            catch { self.error = model.errorText(error) }
        }
    }
}

struct NotionPeek: View {
    var model: AppModel
    @State private var q = ""
    @State private var pages: [NotionPage] = []
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Search Notion", text: $q).textFieldStyle(.roundedBorder).controlSize(.small)
                .onSubmit { Task { do { pages = try await model.notionSearch(q); error = nil } catch { self.error = model.errorText(error) } } }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            ForEach(pages) { p in
                HStack {
                    Text(p.title).font(.caption)
                    Spacer()
                    if let u = p.url { Link("Open", destination: u).font(.caption) }
                }
            }
            Text("Searches the Notion workspace you connected.").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}


/// One Google sign-in for Gmail and Calendar: what Wren may read, Google's permission screen, and
/// afterwards the account, the permissions Google actually granted, and reconnect/disconnect.
struct GoogleAccountCard: View {
    var model: AppModel
    let focus: ConnectorID
    @State private var wantGmail = true
    @State private var wantCalendar = true

    var body: some View {
        let _ = model.connectorVersion
        let g = model.hub.google
        let granted = g.grantedScopes
        VStack(alignment: .leading, spacing: 8) {
            Text("Google account").font(.callout.weight(.semibold))
            if let notice = model.hub.providers.googleStatus.userNotice, !g.isSignedIn || model.hub.providers.googleStatus == .testing {
                Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.googleConnecting {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Waiting for you to finish on Google's page in your browser…").font(.callout) }
            } else if !g.isSignedIn {
                Text("Wren opens Google's sign-in page in your browser. Choose your account, review the permissions, and approve. You come straight back to Wren.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $wantGmail) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Read my email (read-only)")
                        Text("Search messages, answer questions like “anything from the recruiter?”, summarise mail and suggest tasks. Wren can't send, delete, archive or change anything.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.toggleStyle(.checkbox)
                Toggle(isOn: $wantCalendar) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("See my calendars (read-only)")
                        Text("Read upcoming events to answer “what meetings do I have tomorrow?” and add them to the briefing. Wren can't create or change events.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.toggleStyle(.checkbox)
                Button("Connect Google") { model.connectGoogle(scopes: chosen) }
                    .buttonStyle(.borderedProminent).tint(WrenTheme.accent).disabled(chosen.isEmpty)
                Text("Your Google password goes only to Google. Wren keeps the sign-in in a private file on this Mac, and you can untick a permission on Google's page too.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Connected as \(g.email ?? "your Google account")").font(.callout)
                permissionRow("Read email (read-only)", granted.contains(GoogleAccount.gmailScope), add: GoogleAccount.gmailScope)
                permissionRow("See calendars (read-only)", granted.contains(GoogleAccount.calendarScope), add: GoogleAccount.calendarScope)
                HStack {
                    Button("Check again") { Task { await model.hub.gmail.refresh(); await model.hub.calendar.refresh(); model.connectorsChanged() } }
                    Button("Reconnect") { model.connectGoogle(scopes: Array(granted.isEmpty ? [GoogleAccount.gmailScope, GoogleAccount.calendarScope] : granted)) }
                    Button("Disconnect Google", role: .destructive) { model.disconnectGoogle() }
                }.controlSize(.small)
                Text("Disconnecting removes Wren's access to both Gmail and Calendar at Google and deletes the sign-in from this Mac.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            if let e = model.googleError { Text(e).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if let n = g.disconnectNote { Text(n).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { wantGmail = focus == .gmail || !g.isSignedIn; wantCalendar = focus == .googleCalendar || !g.isSignedIn }
    }

    var chosen: [String] {
        (wantGmail ? [GoogleAccount.gmailScope] : []) + (wantCalendar ? [GoogleAccount.calendarScope] : [])
    }

    func permissionRow(_ title: String, _ on: Bool, add scope: String) -> some View {
        HStack {
            Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? WrenTheme.accent : .secondary)
            Text(title).font(.callout)
            Text(on ? "Granted" : "Not granted").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !on { Button("Add…") { model.connectGoogle(scopes: [scope]) }.controlSize(.small) }
        }
    }
}
