import SwiftUI
import WrenCore

/// Compact menu-bar popover: a quick list, an editor, and settings. Not a dashboard.
/// True when a pane is shown inside the main window (which has its own sidebar and chrome).
private struct InWindowKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var wrenInWindow: Bool {
        get { self[InWindowKey.self] }
        set { self[InWindowKey.self] = newValue }
    }
}

/// Shows the pane for the current route. Shared by the popover and the main window.
struct RouteView: View {
    @Bindable var model: AppModel
    var body: some View {
        switch model.route {
        case .list, .goals, .review, .overview: ListPane(model: model)
        case let .detail(id):
            if let c = model.item(id) { ItemDetailView(model: model, item: c) } else { ListPane(model: model) }
        case .settings: SettingsView(model: model)
        case .briefing: BriefingView(model: model)
        case .checkIn: CheckInView(model: model)
        case .activity: ActivityView(model: model)
        case .aiSetup: AISetupView(model: model)
        case .connectors: ConnectorsView(model: model)
        case let .connector(id): ConnectorDetailView(model: model, id: id)
        case .delegate: DelegateView(model: model)
        case let .delegation(id): DelegationDetailView(model: model, id: id)
        case .inbox: InboxView(model: model)
        case let .mailMessage(id): MailMessageView(model: model, id: id)
        case let .goal(id):
            if let g = model.goal(id) { GoalDetailView(model: model, goal: g) } else { ListPane(model: model) }
        }
    }
}

/// Compact menu-bar popover: a quick list, an editor, and settings. Not a dashboard.
struct PopoverView: View {
    @Bindable var model: AppModel

    var body: some View {
        RouteView(model: model)
            .frame(width: 380)
            .frame(minHeight: 200, maxHeight: 560)
            .modifier(ConfirmationAlert(model: model))
    }
}

/// The broker's confirmation prompt as a native alert.
struct ConfirmationAlert: ViewModifier {
    @Bindable var model: AppModel
    func body(content: Content) -> some View {
        content.alert("Confirm", isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.cancelPendingConfirmation() } }),
                      presenting: model.confirmation) { _ in
            Button("Cancel", role: .cancel) { model.cancelPendingConfirmation() }
            Button("Confirm", role: .destructive) { model.approvePendingConfirmation() }
        } message: { p in Text(p.prompt) }
    }
}

struct ListPane: View {
    @Bindable var model: AppModel
    @Environment(\.wrenInWindow) private var inWindow
    @State private var draft = ""
    @State private var showClosed = false

    var commitments: [Commitment] { model.pending.filter { $0.kind == .commitment } }
    var others: [Commitment] { model.pending.filter { $0.kind != .commitment } }

    var body: some View {
        VStack(spacing: 0) {
            if !inWindow {
                header
                MainTabs(model: model)
                Divider()
            }
            if let msg = model.storeError ?? model.banner {
                Notice(text: msg, systemImage: "exclamationmark.triangle")
            }
            if let p = model.pauseLabel {
                Notice(text: "\(p). Reminders are kept and will be summarised when you resume.", systemImage: "bell.slash",
                       action: ("Resume", { model.resumeNotifications() }))
            } else if let r = model.resumeNote {
                Notice(text: r, systemImage: "bell", action: ("OK", { model.resumeNote = nil }))
            }
            if model.notificationStatus == .denied {
                Notice(text: "Notifications are off for Wren. Due items appear here instead.", systemImage: "bell.slash",
                       action: ("Open Settings", { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }))
            } else if model.notificationStatus == .notDetermined {
                Notice(text: "Allow notifications so Wren can remind you.", systemImage: "bell",
                       action: ("Allow…", { model.requestNotificationPermission() }))
            }
            if let err = model.hotKeyError {
                Notice(text: err + " Use the field below or the menu bar.", systemImage: "keyboard")
            }

            if model.route == .goals {
                GoalsPane(model: model)
            } else if model.route == .review {
                ReviewPane(model: model)
            } else {
                itemsBody
            }
            if !inWindow {
                Divider()
                footer
            }
        }
    }

    @ViewBuilder var itemsBody: some View {
            HStack(spacing: 8) {
                Image(systemName: "plus").foregroundStyle(.secondary)
                TextField("Add something…", text: $draft)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        // The same router as the capture panel and voice: "remind me…", "ask GPT…" and
                        // questions run as commands, with their result shown in the panel.
                        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        if let run = model.runInCapturePanel { draft = ""; run(text) }
                        else if model.capture(text, source: .popover) { draft = "" }
                    }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()

            if model.pending.isEmpty && model.closed.isEmpty {
                EmptyState(shortcut: model.hotKeyEnabled ? model.hotKeyDisplay : nil)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !model.dueUndelivered.isEmpty && !model.notifications.canDeliverNow {
                            SectionLabel("Due now")
                            ForEach(model.dueUndelivered) { Row(model: model, item: $0) }
                        }
                        if !commitments.isEmpty {
                            SectionLabel("Commitments")
                            ForEach(commitments) { Row(model: model, item: $0) }
                        }
                        if !others.isEmpty {
                            SectionLabel("Ideas, questions and unsorted")
                            ForEach(others) { Row(model: model, item: $0) }
                        }
                        if !model.closed.isEmpty {
                            Button { withAnimation(.easeOut(duration: 0.15)) { showClosed.toggle() } } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.right").rotationEffect(.degrees(showClosed ? 90 : 0))
                                    Text("Done and dropped")
                                }
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)
                            if showClosed { ForEach(model.closed) { Row(model: model, item: $0) } }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
    }

