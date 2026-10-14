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

    /// Every input is routed once, by `ExecutionRouter`, to one operation (create a task or reminder,
    /// ask ChatGPT, search Gmail, change an item…), and only that operation's subsystem runs it. Typed
    /// text and voice transcripts take exactly this path. Each run records a structured result.
    func submitFromCapture(_ text: String, channel: UserChannel = .hotkey) async -> CaptureReply {
        // A spoken command may still start with "Hey Wren,"; it isn't part of the request.
        let spoken = channel == .voice ? ReminderCommand.stripAddress(text) : text
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("Nothing to save.") }
        // The same words from the same place twice in a row (a repeated Return or voice event) run once.
        let key = SubmissionGuard.key(trimmed, channel: channel.rawValue)
        guard submissions.begin(key, now: clock.now) else {
            log.notice("duplicate submission ignored (\(channel.rawValue, privacy: .public))")
            return .failed("That was just submitted, so Wren didn't do it twice.")
        }
        defer { submissions.end(key, now: clock.now) }
        let (operation, reply) = await execute(trimmed, original: text, channel: channel)
        let result = Self.result(of: reply, operation: operation, at: clock.now)
        lastExecution = result
        log.notice("execute \(result.operation, privacy: .public) succeeded=\(result.succeeded, privacy: .public) needsUser=\(result.needsUser, privacy: .public) via \(channel.rawValue, privacy: .public)")
        return reply
    }

    private func execute(_ trimmed: String, original text: String, channel: UserChannel) async -> (String, CaptureReply) {
        reload()
        let source: CaptureSource = channel == .voice ? .voice : .hotkey
        func save(_ body: String) -> CaptureReply { capture(body, source: source) ? .saved : .failed("Couldn't save. Your text is still here.") }
        if let body = IntentRouter.explicitCapture(trimmed) {
            reminderFollowUp = nil
            return ("SaveNote", save(body))
        }
        // Reminders first: this also completes an answer to "When should I remind you…?".
        if let r = await reminderRequest(trimmed, channel: channel) { return ("CreateReminder", r) }
        let all = (try? store?.all()) ?? []
        let operation = ExecutionRouter.operation(for: trimmed, now: clock.now, calendar: clock.calendar, resolver: resolver)
        switch operation {
        case let .saveNote(body):
            return (operation.name, save(body))
        case let .delegateToChatGPT(request):
            return (operation.name, .ask(request))
        case let .followUpDelegation(f):
            return (operation.name, followUp(f, text: text))
        case .createReminder:
            // reminderRequest handles every reminder; reaching here means it couldn't, so keep the words.
            return (operation.name, save(trimmed))
        case let .clarifyIntent(question):
            return (operation.name, .resolution(.needsDate(question)))
        case .openDelegationResult:
            guard let r = recentDelegations.first(where: { $0.status.isFinal }) ?? recentDelegations.first else {
                return (operation.name, .resolution(.notFound("There are no GPT requests yet.")))
            }
            openDelegation(r.id)
            return (operation.name, .resolution(.answer(Answer(title: "Opened the GPT result", lines: [AnswerLine(r.task, recordID: nil)], basis: "\(r.displayStatus) · \(r.createdAt.formatted(date: .abbreviated, time: .shortened))"))))
        case let .openEmail(sender):
            return (operation.name, openEmail(from: sender))
        case let .markEmailRead(sender):
            // Never marks anything read from words alone: it opens the message, where Mark as read
            // asks for its own confirmation and needs Gmail's separate permission.
            let r = openEmail(from: sender)
            if case .resolution(.answer) = r {
                return (operation.name, .resolution(.notFound(canMarkRead ? "Opened the email. Choose Mark as read there to change it in Gmail." : "Opened the email. Mark as read needs Gmail's separate permission; allow it from the message.")))
            }
            return (operation.name, r)
        case .changeItem, .queryStoredItems:
            if let r = await connectorAnswer(trimmed) { return (operation.name, .resolution(r)) }
            let result = resolver.resolve(trimmed, items: all, goals: goals, context: conversation, now: clock.now)
            if case let .notFound(msg) = result {
                // The model may only help if it found something real; an empty answer would hide the reason.
                if case let .resolved(r)? = await modelInterpretation(trimmed, all: all) {
                    if case let .answer(a) = r, a.lines.isEmpty {} else { return (operation.name, .resolution(r)) }
                }
                return (operation.name, .resolution(.notFound(msg)))
            }
            if case .notACommand = result { return ("Capture", save(trimmed)) }
            return (operation.name, .resolution(result))
        case .searchGmail, .queryCalendar:
            if let r = await connectorAnswer(trimmed) { return (operation.name, .resolution(r)) }
            return (operation.name, .resolution(.notFound(operation == .searchGmail ? "Gmail isn't connected. Open Connectors › Gmail to set it up." : "No calendar is connected. Open Connectors › Calendar.")))
        case let .generalQuestion(request):
            return (operation.name, .ask(request))
        case .createTask, .capture:
            if let r = await connectorAnswer(trimmed) { return (operation.name, .resolution(r)) }
            // Ask the local model only when the text looks like a command or question.
            if ContextResolver.mightBeCommandOrQuestion(trimmed) {
                switch await modelInterpretation(trimmed, all: all) {
                case let .resolved(r)?: return ("ChangeItem", .resolution(r))
                case .generalQuestion?: return ("GeneralQuestion", .ask(AIRequest(prompt: IntentRouter.questionPromptPublic(trimmed), original: text, target: nil)))
                case nil: break
                }
            }
            return (operation.name, save(trimmed))
        }
    }

    /// "Continue that research", "open that in GPT": acts on the earlier request, in its own tool. A
    /// ChatGPT website request continues on the website (in its linked conversation when there is one);
    /// a request run in Wren continues in Wren; naming ChatGPT never lands on the local model.
    func followUp(_ f: DelegationFollowUp, text: String) -> CaptureReply {
        func answer(_ title: String, _ line: String) -> CaptureReply {
            .resolution(.answer(Answer(title: title, lines: [AnswerLine(line, recordID: nil)], basis: "About your earlier request")))
        }
        guard let parent = followUpTarget else {
            return .resolution(.needsDate(f.action == .open
                ? "There's no earlier GPT request to open. Say what to ask, for example “ask GPT to research …”."
                : "Which request should I continue? Open it in Delegate first, or say the whole request, for example “ask GPT to research …”."))
        }
        let title = "“\(parent.task.prefix(60))\(parent.task.count > 60 ? "…" : "")”"
        switch f.action {
        case .open:
            if let url = parent.conversationURL {
                NSWorkspace.shared.open(url)
                return answer("Opened the ChatGPT conversation", "\(title), at its linked conversation.")
            }
            switch parent.destination {
            case .chatgptHandoff:
                NSWorkspace.shared.open(ChatGPTWeb.home)
                return answer("Opened ChatGPT", "\(title) has no conversation link in Wren, so Wren can't open that exact chat. Find it in ChatGPT's history, then paste its link on the request in Wren.")
            case .chatgptPlan where f.namesChatGPT:
                NSWorkspace.shared.open(ChatGPTWeb.home)
                return answer("Opened ChatGPT", "\(title) ran in Wren with connected ChatGPT, so there's no ChatGPT conversation to open; its result is in Wren. To take it to the website, say “continue that research in ChatGPT”.")
            case .localModel where f.namesChatGPT:
                // Named GPT: take the earlier request to the ChatGPT website (a new conversation there).
                return .ask(AIRequest(prompt: parent.prompt ?? parent.task, original: text, depth: parent.depth, kind: parent.kind,
                                      target: .chatgpt, followUpOf: parent.id, mode: .web))
            default:
                openDelegation(parent.id)
                return answer("Opened the result in Wren", "\(title) ran in Wren (\(parent.modeLabel)), so it isn't a ChatGPT conversation and has no ChatGPT link.")
            }
        case let .continue(instruction):
            let mode: ChatGPTMode?
            switch parent.destination {
            case .chatgptHandoff: mode = .web
            case .chatgptPlan: mode = f.namesChatGPT ? settings.chatgptMode : .inWren
            default: mode = f.namesChatGPT ? settings.chatgptMode : nil
            }
            // In a linked conversation, ChatGPT already has the context: only the new instruction goes.
            let linked = mode == .web && parent.conversationURL != nil
            let prompt = linked ? instruction
                : ChatGPTWeb.followUpPrompt(earlierRequest: parent.prompt ?? parent.task, earlierAnswer: parent.response, instruction: instruction)
            return .ask(AIRequest(prompt: prompt, original: text, depth: parent.depth, kind: parent.kind,
                                  target: mode == nil ? nil : .chatgpt, followUpOf: parent.id, mode: mode))
        }
    }

    /// The structured result of one executed command (no user text).
    static func result(of reply: CaptureReply, operation: String, at: Date) -> ExecutionResult {
        switch reply {
        case .saved: return ExecutionResult(operation: operation, succeeded: true, at: at)
        case let .failed(m): return ExecutionResult(operation: operation, succeeded: false, error: m, at: at)
        case .ask: return ExecutionResult(operation: operation, succeeded: true, needsUser: false, at: at)
        case let .resolution(r):
            switch r {
            case let .answer(a): return ExecutionResult(operation: operation, succeeded: true, entityID: a.lines.compactMap(\.recordID).first?.uuidString, at: at)
            case .proposal, .clarify, .needsDate: return ExecutionResult(operation: operation, succeeded: false, needsUser: true, at: at)
            case let .notFound(m): return ExecutionResult(operation: operation, succeeded: false, error: m, at: at)
            case .notACommand: return ExecutionResult(operation: operation, succeeded: false, error: "Not a command.", at: at)
            }
        }
    }

    /// Opens the newest matching message from Wren's inbox (synced from Gmail), in Wren.
    func openEmail(from sender: String?) -> CaptureReply {
        guard gmailUsable else { return .resolution(.notFound("Gmail isn't connected. Open Connectors › Gmail to set it up.")) }
        let items = mailbox.items.values.sorted { $0.message.date > $1.message.date }
        let match = items.first { item in
            guard let s = sender, !s.isEmpty else { return true }
            let from = (item.message.senderName + " " + item.message.from).lowercased()
            return s.split(separator: " ").allSatisfy { from.contains($0) }
        }
        guard let m = match else {
            return .resolution(.notFound(sender.map { "No email from “\($0)” in Wren's inbox yet. Wren checks Gmail every \(mailPrefs.pollingMinutes) minutes; try Check now in Inbox." } ?? "Wren's inbox is empty."))
        }
        openMail(m.id)
        return .resolution(.answer(Answer(title: "Opened the email from \(m.message.senderName)", lines: [AnswerLine(m.message.subject, recordID: nil)],
                                          basis: "From Wren's synced inbox. Open in Gmail is on the message.")))
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
        record.parentID = r.followUpOf; record.original = r.original
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
        if !isNewRequest, let prefix = reminderFollowUp, reminderFollowUpNeedsSubject {
            // "What should I remind you about?": the answer is the subject; the schedule is kept.
            reminderFollowUp = nil; reminderFollowUpNeedsSubject = false
            guard let merged = ReminderFollowUp.subjectAnswer(text, pending: prefix, now: now, calendar: cal) else { return nil }
            candidate = merged
        } else if !isNewRequest, let prefix = reminderFollowUp {
            // A new, explicit request (ask GPT, save a note) is never read as the answer to the earlier question.
            if !ReminderFollowUp.mayAnswer(text) { reminderFollowUp = nil; return nil }
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
            reminderFollowUp = nil; reminderFollowUpNeedsSubject = false
            return await createReminder(text: candidate, title: title, when: when, explanation: explanation, channel: channel)
        case let .clarify(title, question):
            reminderFollowUpNeedsSubject = title.isEmpty
            reminderFollowUp = question.hasPrefix("Is that") || title.isEmpty ? candidate : "remind me to " + title
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
        return .resolution(.answer(Answer(title: "Reminder created: \(title)", lines: lines, basis: "From your words: “\(text)”")))
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
