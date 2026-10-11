import SwiftUI
import WrenCore

/// How often a reminder repeats, as offered in forms.
enum RepeatChoice: String, CaseIterable, Identifiable {
    case never, daily, weekdays, weekly
    var id: String { rawValue }
    func label(for date: Date) -> String {
        switch self {
        case .never: "Never"
        case .daily: "Every day"
        case .weekdays: "Every weekday (Mon–Fri)"
        case .weekly: "Every \(date.formatted(.dateTime.weekday(.wide)))"
        }
    }
    /// The rule at `date`'s local time of day.
    func rule(at date: Date, calendar: Calendar = .current) -> RecurrenceRule? {
        let h = calendar.component(.hour, from: date), m = calendar.component(.minute, from: date)
        switch self {
        case .never: return nil
        case .daily: return RecurrenceRule(weekdays: [], hour: h, minute: m)
        case .weekdays: return RecurrenceRule(weekdays: RecurrenceRule.weekdaySet, hour: h, minute: m)
        case .weekly: return RecurrenceRule(weekdays: [calendar.component(.weekday, from: date)], hour: h, minute: m)
        }
    }
    static func from(_ r: RecurrenceRule?) -> RepeatChoice {
        guard let r else { return .never }
        if r.isDaily { return .daily }
        if r.weekdays == RecurrenceRule.weekdaySet { return .weekdays }
        return r.weekdays.count == 1 ? .weekly : .daily
    }
}

/// "New reminder" from the main window. Uses the same audited path as typed and spoken requests.
struct NewReminderSheet: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var when = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
    @State private var repeatChoice = RepeatChoice.never
    @State private var result: String?
    @State private var failed = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New reminder").font(.title3.weight(.semibold))
            TextField("What should Wren remind you about?", text: $title).textFieldStyle(.roundedBorder)
            DatePicker("When", selection: $when, in: Date()..., displayedComponents: [.date, .hourAndMinute])
            Picker("Repeat", selection: $repeatChoice) {
                ForEach(RepeatChoice.allCases) { Text($0.label(for: when)).tag($0) }
            }
            if model.notificationStatus == .denied {
                Text("Notifications are off for Wren, so this would only show inside Wren. Turn them on in System Settings › Notifications.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let result { Text(result).font(.callout).foregroundStyle(failed ? .orange : .secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set reminder") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || busy || (repeatChoice == .never && when <= .now))
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    func save() {
        busy = true
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let w: ReminderWhen = repeatChoice.rule(at: when).map { .repeating($0) } ?? .once(when)
        Task {
            let reply = await model.createReminder(text: t, title: t, when: w, explanation: nil, channel: .popover)
            busy = false
            switch reply {
            case let .resolution(.answer(a)):
                model.banner = a.title + ". " + (a.lines.last?.text ?? "")
                dismiss()
            case let .failed(m): result = m; failed = true
            default: result = "The reminder wasn't saved."; failed = true
            }
        }
    }
}
