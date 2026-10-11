import AppKit
import SwiftUI
import WrenCore

/// Renders the real views with sample data to PNGs, for design review without a screen.
/// Used by `wren-tools snapshot`. Uses an in-memory store; touches no user data.
public enum SnapshotRenderer {
    @MainActor
    public static func renderAll(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try WrenStore(url: nil)
        let cal = Calendar.current
        let now = Date()
        func add(_ text: String, kind: CaptureKind, title: String, deadline: Date? = nil, hasTime: Bool = false,
                 reminder: Date? = nil, priority: Priority = .normal) throws -> Commitment {
            let c = try store.capture(text, source: .hotkey, now: now.addingTimeInterval(-7200))
            try store.applyInterpretation(Interpretation(kind: kind, title: title, priority: priority, deadline: deadline,
                                                         deadlineHasTime: hasTime, note: nil),
                                          to: c, model: "qwen2.5:3b", reminderPolicy: ReminderPolicy(), now: now.addingTimeInterval(-7100))
            if let reminder { try store.scheduleReminder(c, at: reminder) }
            return c
        }
        let friday = cal.nextDate(after: now, matching: DateComponents(weekday: 6), matchingPolicy: .nextTime)!
        let form = try add("Submit the scholarship form by Friday", kind: .commitment, title: "Submit the scholarship form",
                           deadline: cal.startOfDay(for: friday), priority: .high)
        _ = try add("Call my friend at 8 tonight", kind: .commitment, title: "Call my friend",
                    deadline: cal.date(bySettingHour: 20, minute: 0, second: 0, of: now), hasTime: true)
        _ = try add("I should read that research paper this weekend", kind: .commitment, title: "Read the research paper",
                    deadline: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)))
        _ = try add("I have an idea for a new AI startup", kind: .idea, title: "AI startup idea")
        _ = try add("I am waiting for the recruiter to reply", kind: .waiting, title: "Recruiter reply")
        let done = try add("Renew passport photos", kind: .commitment, title: "Renew passport photos")
        try store.complete(done)
        _ = try add("Pay the electricity bill", kind: .commitment, title: "Pay the electricity bill",
                    deadline: cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)))
        _ = try add("Book dentist appointment today", kind: .commitment, title: "Book dentist appointment",
                    deadline: cal.startOfDay(for: now))

        // Milestone 3 sample data.
        let goal = try store.createGoal(title: "Publish multi-agent reasoning article", originalText: "I want to publish a technical article about multi-agent reasoning before the end of the month.",
                                        targetDate: cal.date(byAdding: .day, value: 5, to: cal.startOfDay(for: now)), method: .milestones, now: now.addingTimeInterval(-86400 * 10))
        for (t, done) in [("Outline the argument", true), ("First draft", false), ("Get feedback from Sam", false)] {
            let m = try store.capture(t, source: .manual, now: now.addingTimeInterval(-86400 * 9))
            m.kind = .commitment; m.processing = .manual
            try store.link(m, to: goal, asMilestone: true, now: now.addingTimeInterval(-86400 * 9))
            if done { try store.complete(m, now: now.addingTimeInterval(-86400 * 3)) }
        }
        let paused = try store.createGoal(title: "Run a half marathon", targetDate: nil, now: now.addingTimeInterval(-86400 * 40))
        try store.setManualProgress(paused, 0.3, now: now.addingTimeInterval(-86400 * 30))
        let w = try add("Waiting for the API review from the platform team", kind: .waiting, title: "API review from the platform team")
        try store.updateWaiting(w, waitingOn: "Platform team", expected: "Approval of the v2 API", followUpAt: cal.startOfDay(for: now), now: now.addingTimeInterval(-86400 * 4))
        let moved = try add("Write the quarterly report", kind: .commitment, title: "Write the quarterly report",
                            deadline: cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now)))
        for k in 1...3 { try store.snooze(moved, until: now.addingTimeInterval(Double(k) * 3600), now: now.addingTimeInterval(Double(-k) * 3600)) }
        let oldIdea = Commitment(originalText: "Idea: a CLI for notes", source: .hotkey, now: now.addingTimeInterval(-86400 * 45))
        oldIdea.kind = .idea; oldIdea.title = "A CLI for notes"; oldIdea.processing = .manual
        store.context.insert(oldIdea)
        try store.context.save()

        let model = AppModel(store: store)
        model.ai = .ready(model: "qwen2.5:3b", models: ["qwen2.5:3b", "llama3.2:3b"], verifiedAt: now, latencyMs: 840)
        model.selectedModel = "qwen2.5:3b"
        model.notificationStatus = .authorized

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let tag = appearance == .aqua ? "light" : "dark"
            model.route = .list
            try render(PopoverView(model: model), size: CGSize(width: 380, height: 520), appearance: appearance, to: dir.appendingPathComponent("popover-list-\(tag).png"))
            model.route = .detail(form.id)
            try render(PopoverView(model: model), size: CGSize(width: 380, height: 520), appearance: appearance, to: dir.appendingPathComponent("popover-detail-\(tag).png"))
            model.route = .briefing
            try render(PopoverView(model: model), size: CGSize(width: 380, height: 520), appearance: appearance, to: dir.appendingPathComponent("popover-briefing-\(tag).png"))
            model.route = .checkIn
            try render(PopoverView(model: model), size: CGSize(width: 380, height: 520), appearance: appearance, to: dir.appendingPathComponent("popover-checkin-\(tag).png"))
            model.reload()
            model.route = .goals
            try render(PopoverView(model: model), size: CGSize(width: 380, height: 520), appearance: appearance, to: dir.appendingPathComponent("popover-goals-\(tag).png"))
            model.route = .goal(goal.id)
            try render(PopoverView(model: model), size: CGSize(width: 380, height: 560), appearance: appearance, to: dir.appendingPathComponent("popover-goal-\(tag).png"))
            model.route = .review
            try render(PopoverView(model: model), size: CGSize(width: 380, height: 700), appearance: appearance, to: dir.appendingPathComponent("popover-review-\(tag).png"))
            model.route = .detail(w.id)
            try render(PopoverView(model: model), size: CGSize(width: 380, height: 700), appearance: appearance, to: dir.appendingPathComponent("popover-waiting-\(tag).png"))
            let cs = CaptureState()
            cs.text = "Push the report to next week"
            if case let .proposal(p) = model.resolver.resolve(cs.text, items: try store.all(), goals: [], context: .init(), now: now) { cs.reply = .proposal(p) }
            try render(CaptureView(state: cs, submit: { _ in }, cancel: {}).padding(20)
                .background(appearance == .aqua ? Color(white: 0.85) : Color(white: 0.15)),
                       size: CGSize(width: 600, height: 230), appearance: appearance, to: dir.appendingPathComponent("capture-proposal-\(tag).png"))
            let cs2 = CaptureState()
            cs2.text = "Mark the API task as done"
            cs2.reply = model.resolver.resolve(cs2.text, items: try store.all(), goals: [], context: .init(), now: now)
            try render(CaptureView(state: cs2, submit: { _ in }, cancel: {}).padding(20)
                .background(appearance == .aqua ? Color(white: 0.85) : Color(white: 0.15)),
                       size: CGSize(width: 600, height: 260), appearance: appearance, to: dir.appendingPathComponent("capture-clarify-\(tag).png"))
            model.route = .overview
            try render(MainWindowView(model: model), size: CGSize(width: 980, height: 720), appearance: appearance, to: dir.appendingPathComponent("window-overview-\(tag).png"))
            model.route = .settings
            try render(MainWindowView(model: model), size: CGSize(width: 980, height: 720), appearance: appearance, to: dir.appendingPathComponent("window-settings-\(tag).png"))
            model.pause = NotificationPause(since: now, until: now.addingTimeInterval(3600))
            try render(PopoverView(model: model), size: CGSize(width: 380, height: 2300), appearance: appearance, to: dir.appendingPathComponent("popover-settings-\(tag).png"))
            let state = CaptureState()
            state.text = "Submit the scholarship form by Friday"
            try render(CaptureView(state: state, submit: { _ in }, cancel: {}).padding(20)
                .background(appearance == .aqua ? Color(white: 0.85) : Color(white: 0.15)),
                       size: CGSize(width: 600, height: 160), appearance: appearance, to: dir.appendingPathComponent("capture-\(tag).png"))
        }
        // Empty state.
        let empty = AppModel(store: try WrenStore(url: nil))
        empty.ai = .noChatModel
        try render(PopoverView(model: empty), size: CGSize(width: 380, height: 400), appearance: .aqua, to: dir.appendingPathComponent("popover-empty-light.png"))
    }

    @MainActor
    static func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}
