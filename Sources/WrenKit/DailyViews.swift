import SwiftUI
import WrenCore

/// Shared top bar for secondary panes.
struct PaneHeader: View {
    var model: AppModel
    let title: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Button { model.route = .list } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(.borderless)
            Spacer()
            Text(title).font(.headline)
            Spacer()
            Text(trailing ?? "").font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// One line for a summarized item, with the actions that matter in context.
struct SummaryRow: View {
    var model: AppModel
    let item: SummaryItem
    var showsCheckInActions = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Button { model.route = .detail(item.id) } label: { Text(item.title).lineLimit(2).multilineTextAlignment(.leading) }
                    .buttonStyle(.plain)
                if let d = item.deadline {
                    Text(DueText.describe(d, hasTime: item.deadlineHasTime)).font(.caption).foregroundStyle(.secondary)
                } else if let r = item.nextReminderAt {
                    Label(DueText.describe(r, hasTime: true), systemImage: "bell").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if let c = model.item(item.id), c.status == .pending {
                if showsCheckInActions {
                    Button("Done") { model.complete(c, via: .checkIn) }
                    Menu("Later") {
                        Button("Snooze 1 hour") { model.snooze(c, until: .now.addingTimeInterval(3600), via: .checkIn) }
                        Button("Leave for tomorrow") { model.leaveForTomorrow(c) }
                        Button("Reschedule…") { model.route = .detail(c.id) }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                } else {
                    Button { model.complete(c, via: .briefing) } label: { Image(systemName: "checkmark.circle") }
                        .buttonStyle(.borderless).help("Mark done")
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 5)
    }
}

struct BriefingView: View {
    var model: AppModel
    var body: some View {
        let b = model.briefing
        VStack(spacing: 0) {
            PaneHeader(model: model, title: "Today", trailing: Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
            Divider()
            if b.isEmpty {
                Text("Nothing overdue or due soon. Enjoy the space.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(32)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        section("Overdue", b.overdue)
                        section("Due today", b.dueToday)
                        section("Coming up", b.upcoming)
                        section("Marked important", b.important)
                        section("Waiting on others", b.waiting)
                        section("Reminders today", b.remindersToday)
                        if !b.decisions.isEmpty {
                            SectionLabel("Needs a decision")
                            ForEach(b.decisions) { InsightRow(model: model, insight: $0) }
                        }
                    }.padding(.bottom, 8)
                }
            }
            Divider()
            DailyFooter(text: footer)
        }
    }

    var footer: String {
        switch model.todayRun.briefing {
        case .sent: "Today's briefing was sent."
        case .missed: "Wren wasn't running at briefing time today."
        case .undelivered: "Notifications are off, so the briefing is only shown here."
        case .skippedEmpty: "Nothing to report this morning, so no notification was sent."
        case .disabled: "Morning briefing is off."
        default: model.daily.briefingEnabled ? "Next briefing at \(DailyFooter.time(model.daily.briefingMinutes))." : "Morning briefing is off."
        }
    }

    @ViewBuilder func section(_ title: String, _ items: [SummaryItem]) -> some View {
        if !items.isEmpty {
            SectionLabel(title)
            ForEach(items) { SummaryRow(model: model, item: $0) }
        }
    }
}

struct CheckInView: View {
    var model: AppModel
    var body: some View {
        let c = model.checkIn
        VStack(spacing: 0) {
            PaneHeader(model: model, title: "Check-in")
            Divider()
            if c.isEmpty {
                Text("Nothing to review today.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(32)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !c.completedToday.isEmpty {
                            SectionLabel("Done today")
                            ForEach(c.completedToday) { i in
                                Label(i.title, systemImage: "checkmark").font(.callout).foregroundStyle(.secondary)
                                    .padding(.horizontal, 14).padding(.vertical, 3)
                            }
                        }
                        section("Still open", c.open)
                        section("Due soon", c.dueSoon)
                        section("Waiting on others", c.waiting)
                        section("Put off today", c.deferredToday)
                        if !c.decisions.isEmpty {
                            SectionLabel("Needs a decision")
                            ForEach(c.decisions) { InsightRow(model: model, insight: $0) }
                        }
                    }.padding(.bottom, 8)
                }
            }
            Divider()
            HStack {
                Text("Wren never moves deadlines or marks things done for you.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss") { model.dismissCheckIn(); model.route = .list }
                Button("Finish") { model.finishCheckIn() }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    @ViewBuilder func section(_ title: String, _ items: [SummaryItem]) -> some View {
        if !items.isEmpty {
            SectionLabel(title)
            ForEach(items) { SummaryRow(model: model, item: $0, showsCheckInActions: true) }
        }
    }
}

struct DailyFooter: View {
    let text: String
    var body: some View {
        HStack { Text(text).font(.caption).foregroundStyle(.secondary); Spacer() }
            .padding(.horizontal, 14).padding(.vertical, 8)
    }
    static func time(_ minutes: Int) -> String {
        Calendar.current.time(minutesAfterMidnight: minutes, on: .now).formatted(date: .omitted, time: .shortened)
    }
}

/// What Wren did and why, newest first. Labels only; no content.
struct ActivityView: View {
    var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(model: model, title: "Activity")
            Divider()
            let records = model.audit
            if records.isEmpty {
                Text("No actions yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(32)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(records) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Image(systemName: icon(r.status)).foregroundStyle(color(r.status))
                                    Text("\(r.action) · \(r.targetLabel)").lineLimit(1)
                                    Spacer()
                                    Text(r.at.formatted(date: .omitted, time: .shortened)).foregroundStyle(.tertiary)
                                }
                                Text("By \(r.origin)\(r.authorization.map { " · allowed by \($0)" } ?? "")\(r.confirmationObtained ? " · confirmed" : "")")
                                    .foregroundStyle(.secondary)
                                if let d = r.detail { Text(d).foregroundStyle(.secondary) }
                            }
                            .font(.caption)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }
    func icon(_ s: ExecutionStatus) -> String {
        switch s {
        case .succeeded: "checkmark.circle"
        case .denied: "hand.raised"
        case .failed: "xmark.octagon"
        case .awaitingConfirmation: "questionmark.circle"
        case .unverified: "exclamationmark.circle"
        default: "circle.dotted"
        }
    }
    func color(_ s: ExecutionStatus) -> Color {
        switch s { case .succeeded: WrenTheme.accent; case .denied, .failed: .orange; default: .secondary }
    }
}
