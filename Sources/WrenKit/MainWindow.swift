import AppKit
import SwiftUI
import WrenCore

/// The window you see when you open Wren from Applications. Same data and panes as the
/// menu-bar popover, with room to read.
struct MainWindowView: View {
    @Bindable var model: AppModel

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview", items = "Items", goals = "Goals", review = "Review", delegate = "Delegate",
             connectors = "Connectors", localAI = "Local AI", settings = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .overview: "house"
            case .items: "checklist"
            case .goals: "scope"
            case .review: "tray.full"
            case .delegate: "arrow.up.forward.app"
            case .connectors: "puzzlepiece.extension"
            case .localAI: "cpu"
            case .settings: "gearshape"
            }
        }
        var route: Route {
            switch self {
            case .overview: .overview
            case .items: .list
            case .goals: .goals
            case .review: .review
            case .delegate: .delegate
            case .connectors: .connectors
            case .localAI: .aiSetup
            case .settings: .settings
            }
        }
    }

    var selection: Binding<Section?> {
        Binding(get: {
            switch model.route {
            case .overview: .overview
            case .list, .detail, .briefing, .checkIn: .items
            case .goals, .goal: .goals
            case .review: .review
            case .aiSetup: .localAI
            case .delegate: .delegate
            case .connectors, .connector: .connectors
            case .settings, .activity: .settings
            }
        }, set: { if let s = $0 { model.route = s.route } })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(Section.allCases) { s in
                    Label {
                        HStack {
                            Text(s.rawValue)
                            Spacer()
                            if s == .review && !model.insights.isEmpty {
                                Text("\(model.insights.count)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: { Image(systemName: s.icon) }
                    .tag(s)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                Button { model.openCapturePanel() } label: {
                    Label("New capture", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(WrenTheme.accent)
                .padding(12)
            }
        } detail: {
            Group {
                if model.route == .overview {
                    OverviewView(model: model)
                } else {
                    RouteView(model: model)
                        .environment(\.wrenInWindow, true)
                        .frame(maxWidth: 640)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .modifier(ConfirmationAlert(model: model))
        .frame(minWidth: 760, minHeight: 540)
        .onAppear { model.reload(); model.refreshBackups(); Task { await model.refreshAI() } }
    }
}

struct OverviewView: View {
    @State private var showNewReminder = false
    @Bindable var model: AppModel

    var body: some View {
        let b = model.briefing
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let p = model.pauseLabel {
                    Notice(text: "\(p). Nothing is lost; reminders are summarised when you resume.", systemImage: "bell.slash",
                           action: ("Resume", { model.resumeNotifications() }))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if let msg = model.storeError ?? model.banner ?? model.resumeNote {
                    Notice(text: msg, systemImage: "info.circle").clipShape(RoundedRectangle(cornerRadius: 8))
                }
                tiles
                today(b)
                ConnectedToday(model: model)
                aiCard
                Text("Your data stays on this Mac in ~/Library/Application Support/Wren. Wren lives in the menu bar too: close this window and it keeps reminding you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    var header: some View {
        HStack(alignment: .center, spacing: 16) {
            WrenLogo(size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("Wren").font(.largeTitle.weight(.semibold))
                Text("Remembers what you said you'd do, helps you follow through, and brings important things back to your attention.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    Button { showNewReminder = true } label: { Label("New reminder", systemImage: "bell.badge") }
                    Button { model.openCapturePanel() } label: { Label("New capture", systemImage: "square.and.pencil") }
                        .buttonStyle(.borderedProminent).tint(WrenTheme.accent)
                }
                .sheet(isPresented: $showNewReminder) { NewReminderSheet(model: model) }
                if model.hotKeyEnabled {
                    Text("or press \(model.hotKeyDisplay) anywhere").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    var tiles: some View {
        let commitments = model.pending.filter { $0.kind == .commitment }.count
        let goals = model.goals.filter { $0.status == .active }.count
        let waiting = model.pending.filter { $0.kind == .waiting }.count
        return HStack(spacing: 12) {
            tile("\(commitments)", "Open commitments", "checklist") { model.route = .list }
            tile("\(goals)", "Active goals", "scope") { model.route = .goals }
            tile("\(waiting)", "Waiting on others", "hourglass") { model.route = .list }
            tile("\(model.insights.count)", "To review", "tray.full") { model.route = .review }
        }
    }

    func tile(_ value: String, _ label: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).foregroundStyle(WrenTheme.accent)
                Text(value).font(.title.weight(.semibold).monospacedDigit())
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder func today(_ b: Briefing) -> some View {
        let listed = Set((b.overdue + b.dueToday).map(\.id))
        let reminders = model.pending.compactMap { c -> (Commitment, Date)? in c.nextReminderAt.map { (c, $0) } }
            .filter { $0.1 > model.clock.now && !listed.contains($0.0.id) }.sorted { $0.1 < $1.1 }.prefix(5)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Today").font(.title3.weight(.semibold))
                Spacer()
                Button("Full briefing") { model.route = .briefing }.buttonStyle(.link)
                Button("Check-in") { model.route = .checkIn }.buttonStyle(.link)
            }
            if b.overdue.isEmpty && b.dueToday.isEmpty && reminders.isEmpty {
                Text("Nothing overdue or due today.").foregroundStyle(.secondary)
            }
            group("Overdue", b.overdue, color: .orange)
            group("Due today", b.dueToday, color: .primary)
            if !reminders.isEmpty {
                Text("Upcoming reminders").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(reminders), id: \.0.id) { c, at in
                    row(c.title, DueText.describe(at, hasTime: true), id: c.id)
                }
            }
        }
    }

    @ViewBuilder func group(_ title: String, _ items: [SummaryItem], color: Color) -> some View {
        if !items.isEmpty {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(color == .orange ? Color.orange : .secondary)
            ForEach(items) { i in row(i.title, i.deadline.map { DueText.describe($0, hasTime: i.deadlineHasTime) } ?? "", id: i.id) }
        }
    }

    func row(_ title: String, _ detail: String, id: UUID) -> some View {
        Button { model.route = .detail(id) } label: {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }

    var aiCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(model.ai.isReady ? WrenTheme.accent : (model.ai.usableModel != nil ? Color.secondary : .orange)).frame(width: 8, height: 8)
                Text("Local AI: \(model.ai.title)").font(.callout.weight(.medium))
                Spacer()
                Button(model.ai.isReady ? "Details" : "Set up") { model.route = .aiSetup }
            }
            if !model.ai.isReady, !model.ai.detail.isEmpty {
                Text(model.ai.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Without AI, Wren still saves everything you capture, reads dates like “Friday at 3”, reminds you, sends the briefing and check-in, tracks goals, and understands set phrases like “move that to Sunday”. A local model adds cleaner titles, better classification and more natural requests.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Owns the main window. Wren stays a menu-bar app (no Dock icon); the window is brought
/// to the front explicitly whenever the user asks for it.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Wren"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: MainWindowView(model: model))
            w.contentMinSize = NSSize(width: 760, height: 540)
            w.setFrameAutosaveName("WrenMainWindow")
            if !w.setFrameUsingName("WrenMainWindow") { w.center() }
            if w.frame.width < 760 || w.frame.height < 560 {
                w.setContentSize(NSSize(width: max(920, w.frame.width), height: max(640, w.frame.height))); w.center()
            }
            w.delegate = self
            w.collectionBehavior.insert(.fullScreenPrimary)
            window = w
        }
        if model.route == .list { model.route = .overview }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func windowWillClose(_ notification: Notification) {
        if model.route == .overview { model.route = .list }
    }
}

/// The real Wren logo: the app icon generated from assets/logo.png. Falls back to the
/// vector mark traced from the same logo on its cream tile.
struct WrenLogo: View {
    var size: CGFloat
    static let icon: NSImage? = Bundle.main.url(forResource: "Wren", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    var body: some View {
        Group {
            if let icon = Self.icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(WrenTheme.ivory)
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(Color(white: 0.14), lineWidth: max(1, size * 0.03))
                    WrenMarkShape().fill(Color.black).padding(size * 0.2)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Wren logo")
    }
}

/// Today's events and mail needing attention, only when those connectors are connected.
struct ConnectedToday: View {
    var model: AppModel
    @State private var events: [CalendarEvent] = []
    @State private var mail: [EmailTriage] = []
    @State private var problems: [String] = []

    var body: some View {
        let _ = model.connectorVersion
        let cal = model.calendarUsable, gm = model.hub.gmail.state.isUsable
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("From your connected accounts").font(.title3.weight(.semibold))
                Spacer()
                Button("Connectors") { model.route = .connectors }.buttonStyle(.link)
            }
            if !cal && !gm {
                Text("Connect Gmail or Google Calendar to see today's events and the mail that needs you here. Nothing is connected now.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if cal {
                Text("Calendar today").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if events.isEmpty { Text("No more events today.").font(.callout).foregroundStyle(.secondary) }
                ForEach(events) { e in
                    HStack {
                        Text("\(e.timeText(calendar: model.clock.calendar, now: model.clock.now)) · \(e.title)").lineLimit(1)
                        Spacer()
                        Button("Remind me") { model.reminderFromEvent(e) }.controlSize(.small)
                    }
                }
            }
            if gm {
                Text("Mail that may need you (read-only)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if mail.isEmpty { Text("Nothing flagged in the last day.").font(.callout).foregroundStyle(.secondary) }
                ForEach(mail.prefix(6), id: \.message.id) { t in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(t.message.senderName): \(t.message.subject)").lineLimit(1)
                            Text(t.explanation).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add task…") { model.openCapturePanel(); model.prefillCapture?("Reply to \(t.message.senderName) about \(t.message.subject)") }.controlSize(.small)
                        Link("Open", destination: t.message.webURL).font(.caption)
                    }
                }
            }
            ForEach(problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
        }
        .task(id: model.connectorVersion) { await load() }
    }

    func load() async {
        problems = []
        let c = model.clock.calendar, now = model.clock.now
        if model.calendarUsable {
            do { events = try await model.fetchEvents(from: now, to: c.date(byAdding: .day, value: 1, to: c.startOfDay(for: now))!, origin: .user(.popover)) }
            catch { problems.append("Calendar: \(model.errorText(error))") }
        }
        if model.hub.gmail.state.isUsable {
            do { mail = try await model.fetchTriaged("newer_than:1d -category:promotions -category:social", origin: .user(.popover)).filter(\.needsAttention) }
            catch { problems.append("Gmail: \(model.errorText(error))") }
        }
    }
}
