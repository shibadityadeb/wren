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
            chip("\(s[.needsSetup] ?? 0) need setup", .orange)
            chip("\(s[.unavailable] ?? 0) unavailable", .red)
            chip("\(s[.notConnected] ?? 0) not connected", .secondary)
            chip("\(s[.planned] ?? 0) planned", .secondary)
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
    @State private var secret = ""
    @State private var clientID = ""
    @State private var working = false

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
                        Notice(text: "Planned for a later version. There's nothing to connect yet.", systemImage: "clock")
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
        case .notion: tokenSetup(state, placeholder: "ntn_…", help: notionHelp) { await model.hub.notion.connect(token: $0) }
        case .openaiAPI: openaiSetup(state)
        case .chatgpt: chatgptSetup(state)
        case .voice: voiceSetup(state)
        case .localFiles, .shortcuts: EmptyView()
        }
    }

    var notionHelp: String {
        "1. In Notion open Settings › Connections › Develop or manage integrations, create an internal integration (read content, insert content), and copy its token.\n2. On each page Wren may use, open ••• › Connections and add the integration. Wren can't see anything else.\n3. Paste the token here. Wren checks it with Notion before saving it in the Keychain."
    }

    func connectedActions(_ state: ConnectorState) -> some View {
        HStack {
            Button("Check again") { working = true; Task { await model.hub.registry.connector(id)?.refresh(); model.connectorsChanged(); working = false } }
            Button("Disconnect", role: .destructive) { model.disconnect(id) }
            if working { ProgressView().controlSize(.small) }
        }
        .controlSize(.small)
    }

    @ViewBuilder func googleSetup(_ state: ConnectorState) -> some View {
        let c = id == .gmail ? model.hub.gmail : model.hub.calendar
        VStack(alignment: .leading, spacing: 8) {
            if !model.googleConfigured {
                Text("Google setup (once, shared by Gmail and Calendar)").font(.callout.weight(.medium))
                Text("Google requires your own OAuth client. In Google Cloud Console: create a project, enable the Gmail API and/or Google Calendar API, set up the OAuth consent screen (add yourself as a test user), then Credentials › Create OAuth client ID › Desktop app. Paste the client ID (and the client secret Google shows for desktop clients; it isn't confidential for desktop apps, but Google's token endpoint asks for it). Both go to the Keychain, never into Wren's source or exports.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Client ID (…apps.googleusercontent.com)", text: $clientID).textFieldStyle(.roundedBorder)
                SecureField("Client secret", text: $secret).textFieldStyle(.roundedBorder)
                Button("Save") { model.saveGoogleConfig(clientID: clientID, secret: secret); secret = "" }.disabled(clientID.isEmpty)
            } else if state.isUsable {
                connectedActions(state)
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
            } else {
                Text("Wren will open Google's consent page in your browser. Requested permission: \(id == .gmail ? "read your email (read-only)" : "see your calendars (read-only)"). Wren never sees your password.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(state == .connecting ? "Waiting for Google…" : (c.google.tokens == nil ? "Connect with Google" : "Reconnect")) { model.connectGoogle(c) }
                        .disabled(state == .connecting).buttonStyle(.borderedProminent).tint(WrenTheme.accent)
                    if case .permissionDenied = state { Button("Disconnect", role: .destructive) { model.disconnect(id) } }
                }
                Text("If your OAuth consent screen is in Testing status, Google lists you as a test user and may expire access after 7 days, so you'd reconnect. Publishing the app (or an internal Workspace app, if your admin allows) avoids that; Google decides.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Change Google client…") { try? model.hub.credentials.delete(GoogleSession.configKey); model.connectorsChanged() }.buttonStyle(.link).font(.caption)
            }
        }
    }

    func tokenSetup(_ state: ConnectorState, placeholder: String, help: String, connect: @escaping (String) async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.isUsable {
                connectedActions(state)
                NotionPeek(model: model)
            } else {
                Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SecureField(placeholder, text: $secret).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Connect") { working = true; let t = secret; secret = ""; Task { await connect(t); model.connectorsChanged(); working = false } }
                        .disabled(secret.isEmpty || working).buttonStyle(.borderedProminent).tint(WrenTheme.accent)
                    if working { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    @ViewBuilder func openaiSetup(_ state: ConnectorState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Optional. API use is billed by OpenAI per request and is separate from any ChatGPT subscription; a ChatGPT plan doesn't include API access. Every request shows the exact text and asks first.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if state.isUsable || !model.hub.openai.models.isEmpty {
                Picker("Model", selection: Binding(get: { model.hub.openai.selectedModel ?? "" }, set: { model.hub.openai.selectedModel = $0.isEmpty ? nil : $0; Task { await model.hub.openai.refresh(); model.connectorsChanged() } })) {
                    Text("Choose…").tag("")
                    ForEach(model.hub.openai.models, id: \.self) { Text($0).tag($0) }
                }
                Text("Models listed by your key. Wren doesn't assume what any model can do.").font(.caption2).foregroundStyle(.tertiary)
                connectedActions(state)
            } else {
                SecureField("sk-…", text: $secret).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Connect") { working = true; let k = secret; secret = ""; Task { await model.hub.openai.connect(key: k); model.connectorsChanged(); working = false } }
                        .disabled(secret.isEmpty || working)
                    if working { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    @ViewBuilder func chatgptSetup(_ state: ConnectorState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Allow handing tasks to ChatGPT", isOn: Binding(get: { model.hub.chatgpt.enabled }, set: {
                model.hub.chatgpt.enabled = $0
                if !$0 { try? model.policyStore?.setGrant(.chatgptHandoff, granted: false) }
                model.connectorsChanged()
            }))
            Picker("Open in", selection: Binding(get: { model.settings.chatgptDestination }, set: { model.settings.chatgptDestination = $0; Task { await model.hub.chatgpt.refresh(); model.connectorsChanged() } })) {
                Text("Default browser (chatgpt.com)").tag("browser")
                Text(ConnectorHub.chatGPTAppURL == nil ? "ChatGPT for Mac (not installed)" : "ChatGPT for Mac").tag("app")
            }
            Text("How it works: Wren prepares a prompt and shows exactly what will leave your Mac. When you approve, Wren copies it and opens ChatGPT. You paste it and press send there. Wren never sends it for you and can't see which model or mode you pick. Paste the answer back in Delegate to save, summarise it locally and turn parts into tasks.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("OpenAI doesn't document a supported way to prefill or submit a prompt by link, so Wren uses the clipboard.")
                .font(.caption2).foregroundStyle(.tertiary)
            Button("Open Delegate") { model.route = .delegate }.controlSize(.small)
        }
    }

    @ViewBuilder func voiceSetup(_ state: ConnectorState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Push-to-talk (hold \(model.settings.voiceHotKey.display))", isOn: Binding(get: { model.settings.voiceEnabled }, set: { model.setVoiceEnabled($0) }))
            Text("Hold the shortcut, speak, release. The text appears in the capture panel for you to correct before it's saved or acted on. You can also click the microphone in the capture panel.")
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
            TextField("Search pages shared with Wren", text: $q).textFieldStyle(.roundedBorder).controlSize(.small)
                .onSubmit { Task { do { pages = try await model.notionSearch(q); error = nil } catch { self.error = model.errorText(error) } } }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            ForEach(pages) { p in
                HStack {
                    Text(p.title).font(.caption)
                    Spacer()
                    if let u = p.url { Link("Open", destination: u).font(.caption) }
                }
            }
            Text("Only pages shared with your integration appear here.").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
