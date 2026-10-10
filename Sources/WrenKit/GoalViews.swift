import SwiftUI
import WrenCore

/// Items / Goals / Review switcher shown on the main panes.
struct MainTabs: View {
    @Bindable var model: AppModel
    var body: some View {
        let selection = Binding<Int>(
            get: { switch model.route { case .goals, .goal: 1; case .review: 2; default: 0 } },
            set: { model.route = [Route.list, .goals, .review][$0] })
        Picker("", selection: selection) {
            Text("Items").tag(0)
            Text("Goals").tag(1)
            Text(model.insights.isEmpty ? "Review" : "Review (\(model.insights.count))").tag(2)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 14).padding(.bottom, 8)
    }
}

struct ProgressLine: View {
    let report: GoalProgressReport
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let f = report.fraction {
                ProgressView(value: f).tint(WrenTheme.accent)
            } else {
                ProgressView(value: 0).tint(.secondary).opacity(0.4)
            }
            Text(report.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct GoalsPane: View {
    @Bindable var model: AppModel
    @State private var draft = ""
    @State private var showClosed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "scope").foregroundStyle(.secondary)
                TextField("New goal… (e.g. Publish my article by end of month)", text: $draft)
                    .textFieldStyle(.plain)
                    .onSubmit(add)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            let open = model.goals.filter { $0.status == .active || $0.status == .paused }
            let closed = model.goals.filter { $0.status == .completed || $0.status == .archived }
            if model.goals.isEmpty {
                VStack(spacing: 6) {
                    Text("No goals yet").font(.headline)
                    Text("Goals are bigger outcomes. Link tasks to them and choose how progress is measured.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(28).frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(open) { GoalRow(model: model, goal: $0) }
                        if !closed.isEmpty {
                            Button { showClosed.toggle() } label: {
                                Label("Completed and archived (\(closed.count))", systemImage: showClosed ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }.buttonStyle(.plain).padding(.horizontal, 14).padding(.top, 12)
                            if showClosed { ForEach(closed) { GoalRow(model: model, goal: $0) } }
                        }
                    }.padding(.bottom, 8)
                }
            }
        }
    }

