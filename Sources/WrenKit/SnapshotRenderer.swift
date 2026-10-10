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

        let model = AppModel(store: store)
        model.modelStatus = .ready(["qwen2.5:3b", "llama3.2:3b"])
        model.selectedModel = "qwen2.5:3b"
        model.notificationStatus = .authorized

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let tag = appearance == .aqua ? "light" : "dark"
            model.route = .list
            try render(PopoverView(model: model), size: CGSize(width: 380, height: 520), appearance: appearance, to: dir.appendingPathComponent("popover-list-\(tag).png"))
            model.route = .detail(form.id)
            try render(PopoverView(model: model), size: CGSize(width: 380, height: 520), appearance: appearance, to: dir.appendingPathComponent("popover-detail-\(tag).png"))
            model.route = .settings
            try render(PopoverView(model: model), size: CGSize(width: 380, height: 560), appearance: appearance, to: dir.appendingPathComponent("popover-settings-\(tag).png"))
            let state = CaptureState()
            state.text = "Submit the scholarship form by Friday"
            try render(CaptureView(state: state, submit: { _ in }, cancel: {}).padding(20)
                .background(appearance == .aqua ? Color(white: 0.85) : Color(white: 0.15)),
                       size: CGSize(width: 600, height: 160), appearance: appearance, to: dir.appendingPathComponent("capture-\(tag).png"))
        }
        // Empty state.
        let empty = AppModel(store: try WrenStore(url: nil))
        empty.modelStatus = .noChatModel
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
