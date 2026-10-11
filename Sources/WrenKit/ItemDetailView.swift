import SwiftUI
import WrenCore

struct ItemDetailView: View {
    var model: AppModel
    let item: Commitment

    @State private var title = ""
    @State private var details = ""
    @State private var kind = CaptureKind.unsorted
    @State private var priority = Priority.normal
    @State private var hasDeadline = false
    @State private var deadline = Date()
    @State private var deadlineHasTime = false
    @State private var hasReminder = false
    @State private var reminder = Date()
    @State private var repeatChoice = RepeatChoice.never
    @State private var showHistory = false
    @State private var waitingOn = ""
    @State private var expected = ""
    @State private var hasFollowUp = false
    @State private var followUp = Date()
    @State private var steps = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.route = .list } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Text(item.status == .pending ? item.kind.label : item.status.rawValue.capitalized)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Title", text: $title, axis: .vertical)
                        .textFieldStyle(.plain).font(.title3.weight(.medium))
                    TextField("Notes", text: $details, axis: .vertical)
                        .textFieldStyle(.plain).foregroundStyle(.secondary).lineLimit(1...5)

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Type").foregroundStyle(.secondary)
                            Picker("", selection: $kind) {
                                ForEach(CaptureKind.allCases, id: \.self) { Text($0.label).tag($0) }
                            }.labelsHidden().fixedSize()
                        }
                        GridRow {
                            Text("Priority").foregroundStyle(.secondary)
                            Picker("", selection: $priority) {
                                ForEach(Priority.allCases, id: \.self) { Text($0.label).tag($0) }
                            }.labelsHidden().pickerStyle(.segmented).fixedSize()
                        }
                        GridRow {
                            Toggle("Due", isOn: $hasDeadline).toggleStyle(.checkbox)
                            HStack {
                                DatePicker("", selection: $deadline, displayedComponents: deadlineHasTime ? [.date, .hourAndMinute] : [.date])
                                    .labelsHidden().disabled(!hasDeadline)
                                Toggle("Time", isOn: $deadlineHasTime).toggleStyle(.checkbox).disabled(!hasDeadline)
                            }
                        }
                        GridRow {
                            Toggle("Remind", isOn: $hasReminder).toggleStyle(.checkbox).disabled(item.status != .pending)
                            DatePicker("", selection: $reminder, displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden().disabled(!hasReminder || item.status != .pending)
                        }
                        GridRow {
                            Text("Repeat")
                            Picker("", selection: $repeatChoice) {
                                ForEach(RepeatChoice.allCases) { Text($0.label(for: reminder)).tag($0) }
                            }
                            .labelsHidden().fixedSize().disabled(!hasReminder || item.status != .pending)
                        }
                    }
                    .font(.callout)

                    if let rule = item.recurrence, item.status == .pending {
                        Label("\(rule.label())\(item.nextReminderAt.map { " · next \(DueText.describe($0, hasTime: true))" } ?? "")", systemImage: "repeat")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if hasReminder && reminder <= .now && item.status == .pending && repeatChoice == .never {
                        Text("This time has passed, so the reminder will be sent right away.").font(.caption).foregroundStyle(.orange)
                    }

                    if kind == .waiting && item.status == .pending { waitingSection }
                    if item.status == .pending { goalSection }
                    Toggle(isOn: Binding(get: { item.isPrivate }, set: { model.setPrivate(item, $0) })) {
                        Label("Private: leave out of anything sent outside this Mac unless I include it", systemImage: "lock")
                    }
                    .toggleStyle(.checkbox).font(.caption)
                    if item.postponementCount > 0 {
                        Text("Moved \(item.postponementCount) time\(item.postponementCount == 1 ? "" : "s").").font(.caption).foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("You wrote").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(item.originalText).font(.callout).textSelection(.enabled)
                        if let note = item.processingNote {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Text(interpretationLabel).font(.caption).foregroundStyle(.tertiary)
                            if item.processing != .manual && item.status == .pending {
                                Button("Read again") { model.retryInterpretation(item) }
                                    .buttonStyle(.link).font(.caption)
                                    .disabled(model.ai.usableModel == nil || model.processing.contains(item.id))
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

                    DisclosureGroup("History", isExpanded: $showHistory) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(item.sortedEvents) { e in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(e.at.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.tertiary)
                                    Text(Self.describe(e.kind) + (e.note.map { " · \($0)" } ?? ""))
                                }
                                .font(.caption)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                .padding(14)
            }

            Divider()
            HStack(spacing: 8) {
                if item.status == .pending {
                    Button("Done") { model.complete(item); model.route = .list }
                    Button("Drop") { model.drop(item); model.route = .list }
                    Button("Archive") { model.archive(item); model.route = .list }
                } else {
                    Button("Reopen") { model.reopen(item); load() }
                    Button("Delete", role: .destructive) { model.delete(item) }
                }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .onAppear(perform: load)
    }

    var waitingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Waiting").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("On whom (person or organisation)", text: $waitingOn).textFieldStyle(.roundedBorder)
            TextField("For what (reply, document, approval…)", text: $expected).textFieldStyle(.roundedBorder)
            HStack {
                Toggle("Follow up", isOn: $hasFollowUp).toggleStyle(.checkbox)
                DatePicker("", selection: $followUp, displayedComponents: .date).labelsHidden().disabled(!hasFollowUp)
                Spacer()
                Button("Save") { model.updateWaiting(item, on: waitingOn, expected: expected, followUp: hasFollowUp ? Calendar.current.startOfDay(for: followUp) : nil) }
            }
            if let since = item.waitingSince {
                Text("Waiting since \(DueText.describe(since, hasTime: false)).").font(.caption).foregroundStyle(.secondary)
            }
            let attempts = item.events.filter { $0.kind == .followedUp }.count
            HStack {
                Text(attempts == 0 ? "No follow-ups yet." : "Followed up \(attempts) time\(attempts == 1 ? "" : "s").").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("I followed up") { model.followedUp(item, next: nil) }
            }
            Text("Wren can remind you to follow up. It never sends messages for you.").font(.caption2).foregroundStyle(.tertiary)
        }
        .controlSize(.small)
        .font(.callout)
    }

    var goalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Goal").foregroundStyle(.secondary)
                Menu(item.goal?.title ?? "None") {
                    Button("None") { model.unlink(item) }.disabled(item.goal == nil)
                    ForEach(model.goals.filter { $0.status == .active || $0.status == .paused }) { g in
                        Button(g.title) { model.link(item, to: g, milestone: false) }
                        Button("\(g.title) (as milestone)") { model.link(item, to: g, milestone: true) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                if item.isMilestone { Text("milestone").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Turn into goal") { model.convertToGoal(item) }.controlSize(.small)
            }
            HStack {
                TextField("Break into steps (comma-separated)", text: $steps).textFieldStyle(.roundedBorder).controlSize(.small)
                Button("Create") {
                    let parts = steps.split(separator: ",").map(String.init)
                    if !parts.isEmpty { model.split(item, into: parts); steps = "" }
                }.controlSize(.small).disabled(steps.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .font(.callout)
    }

    var interpretationLabel: String {
        switch item.processing {
        case .processed: "Read by \(item.modelName ?? "local model")"
        case .awaiting: "Read with simple rules"
        case .failed: "The model's answer was rejected"
        case .manual: "Edited by you"
        }
    }

    func load() {
        title = item.title
        details = item.details ?? ""
        kind = item.kind
        priority = item.priority
        hasDeadline = item.deadline != nil
        deadline = item.deadline ?? Calendar.current.startOfDay(for: .now)
        deadlineHasTime = item.deadlineHasTime
        hasReminder = item.nextReminderAt != nil || item.recurrence != nil
        reminder = item.nextReminderAt ?? Date().addingTimeInterval(3600)
        repeatChoice = RepeatChoice.from(item.recurrence)
        waitingOn = item.waitingOn ?? ""
        expected = item.expectedResponse ?? ""
        hasFollowUp = item.followUpAt != nil
        followUp = item.followUpAt ?? Calendar.current.date(byAdding: .day, value: 3, to: .now)!
    }

    func save() {
        let d = hasDeadline ? (deadlineHasTime ? deadline : Calendar.current.startOfDay(for: deadline)) : nil
        let rule = hasReminder ? repeatChoice.rule(at: reminder) : nil
        model.save(item, .init(title: title, details: details, kind: kind, priority: priority,
                               deadline: d, deadlineHasTime: hasDeadline && deadlineHasTime,
                               nextReminderAt: item.status == .pending && hasReminder ? reminder : nil),
                   repeat: item.status == .pending && rule != item.recurrence ? .some(rule) : nil)
    }

    static func describe(_ k: EventKind) -> String {
        switch k {
        case .captured: "Captured"
        case .interpreted: "Interpreted"
        case .interpretationFailed: "Interpretation failed"
        case .edited: "Edited"
        case .reminderScheduled: "Reminder set"
        case .reminderSent: "Reminder sent"
        case .snoozed: "Snoozed"
        case .completed: "Done"
        case .dropped: "Dropped"
        case .reopened: "Reopened"
        case .deadlineMoved: "Deadline moved later"
        case .archived: "Archived"
        case .linkedToGoal: "Linked to goal"
        case .unlinkedFromGoal: "Unlinked from goal"
        case .convertedToGoal: "Turned into a goal"
        case .split: "Broken into smaller tasks"
        case .waitingUpdated: "Waiting details updated"
        case .followUpScheduled: "Follow-up set"
        case .followedUp: "Followed up"
        case .postponementReviewed: "Reviewed after several moves"
        case .occurrenceDone: "Done for this time (keeps repeating)"
        }
    }
}