    var header: some View {
        HStack(spacing: 8) {
            WrenMarkShape(compact: true).frame(width: 16, height: 16)
            Text("Wren").font(.headline)
            Spacer()
            AIBadge(model: model)
            Button { model.route = .briefing } label: { Image(systemName: "sun.max") }
                .buttonStyle(.borderless).help("Today's briefing")
            Button { model.route = .checkIn } label: { Image(systemName: "moon") }
                .buttonStyle(.borderless).help("Evening check-in")
            Button { model.openCapturePanel() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless).help("Capture (\(model.hotKeyDisplay))")
            Button { model.startVoice() } label: { Image(systemName: model.voicePhase.isCapturingPhase ? "mic.fill" : "mic") }
                .buttonStyle(.borderless).foregroundStyle(model.voicePhase.isCapturingPhase ? .red : .primary)
                .help(model.settings.voiceEnabled ? "Voice command (\(model.settings.voiceHotKey.display)). The microphone turns off when you stop speaking." : "Voice command. The microphone turns off when you stop speaking.")
                .accessibilityLabel("Start a voice command")
            Button { model.route = .settings } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Settings")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    var footer: some View {
        HStack(spacing: 10) {
            Button("Open Wren") { model.openMainWindow() }.buttonStyle(.borderless).font(.caption)
            PauseMenu(model: model).font(.caption)
            Spacer()
            Text("\(model.pending.count) open").font(.caption).foregroundStyle(.secondary)
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.caption)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

struct Row: View {
    var model: AppModel
    let item: Commitment
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                item.status == .pending ? model.complete(item) : model.reopen(item)
            } label: {
                Image(systemName: item.status == .completed ? "checkmark.circle.fill" : item.status == .dropped ? "minus.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(item.status == .completed ? WrenTheme.accent : .secondary)
            }
            .buttonStyle(.plain)
            .help(item.status == .pending ? "Mark done" : "Reopen")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(2)
                    .strikethrough(item.status != .pending, color: .secondary)
                    .foregroundStyle(item.status == .pending ? .primary : .secondary)
                meta
            }
            Spacer(minLength: 4)
            if item.status == .pending {
                Menu {
                    Button("Done") { model.complete(item) }
                    Divider()
                    Button("Remind me in 1 minute") { model.remind(item, at: .now.addingTimeInterval(60)) }
                    Button("Snooze 1 hour") { model.snooze(item, until: .now.addingTimeInterval(3600)) }
                    Button("Tonight at 8 PM") { model.snooze(item, until: Self.today(20)) }.disabled(Self.today(20) <= .now)
                    Button("Tomorrow at 9 AM") { model.snooze(item, until: Self.tomorrow(9)) }
                    Divider()
                    Button("Edit…") { model.route = .detail(item.id) }
                    Button("Drop") { model.drop(item) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .opacity(hovering ? 1 : 0.35)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.route = .detail(item.id) }
    }

    @ViewBuilder var meta: some View {
        let parts = metaParts
        if !parts.isEmpty {
            HStack(spacing: 6) {
                ForEach(parts.indices, id: \.self) { i in
                    Label(parts[i].0, systemImage: parts[i].1).labelStyle(.titleAndIcon)
                }
            }
            .font(.caption)
            .foregroundStyle(isOverdue ? Color.orange : .secondary)
        }
    }

    var isOverdue: Bool {
        guard item.status == .pending, let d = item.deadline else { return false }
        return item.deadlineHasTime ? d < .now : Calendar.current.startOfDay(for: .now) > d
    }

    var metaParts: [(String, String)] {
        var p: [(String, String)] = []
        if model.processing.contains(item.id) { p.append(("Reading…", "ellipsis")) }
        if item.kind != .commitment && item.status == .pending { p.append((item.kind.label, "tray")) }
        if let d = item.deadline { p.append((DueText.describe(d, hasTime: item.deadlineHasTime), "calendar")) }
        if let r = item.nextReminderAt, item.status == .pending {
            // Same day as the deadline: the day is already shown, so give only the time.
            let sameDay = item.deadline.map { Calendar.current.isDate($0, inSameDayAs: r) } ?? false
            p.append((sameDay ? r.formatted(date: .omitted, time: .shortened) : DueText.describe(r, hasTime: true), "bell"))
        }
        if item.processing == .failed { p.append(("Couldn't interpret", "exclamationmark.circle")) }
        if let c = item.completedAt { p.append(("Done \(DueText.describe(c, hasTime: false))", "checkmark")) }
        return p
    }

    static func today(_ h: Int) -> Date { Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: .now)! }
    static func tomorrow(_ h: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: today(h))!
    }
}

struct SectionLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
    }
}

struct Notice: View {
    let text: String
    let systemImage: String
    var action: (String, () -> Void)? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action { Button(action.0, action: action.1).controlSize(.small) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
    }
}

struct EmptyState: View {
    let shortcut: String?
    var body: some View {
        VStack(spacing: 10) {
            WrenMarkShape().frame(width: 44, height: 44).foregroundStyle(.tertiary)
            Text("Nothing to remember yet").font(.headline)
            Text(shortcut.map { "Press \($0) anywhere to tell Wren what you need to do." } ?? "Type above to tell Wren what you need to do.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}

/// Pause / resume notifications.
struct PauseMenu: View {
    var model: AppModel
    var body: some View {
        if model.pause != nil {
            Button { model.resumeNotifications() } label: { Label("Resume", systemImage: "bell.slash") }
                .buttonStyle(.borderless).help(model.pauseLabel ?? "")
        } else {
            Menu {
                ForEach(NotificationPause.Option.allCases, id: \.self) { o in Button(o.label) { model.pauseNotifications(o) } }
            } label: { Label("Pause", systemImage: "bell") }
            .menuStyle(.borderlessButton).fixedSize().help("Pause notifications")
        }
    }
}
