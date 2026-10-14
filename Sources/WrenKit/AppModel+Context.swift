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
        let source = Self.captureSource(channel)
        func save(_ body: String) -> CaptureReply { capture(body, source: source) ? .saved : .failed("Couldn't save. Your text is still here.") }
        // One routing decision for every entry point; the executor only runs what it decided.
        let intent = CommandRouter.intent(for: trimmed, now: clock.now, calendar: clock.calendar)
        lastIntent = intent
        log.notice("route \(intent.summary, privacy: .public) via \(channel.rawValue, privacy: .public)")
        // Wren asked "When should I remind you…?" or "What should I remind you about?": a bare time
        // or subject answers it. A request of its own (a task, a GPT request, a question) is new.
        if reminderFollowUp != nil {
            if intent.rule == .datedStatement || intent.rule == .capture || intent.rule == .reminderRequest {
                if let r = await reminderRequest(trimmed, channel: channel) { return ("CreateReminder", r) }
            } else {
                reminderFollowUp = nil; reminderFollowUpNeedsSubject = false
            }
        }
        let all = (try? store?.all()) ?? []
        let operation = intent.operation
        switch operation {
        case let .saveNote(body):
            return (operation.name, save(body))
        case .createReminder:
            if let r = await reminderRequest(trimmed, channel: channel) { return (operation.name, r) }
            // The parser couldn't complete what the router read as a reminder: never lose the words.
            return (operation.name, save(trimmed))
        case let .createTask(draft):
            return (operation.name, await createTask(draft, text: trimmed, channel: channel))
        case let .delegateToChatGPT(request):
            return (operation.name, .ask(request))
        case let .followUpDelegation(f):
            return (operation.name, followUp(f, text: text))
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
            // Wren's own items: answered from the store, never from a connector ("move the meeting prep task" isn't a calendar question).
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
        case .searchGmail:
            // The authorized Gmail account, read now. Never an answer from memory when it can't be read.
            if trimmed.lowercased().range(of: #"\bneeds? my attention\b"#, options: .regularExpression) != nil { return (operation.name, .resolution(.answer(await attentionAnswer(trimmed)))) }
            guard hub.gmail.state.isUsable else { return (operation.name, .resolution(.notFound(Self.connectorProblem("Gmail", hub.gmail.state, place: "Connectors › Gmail")))) }
            do { return (operation.name, .resolution(.answer(try await emailAnswer(trimmed)))) } catch { return (operation.name, .resolution(.notFound(errorText(error)))) }
        case .queryCalendar:
            guard calendarUsable else { return (operation.name, .resolution(.notFound("No calendar is connected. Open Connectors › Calendar and allow access to the calendars on this Mac."))) }
            do { return (operation.name, .resolution(.answer(try await calendarAnswer(trimmed)))) } catch { return (operation.name, .resolution(.notFound(errorText(error)))) }
        case let .generalQuestion(request):
            return (operation.name, .ask(request))
        case .capture:
            // Nothing in the words names an action. Only then may the local model help, and only
            // with a reading it can ground in the user's own words; otherwise the text is kept.
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

    /// Where an item came from, for its history: voice, the menu-bar field, or the capture panel.
    static func captureSource(_ channel: UserChannel) -> CaptureSource {
        switch channel { case .voice: .voice; case .popover: .popover; default: .hotkey }
    }

    /// Why a connector can't answer, in its real state: not connected, sign-in expired, missing permission…
    static func connectorProblem(_ name: String, _ state: ConnectorState, place: String) -> String {
        switch state {
        case let .reauthorizationRequired(d): return "\(name) needs you to sign in again (\(d)). Open \(place) and choose Reconnect. Your question wasn't answered from old data."
        case let .missingPermissions(d): return "\(name) is missing a permission (\(d)). Open \(place) to allow it."
        case let .temporarilyUnavailable(d): return "\(name) couldn't be reached (\(d)). Try again in a moment."
        case let .notAvailableInBuild(d): return "\(name) isn't available in this build of Wren (\(d))."
        default: return "\(name) isn't connected. Open \(place) to connect it."
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
        let lower = (ReminderCommand.canonical(CommandGrammar.request(ReminderCommand.stripAddress(candidate))) ?? candidate).lowercased()
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
            // "… by Friday" also states a deadline; "tomorrow at 10" is only when to remind.
            let deadline = ReminderCommand.statedDeadline(candidate, now: now, calendar: cal)
            return await createReminder(text: candidate, title: title, when: when, explanation: explanation, channel: channel, deadline: deadline)
        case let .clarify(title, question):
            reminderFollowUpNeedsSubject = title.isEmpty
            reminderFollowUp = question.hasPrefix("Is that") || title.isEmpty ? candidate : "remind me to " + title
            return .resolution(.needsDate(question))
        case let .past(title, message):
            reminderFollowUp = "remind me to " + title
            return .resolution(.needsDate(message))
        }
    }

    func createReminder(text: String, title: String, when: ReminderWhen, explanation: String?, channel: UserChannel, deadline: ParsedDate? = nil) async -> CaptureReply {
        guard let store, let broker else { return .failed(storeError ?? "Wren's database isn't available.") }
        // First reminder: this is when macOS asks for permission, with Wren's reason in the prompt.
        await askForNotificationsIfNeeded()
        let source = Self.captureSource(channel)
        switch await ItemExecution.createReminder(text: text, title: title, when: when, deadline: deadline, source: source, origin: .user(channel),
                                                  store: store, broker: broker, scheduler: reminders, now: clock.now) {
        case let .failure(f): reload(); return .failed(f.message)
        case let .success(o):
            noteRecent(o.itemID); afterScheduling()
            let cal = clock.calendar
            var lines: [AnswerLine] = []
            switch when {
            case let .once(d): lines.append(AnswerLine(DueText.describe(d, hasTime: true, now: clock.now, calendar: cal).capitalizedFirstLetter, recordID: o.itemID))
            case let .repeating(rule):
                lines.append(AnswerLine(rule.label(calendar: cal) + (o.reminderAt.map { " · first \(DueText.describe($0, hasTime: true, now: clock.now, calendar: cal))" } ?? ""), recordID: o.itemID))
            }
            if let explanation { lines.append(AnswerLine(explanation, recordID: nil)) }
            if let d = o.deadline { lines.append(AnswerLine("Deadline: \(DueText.describe(d, hasTime: o.deadlineHasTime, now: clock.now, calendar: cal))", recordID: nil)) }
            lines.append(AnswerLine(scheduleStatus(o), recordID: nil))
            log.notice("reminder created: planned=\(o.planned.count, privacy: .public) accepted=\(o.planned.filter { o.accepted.contains($0.id) }.count, privacy: .public) authorized=\(o.notificationsAuthorized, privacy: .public)")
            return .resolution(.answer(Answer(title: "Reminder created: \(o.title)", lines: lines, basis: "From your words: “\(text)”")))
        }
    }

    /// "I need to submit the assignment by Friday", "Create a task to follow up with the recruiter":
    /// saves the words, stores the task with the deadline exactly as said (none when none was said),
    /// schedules the deadline reminders the user's settings call for, checks what macOS accepted, and
    /// reports only what is really stored and scheduled. The deadline, the reminder times and the
    /// notifications are reported separately.
    func createTask(_ draft: TaskDraft, text: String, channel: UserChannel) async -> CaptureReply {
        let source = Self.captureSource(channel)
        guard let store, let broker else {
            return capture(text, source: source) ? .saved : .failed("Couldn't save. Your text is still here.")
        }
        let autoRemind = policy.rules.contains(.autoRemindDeadlines)
        if draft.deadline != nil, autoRemind { await askForNotificationsIfNeeded() }
        switch await ItemExecution.createTask(draft, text: text, source: source, store: store, broker: broker, scheduler: reminders,
                                              autoRemind: autoRemind, reminderHour: reminderHour, now: clock.now) {
        case let .failure(f): reload(); return .failed([f.message, f.recovery].compactMap { $0 }.joined(separator: " "))
        case let .success(o):
            noteRecent(o.itemID); afterScheduling()
            let cal = clock.calendar
            func when(_ d: Date, time: Bool = true) -> String { DueText.describe(d, hasTime: time, now: clock.now, calendar: cal) }
            var lines: [AnswerLine] = []
            if let d = o.deadline {
                lines.append(AnswerLine("Deadline: \(when(d, time: o.deadlineHasTime))", recordID: o.itemID))
            } else {
                lines.append(AnswerLine("No deadline was given, so none is set.", recordID: o.itemID))
            }
            if draft.deadline?.isApproximate == true { lines.append(AnswerLine("“\(draft.deadline!.phrase)” is approximate; adjust if needed.", recordID: nil)) }
            let times: [String] = o.planned.compactMap { r in
                guard case let .at(d) = r.trigger else { return nil }
                return r.isAdvance ? "\(when(d)) (the day before)" : when(d)
            }
            if !times.isEmpty {
                lines.append(AnswerLine("Reminder\(times.count == 1 ? "" : "s"): " + times.joined(separator: " and "), recordID: nil))
                lines.append(AnswerLine(scheduleStatus(o), recordID: nil))
            } else if o.deadline != nil {
                lines.append(AnswerLine(autoRemind ? "No reminder: the deadline's reminder time has already passed." : "No reminder: deadline reminders are off in Settings › Permissions.", recordID: nil))
            } else {
                lines.append(AnswerLine("Say “remind me to … at …” to add a reminder.", recordID: nil))
            }
            log.notice("task created: deadline=\(o.deadline != nil, privacy: .public) planned=\(o.planned.count, privacy: .public) accepted=\(o.planned.filter { o.accepted.contains($0.id) }.count, privacy: .public)")
            return .resolution(.answer(Answer(title: "Task created: \(o.title)", lines: lines, basis: "From your words: “\(text)”")))
        }
    }

    /// What macOS really holds, in words. Never "scheduled" unless macOS accepted every request.
    func scheduleStatus(_ o: ScheduledOutcome) -> String {
        let one = o.planned.count <= 1
        if o.allScheduled { return "Scheduled with macOS: \(one ? "it appears" : "they appear") even if Wren is closed." }
        if o.planned.isEmpty { return "Nothing to schedule: the time has passed." }
        if !o.notificationsAuthorized { return "Saved, but notifications are off for Wren, so \(one ? "it" : "they") will only show inside Wren. Turn them on in System Settings › Notifications." }
        if o.paused { return "Saved. Notifications are paused; \(one ? "it" : "they") will be included when they resume." }
        return "Saved, but macOS didn't accept the notification. Wren will try again and show it in the app."
    }

    func askForNotificationsIfNeeded() async {
        guard notificationStatus == .notDetermined else { return }
        _ = await notifications.requestPermission()
        notificationStatus = notifications.status
    }

    /// After ItemExecution scheduled: the app's view of the store and of macOS catches up.
    func afterScheduling() {
        reload()
        if let r = reminders?.lastReport { reminderSync = r }
        notificationStatus = notifications.status
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