    /// A trailing date phrase becomes the target date ("… by end of month"), read with the same deterministic rules.
    func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let parsed = DateParser(calendar: model.clock.calendar).parse(text, now: model.clock.now)
        var title = text
        if let p = parsed, let r = title.lowercased().range(of: p.phrase) {
            title.removeSubrange(r)
            title = title.replacingOccurrences(of: #"\s+(by|before|on|until)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        }
        title = title.replacingOccurrences(of: #"^(i want to|i'd like to|my goal is to|goal:)\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        model.createGoal(title: title.prefix(1).uppercased() + title.dropFirst(), targetDate: parsed?.date, originalText: text)
        draft = ""
    }
}

struct GoalRow: View {
    var model: AppModel
    let goal: Goal
    var body: some View {
        Button { model.route = .goal(goal.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(goal.title).lineLimit(2).foregroundStyle(goal.status == .active ? .primary : .secondary)
                    Spacer()
                    if goal.status != .active { Text(goal.status.label).font(.caption).foregroundStyle(.secondary) }
                    Text(GoalProgressReport.of(goal).percentText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let t = goal.targetDate {
                    Label("Target \(DueText.describe(t, hasTime: false))", systemImage: "flag").font(.caption).foregroundStyle(.secondary)
                }
                if let f = GoalProgressReport.of(goal).fraction { ProgressView(value: f).tint(WrenTheme.accent).controlSize(.small) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

struct GoalDetailView: View {
    var model: AppModel
    let goal: Goal
    @State private var title = ""
    @State private var details = ""
    @State private var hasTarget = false
    @State private var target = Date()
    @State private var manual = 0.0
    @State private var milestone = ""
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.route = .goals } label: { Label("Goals", systemImage: "chevron.left") }.buttonStyle(.borderless)
                Spacer()
                Text(goal.status.label).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Goal", text: $title, axis: .vertical).textFieldStyle(.plain).font(.title3.weight(.medium))
                    TextField("Notes", text: $details, axis: .vertical).textFieldStyle(.plain).foregroundStyle(.secondary).lineLimit(1...4)
                    HStack {
                        Toggle("Target", isOn: $hasTarget).toggleStyle(.checkbox)
                        DatePicker("", selection: $target, displayedComponents: .date).labelsHidden().disabled(!hasTarget)
                        Spacer()
                        Button("Save") { save() }.controlSize(.small)
                    }
                    .font(.callout)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Progress").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Picker("Measured by", selection: Binding(get: { goal.method }, set: { model.setGoalMethod(goal, $0) })) {
                            ForEach(ProgressMethod.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        if goal.method == .manual {
                            HStack {
                                Slider(value: $manual, in: 0...1, step: 0.05) { editing in if !editing { model.setGoalProgress(goal, manual) } }
                                Text("\(Int((manual * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 36)
                            }
                        }
                        ProgressLine(report: GoalProgressReport.of(goal))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(goal.method == .milestones ? "Milestones" : "Linked tasks").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        let shown = goal.method == .milestones ? goal.milestones : goal.tasks
                        ForEach(shown.sorted { $0.createdAt < $1.createdAt }) { t in
                            HStack {
                                Image(systemName: t.status == .completed ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(t.status == .completed ? WrenTheme.accent : .secondary)
                                Button(t.title) { model.route = .detail(t.id) }.buttonStyle(.plain)
                                if t.isMilestone && goal.method != .milestones { Image(systemName: "flag").font(.caption2).foregroundStyle(.secondary) }
                                Spacer()
                                Button { model.unlink(t) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).help("Unlink")
                            }.font(.callout)
                        }
                        HStack {
                            TextField("Add a milestone…", text: $milestone).textFieldStyle(.roundedBorder).controlSize(.small)
                                .onSubmit { if !milestone.isEmpty { model.addMilestone(goal, title: milestone); milestone = "" } }
                            Menu("Link task") {
                                ForEach(model.pending.filter { $0.goal == nil }) { c in
                                    Button(c.title) { model.link(c, to: goal, milestone: false) }
                                }
                            }
                            .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                        }
                    }

                    DisclosureGroup("History", isExpanded: $showHistory) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(goal.sortedEvents) { e in
                                Text("\(e.at.formatted(date: .abbreviated, time: .shortened))  \(e.kind.rawValue)\(e.note.map { " · \($0)" } ?? "")")
                                    .font(.caption)
                            }
                        }
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(14)
            }
            Divider()
            HStack(spacing: 8) {
                switch goal.status {
                case .active:
                    Button("Pause") { model.setGoalStatus(goal, .paused) }
                    Button("Complete") { model.setGoalStatus(goal, .completed) }
                    Button("Archive") { model.setGoalStatus(goal, .archived) }
                case .paused:
                    Button("Resume") { model.setGoalStatus(goal, .active) }
                    Button("Complete") { model.setGoalStatus(goal, .completed) }
                    Button("Archive") { model.setGoalStatus(goal, .archived) }
                case .completed, .archived:
                    Button("Reopen") { model.setGoalStatus(goal, .active) }
                }
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .onAppear(perform: load)
    }

    func load() {
        title = goal.title; details = goal.details ?? ""
        hasTarget = goal.targetDate != nil; target = goal.targetDate ?? .now
        manual = goal.manualProgress
    }

    func save() {
        model.editGoal(goal, title: title, details: details.isEmpty ? nil : details,
                       targetDate: hasTarget ? Calendar.current.startOfDay(for: target) : nil)
    }
}

/// Things that need a decision. Nothing here changes on its own.
struct ReviewPane: View {
    var model: AppModel
    var body: some View {
        if model.insights.isEmpty {
            VStack(spacing: 6) {
                Text("Nothing to review").font(.headline)
                Text("Follow-ups that are due, things moved several times, and items that have gone quiet will appear here.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(28).frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(InsightKind.allCases, id: \.self) { kind in
                        let group = model.insights.filter { $0.kind == kind }
                        if !group.isEmpty {
                            SectionLabel(kind.sectionTitle)
                            ForEach(group) { InsightRow(model: model, insight: $0) }
                        }
                    }
                    Text("Wren never archives, deletes or reschedules anything on its own.")
                        .font(.caption).foregroundStyle(.tertiary).padding(14)
                }
            }
        }
    }
}

struct InsightRow: View {
    var model: AppModel
    let insight: Insight
    @State private var splitting = false
    @State private var steps = ""

    var item: Commitment? { insight.subject == .commitment ? insight.subjectUUID.flatMap(model.item) : nil }
    var goal: Goal? { insight.subject == .goal ? insight.subjectUUID.flatMap(model.goal) : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(insight.title) {
                if let id = insight.subjectUUID { model.route = insight.subject == .goal ? .goal(id) : .detail(id) }
            }.buttonStyle(.plain).font(.body.weight(.medium))
            Text(insight.message).font(.callout)
            Text(insight.reason).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) { actions }.controlSize(.small)
            if splitting {
                HStack {
                    TextField("Steps, separated by commas", text: $steps).textFieldStyle(.roundedBorder).controlSize(.small)
                    Button("Create") {
                        if let c = item { model.split(c, into: steps.split(separator: ",").map(String.init)); model.resolve(insight, note: "broke into steps") }
                        splitting = false
                    }.controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder var actions: some View {
        switch insight.kind {
        case .postponed:
            Button("Keep date") { model.resolve(insight, note: "kept the date") }
            Menu("New date") {
                if let c = item {
                    Button("Tomorrow") { model.reschedule(c, to: startOf(1), hasTime: false); model.resolve(insight, note: "new date") }
                    Button("Next week") { model.reschedule(c, to: startOf(7), hasTime: false); model.resolve(insight, note: "new date") }
                    Button("Choose…") { model.route = .detail(c.id) }
                }
            }.menuStyle(.borderlessButton).fixedSize()
            Button("Split…") { splitting.toggle() }
            Menu("More") {
                if let c = item {
                    Button("Turn into a goal") { model.convertToGoal(c); model.resolve(insight, note: "turned into a goal") }
                    Menu("Make a milestone of…") {
                        ForEach(model.goals.filter { $0.status == .active }) { g in
                            Button(g.title) { model.link(c, to: g, milestone: true); model.resolve(insight, note: "milestone") }
                        }
                    }
                    Button("Drop") { model.drop(c); model.resolve(insight, note: "dropped") }
                    Button("Archive") { model.archive(c); model.resolve(insight, note: "archived") }
                }
            }.menuStyle(.borderlessButton).fixedSize()
            Button("Dismiss") { model.dismiss(insight) }
        case .followUpDue:
            if let c = item {
                Button("Followed up") { model.followedUp(c, next: nil) }
                Button("Follow up again in 3 days") { model.followedUp(c, next: startOf(3)) }
            }
            Button("Dismiss") { model.dismiss(insight) }
        case .goalApproaching:
            if let g = goal { Button("Open goal") { model.route = .goal(g.id) } }
            Button("Dismiss") { model.dismiss(insight) }
        case .stale:
            Button("Keep active") { model.resolve(insight, note: "kept active") }
            if let c = item {
                if c.kind == .waiting {
                    Button("Follow up in 3 days") { model.followedUp(c, next: startOf(3)) }
                } else {
                    Menu("Reschedule") {
                        Button("Tomorrow") { model.remind(c, at: Calendar.current.time(minutesAfterMidnight: model.reminderHour * 60, on: startOf(1))) }
                        Button("Next week") { model.remind(c, at: Calendar.current.time(minutesAfterMidnight: model.reminderHour * 60, on: startOf(7))) }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                Menu("Link to goal") {
                    ForEach(model.goals.filter { $0.status == .active }) { g in Button(g.title) { model.link(c, to: g, milestone: false) } }
                }.menuStyle(.borderlessButton).fixedSize()
                Button("Archive") { model.archive(c) }
            }
            if let g = goal {
                Button("Pause goal") { model.setGoalStatus(g, .paused) }
                Button("Archive goal") { model.setGoalStatus(g, .archived) }
            }
            Button("Dismiss") { model.dismiss(insight) }
        }
    }

    func startOf(_ days: Int) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: .now))!
    }
}
