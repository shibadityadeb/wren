import AppKit
import WrenCore

/// What the capture panel should show after Return.
enum CaptureReply {
    /// Saved as a new item; close the panel.
    case saved
    case resolution(ContextResolution)
    case failed(String)
    /// A request for an assistant: the panel shows it as "Ask ChatGPT" (or offers a choice for a
    /// general question) and runs it from there.
    case ask(AIRequest)
}



/// Goals, waiting items, insights and contextual commands. Every change goes through `run`
/// (the ActionBroker). Contextual proposals are confirmed explicitly before they run.
@MainActor
extension AppModel {
    func noteRecent(_ id: UUID) {
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
        if recentIDs.count > 10 { recentIDs.removeLast() }
    }

    var conversation: ConversationContext {
        var selected: UUID?
        if case let .detail(id) = route { selected = id }
        return ConversationContext(selected: selected, recent: recentIDs)
    }

    var resolver: ContextResolver { ContextResolver(calendar: clock.calendar, dateOnlyReminderHour: reminderHour) }

    // MARK: Capture panel entry point

    /// Every input is classified first (explicit save, reminder, ask an assistant, change an item,
    /// question about stored items, general question, or something to remember), and only the
    /// matching action or card follows. Cards never come from an unrelated guess.
    func submitFromCapture(_ text: String, channel: UserChannel = .hotkey) async -> CaptureReply {
        // A spoken command may still start with "Hey Wren,"; it isn't part of the request.
        let spoken = channel == .voice ? ReminderCommand.stripAddress(text) : text
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("Nothing to save.") }
        reload()
        let source: CaptureSource = channel == .voice ? .voice : .hotkey
        if let body = IntentRouter.explicitCapture(trimmed) {
            reminderFollowUp = nil
            return capture(body, source: source) ? .saved : .failed("Couldn't save. Your text is still here.")
        }
        if let r = await reminderRequest(trimmed, channel: channel) { return r }
        let all = (try? store?.all()) ?? []
        switch IntentRouter.route(trimmed, now: clock.now, calendar: clock.calendar, resolver: resolver) {
        case .explicitCapture(let body):
            return capture(body, source: source) ? .saved : .failed("Couldn't save. Your text is still here.")
        case .askAI(let request):
            return .ask(request)
        case .reminder:
            // reminderRequest handles every reminder; reaching here means it couldn't, so keep the words.
            return capture(trimmed, source: source) ? .saved : .failed("Couldn't save. Your text is still here.")
        case .itemCommand, .storedQuery:
            if let r = await connectorAnswer(trimmed) { return .resolution(r) }
            let result = resolver.resolve(trimmed, items: all, goals: goals, context: conversation, now: clock.now)
            if case let .notFound(msg) = result {
                // The model may only help if it found something real; an empty answer would hide the reason.
                if case let .resolved(r)? = await modelInterpretation(trimmed, all: all) {
                    if case let .answer(a) = r, a.lines.isEmpty {} else { return .resolution(r) }
                }
                return .resolution(.notFound(msg))
            }
            if case .notACommand = result { return capture(trimmed, source: source) ? .saved : .failed("Couldn't save. Your text is still here.") }
            return .resolution(result)
        case .generalQuestion(let request):
            // Questions Wren can answer from connected Gmail or Calendar go there first.
            if let r = await connectorAnswer(trimmed) { return .resolution(r) }
            return .ask(request)
        case .capture:
            if let r = await connectorAnswer(trimmed) { return .resolution(r) }
            // Ask the local model only when the text looks like a command or question.
            if ContextResolver.mightBeCommandOrQuestion(trimmed) {
                switch await modelInterpretation(trimmed, all: all) {
                case let .resolved(r)?: return .resolution(r)
                case .generalQuestion?: return .ask(AIRequest(prompt: IntentRouter.questionPromptPublic(trimmed), original: text, target: nil))
                case nil: break
                }
            }
            return capture(trimmed, source: source) ? .saved : .failed("Couldn't save. Your text is still here.")
        }
    }

    // MARK: Asking ChatGPT from the panel

    func askChatGPT(_ r: AIRequest, channel: UserChannel, onDelta: @escaping @MainActor (String) -> Void) async -> AskOutcome {
        guard let asks else { return .failed("Wren's database isn't available.", retryable: false) }
        let o = await asks.askChatGPT(r, channel: channel, onDelta: onDelta)
        connectorsChanged()
        return o
    }

    /// The local model answers a general question on this Mac. nil when no local model is set up.
    func askLocalModel(_ r: AIRequest) async -> AskOutcome? {
        guard let name = ai.usableModel, let client = try? OllamaClient() else { return nil }
        let schema: JSONValue = .object(["type": .string("object"), "properties": .object(["answer": .object(["type": .string("string")])]),
                                         "required": .array([.string("answer")])])
        guard let raw = try? await client.chatJSON(model: name, system: "Answer the question helpfully and concisely. Reply with JSON {\"answer\": …}.",
                                                   user: r.prompt, schema: schema, timeout: 120),
              let d = raw.data(using: .utf8), let v = try? JSONDecoder().decode(JSONValue.self, from: d), let a = v["answer"]?.string, !a.isEmpty
        else { return .failed("The local model didn't answer.", retryable: true) }
        guard let record = newDelegation(r.prompt, destination: .localModel, depth: r.depth) else { return .failed("Couldn't save the answer.", retryable: false) }
        record.prompt = r.prompt; record.response = a; record.responseSource = "Local model \(name) on this Mac"; record.status = .responseImported
        saveDelegation(record)
        return .answered(text: a, source: "Local model \(name), on this Mac", recordID: record.id)
    }

    // MARK: Reminders from words

    /// "Remind me to …": an explicit request creates the reminder at once (audited, persisted, scheduled
    /// with macOS) and says exactly what was set. A missing or ambiguous time is asked about; the
    /// next answer completes the same request.
    func reminderRequest(_ text: String, channel: UserChannel) async -> CaptureReply? {
        let cal = clock.calendar, now = clock.now
        var candidate = text
        let isNewRequest = ReminderCommand.parse(text, now: now, calendar: cal, defaultHour: reminderHour) != nil
        if !isNewRequest, let prefix = reminderFollowUp {
            let looksLikeAnswer = DateParser(calendar: cal).parse(text, now: now) != nil
                || RecurrenceRule.find(in: text, calendar: cal) != nil
                || text.range(of: #"^\s*(a\.?m\.?|p\.?m\.?)\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil
            reminderFollowUp = nil
            guard looksLikeAnswer else { return nil }
            candidate = prefix + " " + text
        }
        // "Remind me about the dentist on Friday" may mean an item that already exists.
        let lower = candidate.lowercased()
        if lower.hasPrefix("remind me about ") || lower.hasPrefix("remind me of ") {
            let r = resolver.resolve(candidate, items: (try? store?.all()) ?? [], goals: goals, context: conversation, now: now)
            switch r {
            case .proposal, .clarify: return .resolution(r)
            default: break
            }
        }
        guard let cmd = ReminderCommand.parse(candidate, now: now, calendar: cal, defaultHour: reminderHour) else { return nil }
        switch cmd {
        case let .create(title, when, explanation):
            reminderFollowUp = nil
            return await createReminder(text: candidate, title: title, when: when, explanation: explanation, channel: channel)
        case let .clarify(title, question):
            reminderFollowUp = question.hasPrefix("Is that") ? candidate : "remind me to " + title
            return .resolution(.needsDate(question))
        case let .past(title, message):
            reminderFollowUp = "remind me to " + title
            return .resolution(.needsDate(message))
        }
    }

    func createReminder(text: String, title: String, when: ReminderWhen, explanation: String?, channel: UserChannel) async -> CaptureReply {
        if notificationStatus == .notDetermined {
            // First reminder: this is when macOS asks for permission, with Wren's reason in the prompt.
            _ = await notifications.requestPermission()
            notificationStatus = notifications.status
        }
        let id = UUID()
        let source: CaptureSource = channel == .voice ? .voice : .hotkey
        let req = ActionRequest(action: BuiltInAction.createReminder, target: TargetRef(kind: "commitment", id: id.uuidString, label: title),
                                parameters: BuiltInAction.createReminderParameters(text: text, title: title, when: when, source: source),
                                origin: .user(channel), createdAt: clock.now)
        let result = await run(req)
        guard let result, result.status == .succeeded || result.status == .unverified, let c = item(id) else {
            return .failed(result?.message ?? "The reminder wasn't saved.")
        }
        noteRecent(id)
        let report = await reconcileReminders()
        var lines: [AnswerLine] = []
        switch when {
        case let .once(d): lines.append(AnswerLine(DueText.describe(d, hasTime: true, now: clock.now, calendar: clock.calendar).capitalizedFirstLetter, recordID: id))
        case let .repeating(rule):
            lines.append(AnswerLine(rule.label(calendar: clock.calendar) + (c.nextReminderAt.map { " · first \(DueText.describe($0, hasTime: true, now: clock.now, calendar: clock.calendar))" } ?? ""), recordID: id))
        }
        if let explanation { lines.append(AnswerLine(explanation, recordID: nil)) }
        let status: String
        if !c.scheduledNotificationIDs.isEmpty {
            status = "Scheduled with macOS: it will appear even if Wren is closed."
        } else if !report.authorized {
            status = "Saved, but notifications are off for Wren, so it will only show inside Wren. Turn them on in System Settings › Notifications."
        } else if report.paused {
            status = "Saved. Notifications are paused; it will be included when they resume."
        } else {
            status = "Saved, but macOS didn't accept the notification. Wren will try again and show it in the app."
        }
        lines.append(AnswerLine(status, recordID: nil))
        return .resolution(.answer(Answer(title: "Reminder set: \(title)", lines: lines, basis: "From your words: “\(text)”")))
    }

    enum ModelReading { case resolved(ContextResolution), generalQuestion }

    /// Model-assisted understanding. Any failure falls back to the non-AI path; nothing is lost.
    private func modelInterpretation(_ text: String, all: [Commitment]) async -> ModelReading? {
        guard settings.useModel, let name = ai.usableModel, let client = try? OllamaClient() else { return nil }
        let interpreter = ModelCommandInterpreter(client: client, model: name, resolver: resolver)
        let started = Date()
        switch await interpreter.interpret(text, items: all, goals: goals, context: conversation, now: clock.now) {
        case let .resolution(r): noteModelSuccess(since: started); return .resolved(r)
        case .generalQuestion: noteModelSuccess(since: started); return .generalQuestion
        case .newItem: noteModelSuccess(since: started); return nil
        case let .unavailable(reason): noteModelFailure(reason); return nil
        case .invalid: return nil
        }
    }

    func choose(_ candidate: Candidate, for pending: PendingCommand) -> ContextResolution {
        guard let c = item(candidate.id) else { return .notFound("That item no longer exists.") }
        return resolver.proposal(for: pending, item: c, now: clock.now)
    }

    /// The user confirmed the exact preview shown. The confirmation binds to this request only.
    func confirmProposal(_ p: ContextProposal) async -> ActionResult? {
        guard let broker else { return nil }
        noteRecent(UUID(uuidString: p.request.target.id) ?? UUID())
        return await run(p.request, confirmation: broker.confirm(p.request))
    }

    func cancelProposal(_ p: ContextProposal) { broker?.cancel(p.request); reload() }

    // MARK: Goals

    private func goalRequest(_ a: ActionID, _ g: Goal, _ p: [String: JSONValue] = [:]) -> ActionRequest {
        ActionRequest(action: a, target: g.targetRef, parameters: p, origin: .user(.popover), createdAt: clock.now)
    }

    func createGoal(title: String, targetDate: Date?, originalText: String? = nil) {
        var p: [String: JSONValue] = ["title": .string(title)]
        if let t = targetDate { p["targetDate"] = time(t) }
        if let o = originalText { p["originalText"] = .string(o) }
        Task { await run(ActionRequest(action: BuiltInAction.createGoal, target: TargetRef(kind: "goal", id: "new", label: title),
                                       parameters: p, origin: .user(.popover), createdAt: clock.now)) }
    }
    func editGoal(_ g: Goal, title: String, details: String?, targetDate: Date?) {
        var p: [String: JSONValue] = ["title": .string(title), "details": details.map(JSONValue.string) ?? .null]
        if let t = targetDate { p["targetDate"] = time(t) }
        Task { await run(goalRequest(BuiltInAction.editGoal, g, p)) }
    }
    func setGoalStatus(_ g: Goal, _ s: GoalStatus) { Task { await run(goalRequest(BuiltInAction.setGoalStatus, g, ["status": .string(s.rawValue)])) } }
    func setGoalMethod(_ g: Goal, _ m: ProgressMethod) { Task { await run(goalRequest(BuiltInAction.setGoalMethod, g, ["method": .string(m.rawValue)])) } }
    func setGoalProgress(_ g: Goal, _ v: Double) { Task { await run(goalRequest(BuiltInAction.setGoalProgress, g, ["value": .number(v)])) } }
    func addMilestone(_ g: Goal, title: String) { Task { await run(goalRequest(BuiltInAction.addMilestone, g, ["title": .string(title)])) } }
    func link(_ c: Commitment, to g: Goal, milestone: Bool) {
        Task { await run(request(BuiltInAction.linkToGoal, c, .popover, ["goalID": .string(g.id.uuidString), "milestone": .bool(milestone)])) }
    }
    func unlink(_ c: Commitment) { Task { await run(request(BuiltInAction.unlinkFromGoal, c, .popover)) } }
    func convertToGoal(_ c: Commitment) {
        Task {
            let r = await run(request(BuiltInAction.convertToGoal, c, .popover))
            if r?.status == .succeeded, let g = item(c.id)?.goal { route = .goal(g.id) }
        }
    }
    func goal(_ id: UUID) -> Goal? { try? store?.goal(id: id) }

    // MARK: Items

    func archive(_ c: Commitment, via ch: UserChannel = .popover) { Task { await run(request(BuiltInAction.archive, c, ch)) } }
    func reschedule(_ c: Commitment, to d: Date, hasTime: Bool) {
        Task { await run(request(BuiltInAction.reschedule, c, .popover, ["deadline": time(d), "hasTime": .bool(hasTime)])) }
    }
    func split(_ c: Commitment, into titles: [String]) {
        Task { await run(request(BuiltInAction.split, c, .popover, ["titles": .array(titles.map(JSONValue.string))])) }
    }

    // MARK: Waiting

    func updateWaiting(_ c: Commitment, on: String, expected: String, followUp: Date?) {
        var p: [String: JSONValue] = ["waitingOn": .string(on), "expected": .string(expected)]
        if let f = followUp { p["followUpAt"] = time(f) }
        Task { await run(request(BuiltInAction.updateWaiting, c, .popover, p)) }
    }
    func followedUp(_ c: Commitment, next: Date?, note: String? = nil) {
        var p: [String: JSONValue] = [:]
        if let n = next { p["next"] = time(n) }
        if let note { p["note"] = .string(note) }
        Task { await run(request(BuiltInAction.acknowledgeFollowUp, c, .popover, p)) }
    }

    // MARK: Insights

    func dismiss(_ i: Insight) {
        Task { await run(ActionRequest(action: BuiltInAction.dismissInsight, target: i.targetRef, parameters: i.parameters, origin: .user(.popover), createdAt: clock.now)) }
    }
    func resolve(_ i: Insight, note: String) {
        var p = i.parameters; p["note"] = .string(note)
        Task { await run(ActionRequest(action: BuiltInAction.resolveInsight, target: i.targetRef, parameters: p, origin: .user(.popover), createdAt: clock.now)) }
    }

    func updateInsightSettings(_ f: (inout InsightSettings) -> Void) {
        var s = insightSettings; f(&s)
        insightSettings = s.normalized()
        settings.insights = insightSettings
        reload()
    }
}

extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
