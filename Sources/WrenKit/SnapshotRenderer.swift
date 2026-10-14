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
            for (r, name) in [(Route.connectors, "connectors"), (.connector(.gmail), "gmail"), (.connector(.chatgpt), "chatgpt"), (.delegate, "delegate")] {
                model.route = r
                try render(MainWindowView(model: model), size: CGSize(width: 980, height: 760), appearance: appearance, to: dir.appendingPathComponent("window-\(name)-\(tag).png"))
            }
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
        // GPT delegations and the inbox (sample data only).
        let gptDone = DelegationRecord(task: "Explain quantum physics and give me a few useful beginner resources.", destination: .chatgptPlan, depth: .normal, now: now.addingTimeInterval(-300))
        gptDone.original = "Ask GPT to research quantum physics and give me a few useful beginner resources."
        gptDone.prompt = gptDone.task; gptDone.status = .completed; gptDone.requestedModel = "gpt-6-luna"; gptDone.reportedModel = "gpt-6-luna"
        gptDone.response = "Quantum physics describes how matter and energy behave at very small scales, where particles act like waves and outcomes are probabilistic.\n\nBeginner resources:\n1. \"Quantum Physics for Babies\" (yes, really) for intuition\n2. MIT OpenCourseWare 8.04, lectures 1–3\n3. 3Blue1Brown's videos on wave functions"
        gptDone.completedAt = now.addingTimeInterval(-280); gptDone.notifiedAt = gptDone.completedAt; gptDone.attempts = 1; gptDone.channelRaw = UserChannel.voice.rawValue
        gptDone.kind = .research; gptDone.webSearchRequested = true; gptDone.webSearchCalls = 2; gptDone.reportedEffort = "medium"; gptDone.startedAt = gptDone.createdAt
        gptDone.sources = [CitedSource(title: "MIT OpenCourseWare 8.04 Quantum Physics I", url: "https://ocw.mit.edu/courses/8-04-quantum-physics-i-spring-2016/")]
        let running = DelegationRecord(task: "Compare these two approaches.", destination: .chatgptPlan, depth: .normal, now: now.addingTimeInterval(-20))
        running.prompt = running.task; running.status = .running; running.requestedModel = "gpt-6-luna"; running.attempts = 1
        let failed = DelegationRecord(task: "Research rust async runtimes.", destination: .chatgptPlan, depth: .normal, now: now.addingTimeInterval(-900))
        failed.prompt = failed.task; failed.status = .failed; failed.failure = .usageLimit; failed.attempts = 1
        failed.error = ChatGPTError.usageLimitReached.errorDescription; failed.completedAt = now.addingTimeInterval(-890); failed.notifiedAt = failed.completedAt
        for r in [gptDone, running, failed] { store.context.insert(r) }
        try store.context.save()
        var mb = MailboxState(); mb.account = "you@example.com"; mb.lastSyncAt = now.addingTimeInterval(-120); mb.monitoringSince = now.addingTimeInterval(-86400)
        let samples: [EmailMessage] = [
            EmailMessage(id: "m1", threadId: "t1", from: "Google <no-reply@accounts.google.com>", to: "you", subject: "Security alert", date: now.addingTimeInterval(-1800), snippet: "A new sign-in on Mac. If this was you, you don't need to do anything.", labels: ["INBOX", "UNREAD", "IMPORTANT"]),
            EmailMessage(id: "m2", threadId: "t2", from: "Priya Shah <priya@acme.com>", to: "you", subject: "Contract for review", date: now.addingTimeInterval(-3600), snippet: "Could you please sign the contract by tomorrow? Happy to walk through it.", labels: ["INBOX", "UNREAD"]),
            EmailMessage(id: "m3", threadId: "t3", from: "Jordan (BigCo Talent) <jordan@bigco.com>", to: "you", subject: "Opportunity at BigCo", date: now.addingTimeInterval(-7200), snippet: "I'm a recruiter at BigCo and your background stood out for a staff engineer role.", labels: ["INBOX", "UNREAD"]),
            EmailMessage(id: "m4", threadId: "t4", from: "Bank <alerts@bank.com>", to: "you", subject: "Your statement is ready", date: now.addingTimeInterval(-9000), snippet: "Your October statement is available.", labels: ["INBOX", "UNREAD"]),
            EmailMessage(id: "m5", threadId: "t5", from: "Shop <deals@shop.com>", to: "you", subject: "50% off everything", date: now.addingTimeInterval(-5000), snippet: "This weekend only.", labels: ["INBOX", "UNREAD", "CATEGORY_PROMOTIONS"], isBulk: true),
        ]
        for m in samples { mb.items[m.id] = MailItem(message: m, classification: MailTriage.classify(m, now: now, calendar: cal), firstSeenAt: now, baseline: false) }
        _ = MailDigest.build(&mb, key: "sample", slot: now, late: false, now: now)
        MailDigest.mark(&mb, key: "sample", .delivered)
        model.mailbox = mb
        model.previewGmail = true
        model.delegationVersion += 1
        for (r, name, h) in [(Route.delegation(gptDone.id), "gpt-result", 760.0), (.delegation(running.id), "gpt-running", 560), (.delegation(failed.id), "gpt-failed", 560),
                             (.inbox, "inbox", 1100), (.mailMessage("m2"), "mail-message", 760), (.overview, "overview-workflows", 1000)] {
            model.route = r
            try render(MainWindowView(model: model), size: CGSize(width: 980, height: h), appearance: .aqua, to: dir.appendingPathComponent("window-\(name)-light.png"))
        }
        model.route = .delegation(gptDone.id)
        try render(MainWindowView(model: model), size: CGSize(width: 980, height: 760), appearance: .darkAqua, to: dir.appendingPathComponent("window-gpt-result-dark.png"))
        let sending = CaptureState()
        sending.text = gptDone.original!
        var card = AskCard(request: AIRequest(prompt: gptDone.task, original: gptDone.original!, target: .chatgpt), destination: .chatgpt)
        card.phase = .sending(recordID: running.id); card.recordID = running.id
        card.note = "Sent to ChatGPT. You can close this; Wren will tell you when it's finished."
        sending.ask = card
        try render(CaptureView(state: sending, submit: { _ in }, cancel: {}).padding(20).background(Color(white: 0.85)),
                   size: CGSize(width: 600, height: 240), appearance: .aqua, to: dir.appendingPathComponent("capture-gpt-sending-light.png"))

        // Voice: each push-to-talk state, with sample text.
        func voiceState(_ phase: VoiceSession.Phase, _ text: String, _ name: String, height: CGFloat = 200, setup: (CaptureState) -> Void = { _ in }) throws {
            let st = CaptureState()
            st.voicePhase = phase; st.recording = phase.isCapturingPhase; st.voiceLevel = 0.55
            st.text = text; st.lastVoiceText = text
            setup(st)
            try render(CaptureView(state: st, submit: { _ in }, cancel: {}).padding(20).background(Color(white: 0.85)),
                       size: CGSize(width: 600, height: height), appearance: .aqua, to: dir.appendingPathComponent("capture-voice-\(name)-light.png"))
        }
        let said = "Remind me to call Sam tomorrow at 10 AM."
        try voiceState(.listening(.hold), "remind me to call Sam tomorrow at", "listening")
        try render(CaptureView(state: { let st = CaptureState(); st.voicePhase = .listening(.hold); st.recording = true; st.voiceLevel = 0.4; st.text = "ask GPT to research"; st.lastVoiceText = st.text; return st }(),
                               submit: { _ in }, cancel: {}).padding(20).background(Color(white: 0.15)),
                   size: CGSize(width: 600, height: 200), appearance: .darkAqua, to: dir.appendingPathComponent("capture-voice-listening-dark.png"))
        try voiceState(.transcribing, said, "transcribing")
        try voiceState(.processing(said), said, "processing")
        try voiceState(.completed("Reminder created: Call Sam"), said, "completed", height: 280) {
            $0.reply = .answer(Answer(title: "Reminder created: Call Sam", lines: [AnswerLine("Tomorrow at 10:00 AM", recordID: nil), AnswerLine("Scheduled with macOS: it will appear even if Wren is closed.", recordID: nil)], basis: "From your words: “\(said)”"))
        }
        try voiceState(.needsClarification("What should I remind you about?"), "Remind me every weekday at 3 PM.", "question", height: 230) {
            $0.reply = .needsDate("What should I remind you about?")
        }
        try voiceState(.transcriptReady("remind me to coal some tomorrow"), "remind me to coal some tomorrow", "review", height: 210) {
            $0.reviewingVoice = true; $0.voiceStatus = "I'm not sure I heard that right. Check it, then press Return."
        }
        try voiceState(.failed(.microphoneDenied), "", "denied", height: 210)

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
