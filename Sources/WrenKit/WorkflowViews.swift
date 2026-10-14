import AppKit
import SwiftUI
import WrenCore

// MARK: GPT delegations

/// One delegated request and its genuine result: the original words, what was sent, status,
/// provider and model, timing, and the answer exactly as returned. Reached from the completion
/// notification, the capture panel, the overview and Delegate history.
struct DelegationDetailView: View {
    @Bindable var model: AppModel
    let id: UUID
    @State private var live = ""
    @State private var note: String?
    @State private var find = ""
    @State private var link = ""

    var body: some View {
        let _ = model.delegationVersion
        ScrollView {
            if let r = model.asks?.record(id) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button { model.route = .delegate } label: { Label("Delegate", systemImage: "chevron.left") }.buttonStyle(.link)
                        Spacer()
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.task).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Spacer()
                        StatusBadge(status: r.status, label: r.displayStatus)
                    }
                    facts(r)
                    if r.destination == .chatgptHandoff { webHandoff(r) }
                    if r.status == .running {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Running in ChatGPT. You can leave this page; Wren will notify you when it finishes.").font(.callout) }
                        if !live.isEmpty { answer(live) }
                        Button("Cancel request", role: .destructive) { model.cancelDelegation(r.id) }.controlSize(.small)
                    }
                    if let e = r.error, r.status != .running {
                        Label(e, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    if let resp = r.response, r.status != .running {
                        HStack {
                            Text(r.status == .partial ? "Partial answer, as returned" : "Answer, as returned").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            TextField("Find in answer", text: $find).textFieldStyle(.roundedBorder).frame(maxWidth: 200).controlSize(.small)
                            if !find.isEmpty { Text(Self.matchCount(find, in: resp)).font(.caption).foregroundStyle(.secondary) }
                        }
                        answer(resp, highlight: find)
                        if !r.sources.isEmpty {
                            Text("Sources ChatGPT cited").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(r.sources, id: \.url) { src in
                                if let u = URL(string: src.url) { Link(src.title, destination: u).font(.callout).help(src.url) }
                            }
                        }
                    }
                    actions(r)
                    if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    if r.destination == .chatgptPlan {
                        Text("Run with connected ChatGPT in Wren: sent through your ChatGPT plan with storage off, so it isn't a ChatGPT conversation and won't appear in your ChatGPT history. The request and answer live here, on this Mac.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
            } else {
                Text("That request no longer exists.").foregroundStyle(.secondary).padding(18)
            }
        }
        .onAppear {
            model.asks?.onDelta = { [id] rid, d in if rid == id { live += d } }
            if let r = model.asks?.record(id), r.seenAt == nil, r.status.isFinal { r.seenAt = model.clock.now; model.saveDelegation(r) }
        }
        .onDisappear { model.asks?.onDelta = { _, _ in } }
    }

    @ViewBuilder func facts(_ r: DelegationRecord) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            if let o = r.original, o != r.task { row("You said", o) }
            row("Sent", r.prompt ?? r.task)
            row("Destination", r.destination.label)
            row("Mode", r.modeLabel)
            row("Status", r.displayStatus)
            if let pid = r.parentID, let p = model.asks?.record(pid) { row("Follows up", p.task) }
            if r.destination == .chatgptPlan {
                row("Kind", r.kind.label)
                row("Reasoning", Self.effortText(r))
                if r.webSearchRequested || r.webSearchCalls > 0 { row("Web search", Self.searchText(r)) }
            }
            if let m = r.requestedModel { row("Model", m + (r.reportedModel.map { $0 == m ? "" : " (response reports \($0))" } ?? " (not reported)")) }
            row("Created", r.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let c = r.completedAt { row(r.status == .completed ? "Completed" : "Ended", c.formatted(date: .abbreviated, time: .shortened)) }
            if r.attempts > 1 { row("Attempts", "\(r.attempts)") }
            if let ch = r.channel { row("From", ch == .voice ? "Voice" : (ch == .hotkey ? "Capture panel" : "Wren window")) }
        }
        .font(.callout)
    }

    /// A ChatGPT website handoff: what Wren knows, the conversation link, and the next steps.
    @ViewBuilder func webHandoff(_ r: DelegationRecord) -> some View {
        let state = r.webState ?? .awaitingSubmission
        VStack(alignment: .leading, spacing: 8) {
            Label(state.label, systemImage: state.hasConversation ? "checkmark.bubble" : (state == .failedToOpen || state == .signInRequired ? "exclamationmark.triangle" : "text.bubble"))
                .font(.callout.weight(.semibold))
            Text(state.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let url = r.conversationURL {
                HStack { Text(url.absoluteString).font(.caption.monospaced()).textSelection(.enabled); Spacer() }
            }
            HStack {
                Button(r.conversationURL == nil ? "Open ChatGPT again" : "Open conversation in ChatGPT") {
                    Task { if let e = await model.reopenInChatGPT(r.id) { note = e } }
                }.buttonStyle(.borderedProminent).tint(WrenTheme.accent)
                    .help(r.conversationURL == nil ? "No conversation is known yet, so this opens ChatGPT with the question again." : "Opens this exact conversation.")
                if state.awaitsSending, BrowserTabs.defaultBrowser != nil, !model.settings.chatgptDetectConversation {
                    Button("Detect conversation automatically…") { Task { note = await model.detectConversation(for: r.id) ?? "Watching for the conversation. Press Enter in ChatGPT to send your question." } }
                }
                if state.awaitsSending { Button("I sent it") { model.markWebSubmitted(r.id) } }
                Button("Run with ChatGPT inside Wren") {
                    let req = AIRequest(prompt: r.prompt ?? r.task, original: r.original ?? r.task, depth: r.depth, kind: r.kind, target: .chatgpt, mode: .inWren)
                    switch model.startDelegation(req, channel: .popover) {
                    case let .started(id), let .duplicate(id): model.openDelegation(id)
                    case let .notRun(o): note = DelegateView.describe(o)
                    }
                }.help("Runs the same request with connected ChatGPT in Wren. The answer is stored in Wren, not in ChatGPT's history.")
            }.controlSize(.small)
            HStack {
                TextField("Conversation link, e.g. https://chatgpt.com/c/…", text: $link).textFieldStyle(.roundedBorder).frame(maxWidth: 380)
                Button("Save link") { note = model.linkConversation(r.id, link) ?? "Linked."; if model.asks?.record(r.id)?.conversationURL != nil { link = "" } }
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Paste from clipboard") { note = model.linkConversationFromClipboard(r.id) ?? "Linked." }
                    .help("Reads the clipboard only now, when you click.")
            }.controlSize(.small)
            Text("Wren opens ChatGPT in your browser with your question in the message box, and you press Enter there: ChatGPT doesn't let other apps send it, and OpenAI offers no supported way for an app to create the conversation or read its answer. With detection on, Wren sees when the conversation starts and saves its link; otherwise link it yourself. Wren can't tell when ChatGPT's answer is finished.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled).lineLimit(6)
        }
    }

    /// Requested versus reported, never assumed.
    static func effortText(_ r: DelegationRecord) -> String {
        switch (r.requestedEffort, r.reportedEffort) {
        case (nil, nil): return "Model default"
        case let (nil, rep?): return "Model default (response reports \(rep))"
        case let (req?, nil): return r.status == .completed ? "Asked for \(req); the response didn't report its effort" : "Asked for \(req)"
        case let (req?, rep?): return req == rep ? "\(rep) (asked for and reported)" : "Asked for \(req); response reports \(rep)"
        }
    }

    static func searchText(_ r: DelegationRecord) -> String {
        if r.webSearchCalls > 0 { return "Used: \(r.webSearchCalls) search\(r.webSearchCalls == 1 ? "" : "es") reported by ChatGPT" }
        switch r.status {
        case .completed, .partial: return "Offered, but ChatGPT didn't search the web for this answer"
        case .running: return "Offered (if your account allows it)"
        default: return r.failure == .unsupportedCapability ? "Not available for this model or workspace" : "Offered; not run"
        }
    }

    static func matchCount(_ q: String, in t: String) -> String {
        let n = t.lowercased().components(separatedBy: q.lowercased()).count - 1
        return n == 1 ? "1 match" : "\(n) matches"
    }

    func answer(_ t: String, highlight: String = "") -> some View {
        var a = AttributedString(t)
        if highlight.count >= 2 {
            var search = a.startIndex
            while let r = a[search...].range(of: highlight, options: .caseInsensitive) {
                a[r].backgroundColor = .yellow.opacity(0.45)
                search = r.upperBound
            }
        }
        return ScrollView { Text(a).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            .frame(minHeight: 80, maxHeight: 360)
            .padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder func actions(_ r: DelegationRecord) -> some View {
        HStack {
            if r.canRetry {
                Button("Retry") {
                    switch model.retryDelegation(r.id) {
                    case .started, .duplicate: note = "Retrying the same request."; live = ""
                    case let .notRun(o): note = DelegateView.describe(o)
                    }
                }.buttonStyle(.borderedProminent).tint(WrenTheme.accent)
            }
            if r.failure == .reauthorizationRequired || r.failure == .planNotAuthorized {
                Button("Reconnect ChatGPT") { model.connectChatGPT(reconsent: r.failure == .planNotAuthorized) }
            }
            if r.failure == .usageLimit { Link("Manage usage", destination: SIWC.manageUsageURL) }
            if r.status == .failed, r.failure == .unsupportedCapability {
                Button("Run with standard settings") {
                    switch model.retryDelegation(r.id, standardSettings: true) {
                    case .started, .duplicate: note = "Running again without web search or a reasoning override."; live = ""
                    case let .notRun(o): note = DelegateView.describe(o)
                    }
                }.buttonStyle(.borderedProminent).tint(WrenTheme.accent)
            }
            if let resp = r.response {
                Button("Copy answer") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(resp, forType: .string); note = "Copied." }
            }
            if r.destination != .chatgptHandoff {
                // Honest: opens the ChatGPT website, not this request (an in-Wren request has no conversation).
                Button("Open ChatGPT website") { NSWorkspace.shared.open(ChatGPTWeb.home) }
                    .help("Opens ChatGPT. This request ran in Wren, so it isn't in your ChatGPT history.")
            }
        }
        .controlSize(.small)
    }
}

struct StatusBadge: View {
    let status: DelegationStatus
    /// A more specific label (Queued, Needs reconnection) when the record has one.
    var label: String? = nil
    var body: some View {
        let (base, color): (String, Color) = switch status {
        case .running: ("Running", .blue)
        case .completed: ("Completed", WrenTheme.accent)
        case .partial: ("Incomplete", .orange)
        case .failed: ("Failed", .red)
        case .cancelled: ("Cancelled", .secondary)
        case .handedOff: ("In ChatGPT", .orange)
        case .responseImported: ("Answer pasted", WrenTheme.accent)
        case .prepared: ("Not sent", .secondary)
        }
        let text = label.map { $0.count <= 22 ? $0 : base } ?? base
        Text(text).font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }
}

/// Compact list for the overview: running and recent GPT requests, newest first.
struct RecentDelegations: View {
    var model: AppModel
    var body: some View {
        let items = model.recentDelegations
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("GPT requests").font(.title3.weight(.semibold))
                    Spacer()
                    Button("All") { model.route = .delegate }.buttonStyle(.link)
                }
                ForEach(items) { r in
                    Button { model.openDelegation(r.id) } label: {
                        HStack {
                            if r.status.isFinal && r.seenAt == nil && r.notifiedAt != nil { Circle().fill(WrenTheme.accent).frame(width: 6, height: 6) }
                            Text(r.task).lineLimit(1)
                            Spacer()
                            StatusBadge(status: r.status)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: Inbox

/// Important mail, the latest digest, and the mail settings. Every line says why it's here.
struct InboxView: View {
    @Bindable var model: AppModel
    @State private var showSettings = false
    @State private var showAll = false

    var body: some View {
        let _ = model.mailVersion
        let _ = model.connectorVersion
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Inbox").font(.title2.weight(.semibold))
                    Spacer()
                    if model.mailSyncing { ProgressView().controlSize(.small) }
                    Button("Check now") { Task { await model.checkMail(.user(.popover)) } }.disabled(!model.gmailUsable || model.mailSyncing)
                    Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }.help("Mail settings")
                }
                status
                if showSettings { MailSettingsView(model: model) }
                if model.gmailUsable {
                    if let d = model.latestDigest { DigestCard(model: model, digest: d) }
                    let all = model.mailbox.inbox.filter { $0.message.unread && $0.dismissedAt == nil }
                    let important = all.filter { $0.classification.category.isImportant }
                    if important.isEmpty { Text("Nothing important is waiting. Wren shows unread inbox mail that looks urgent, time-sensitive, needs a reply, is work-related or is a financial notice.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(MailCategory.allCases.filter(\.isImportant), id: \.self) { c in
                        let items = important.filter { $0.classification.category == c }
                        if !items.isEmpty {
                            Text(c.label).font(.caption.weight(.semibold)).foregroundStyle(c == .urgent ? .orange : .secondary)
                            ForEach(items) { MailRow(model: model, item: $0) }
                        }
                    }
                    let low = all.filter { !$0.classification.category.isImportant }
                    if !low.isEmpty {
                        DisclosureGroup("Informational, no action needed (\(low.count))", isExpanded: $showAll) {
                            ForEach(low.prefix(50)) { MailRow(model: model, item: $0) }
                        }.font(.callout)
                    }
                }
            }
            .padding(18)
        }
        .onAppear { if model.gmailUsable, model.mailbox.lastSyncAt == nil { Task { await model.checkMail(.user(.popover)) } } }
    }

    @ViewBuilder var status: some View {
        if !model.gmailUsable {
            Notice(text: "Gmail isn't connected. Connect Google to get the email digest and alerts for urgent mail.", systemImage: "envelope",
                   action: ("Connectors", { model.route = .connector(.gmail) })).clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            VStack(alignment: .leading, spacing: 3) {
                let m = model.mailbox
                Text([m.account, m.lastSyncAt.map { "checked \(DueText.describe($0, hasTime: true, now: model.clock.now, calendar: model.clock.calendar))" },
                      model.backgroundMailAllowed ? "checking every \(model.mailPrefs.pollingMinutes) min while Wren runs" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let s = model.mailStatus ?? m.lastError { Text(s).font(.caption).foregroundStyle(.orange) }
                if !model.backgroundMailAllowed {
                    Notice(text: "Background checking is off, so there are no new-mail alerts or automatic digests. Wren only checks when you press Check now.",
                           systemImage: "bell.slash", action: ("Turn on", { model.setBackgroundMail(true) })).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Text("Triage runs on this Mac with rules. Email content is never sent to ChatGPT or any other AI service.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

struct MailRow: View {
    var model: AppModel
    let item: MailItem
    var body: some View {
        Button { model.route = .mailMessage(item.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.message.senderName).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer()
                    Text(DueText.describe(item.message.date, hasTime: true, now: model.clock.now, calendar: model.clock.calendar)).font(.caption).foregroundStyle(.secondary)
                }
                Text(item.message.subject.isEmpty ? "(no subject)" : item.message.subject).lineLimit(1)
                Text("Why: " + item.classification.reasons.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(8).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// One message: facts from Gmail, Wren's inference (labelled), and the allowed actions.
struct MailMessageView: View {
    @Bindable var model: AppModel
    let id: String
    @State private var working = false
    @State private var result: String?

    var body: some View {
        let _ = model.mailVersion
        ScrollView {
            if let item = model.mailbox.items[id] {
                let m = item.message, c = item.classification
                VStack(alignment: .leading, spacing: 12) {
                    Button { model.route = .inbox } label: { Label("Inbox", systemImage: "chevron.left") }.buttonStyle(.link)
                    Text(m.subject.isEmpty ? "(no subject)" : m.subject).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow { Text("From").foregroundStyle(.secondary); Text(m.from).textSelection(.enabled) }
                        GridRow { Text("Received").foregroundStyle(.secondary); Text(m.date.formatted(date: .abbreviated, time: .shortened)) }
                        GridRow { Text("State").foregroundStyle(.secondary); Text(m.unread ? "Unread in Gmail" : "Read in Gmail") }
                    }.font(.callout)
                    GroupBox("From the email (Gmail's preview)") {
                        Text(m.snippet.isEmpty ? "No preview." : m.snippet).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Wren's reading (inferred)") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(c.category.label)\(c.corrected ? " (set by you)" : "")").font(.callout.weight(.medium))
                            Text("Why: " + c.reasons.joined(separator: "; ")).font(.callout)
                            Text("Suggested: " + c.suggestedAction).font(.callout)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    actions(item)
                    if let e = item.lastActionError { Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
                    Text("Dismiss and Snooze only change Wren's alerts; your Gmail message is unchanged.").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(18)
            } else {
                VStack(alignment: .leading) {
                    Text("That email isn't in Wren's inbox anymore (read, archived or older than 30 days).").foregroundStyle(.secondary)
                    Button("Inbox") { model.route = .inbox }
                }.padding(18)
            }
        }
    }

    @ViewBuilder func actions(_ item: MailItem) -> some View {
        HStack {
            Link("Open in Gmail", destination: item.message.webURL)
            if item.message.unread {
                if model.canMarkRead {
                    Button(item.lastActionError == nil ? "Mark as read" : "Retry Mark as read") {
                        working = true
                        Task { result = await model.markRead(item.id) ?? "Marked as read in Gmail."; working = false }
                    }.disabled(working)
                } else if model.gmailUsable {
                    Button("Allow Mark as read…") { model.allowMarkAsRead() }
                        .help("Asks Google for permission to change your email's read state (gmail.modify). Google's permission also covers other changes; Wren only implements Mark as read.")
                }
            }
            Button("Add task…") { model.taskFromMail(item) }
            Menu("Correct") {
                ForEach(MailCategory.allCases, id: \.self) { c in Button(c.label) { model.correctMail(item.id, to: c) } }
                Divider()
                Button("Always important from \(item.message.senderAddress)") { model.setSenderRule(item.message.senderAddress, .important) }
                Button("Never important from \(item.message.senderAddress)") { model.setSenderRule(item.message.senderAddress, .notImportant) }
                if model.mailbox.senderRules[item.message.senderAddress] != nil {
                    Button("Clear rule for this sender") { model.setSenderRule(item.message.senderAddress, nil) }
                }
            }.fixedSize()
            Menu("Alert") {
                Button("Dismiss alert") { model.dismissMailAlert(item.id); model.route = .inbox }
                Button("Snooze 3 hours") { model.snoozeMail(item.id, hours: 3) }
                Button("Snooze until tomorrow") { model.snoozeMail(item.id, hours: 18) }
            }.fixedSize()
            if working { ProgressView().controlSize(.small) }
        }
        .controlSize(.small)
    }
}

struct DigestCard: View {
    var model: AppModel
    let digest: DigestRecord
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Email digest · \(digest.createdAt.formatted(date: .abbreviated, time: .shortened))\(digest.late ? " (late)" : "")").font(.callout.weight(.semibold))
                Spacer()
                Text(digest.state == .delivered ? "Notified" : digest.state == .empty ? "Nothing new" : digest.state == .undelivered ? "Not notified (notifications off)" : "Pending")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if digest.entries.isEmpty { Text("No unread inbox mail to report.").font(.caption).foregroundStyle(.secondary) }
            ForEach(digest.entries.prefix(expanded ? 50 : 4)) { e in
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text("\(e.sender): \(e.subject)\(e.count > 1 ? " (\(e.count))" : "")").font(.callout).lineLimit(1)
                        Spacer()
                        Link("Open email", destination: e.link).font(.caption)
                    }
                    Text("Summary: \(e.summary)").font(.caption).lineLimit(2)
                    Text("Inferred: \(e.category.shortLabel) · \(e.reason) · Suggested: \(e.suggestedAction)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if digest.entries.count > 4 { Button(expanded ? "Show less" : "Show all \(digest.entries.count)") { expanded.toggle() }.buttonStyle(.link).font(.caption) }
        }
        .padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MailSettingsView: View {
    @Bindable var model: AppModel
    var body: some View {
        let p = model.mailPrefs
        GroupBox("Mail settings") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Check for new mail while Wren runs", isOn: Binding(get: { model.backgroundMailAllowed }, set: { model.setBackgroundMail($0) }))
                Stepper("Every \(p.pollingMinutes) minutes", value: Binding(get: { p.pollingMinutes }, set: { v in model.updateMail { $0.pollingMinutes = v } }), in: 2...60)
                Divider()
                Toggle("Daily email digest", isOn: Binding(get: { p.digest.enabled }, set: { v in model.updateMail { $0.digest.enabled = v } }))
                DatePicker("Digest time", selection: Binding(get: { model.clock.calendar.time(minutesAfterMidnight: p.digest.minutesAfterMidnight, on: model.clock.now) },
                                                              set: { d in let c = model.clock.calendar.dateComponents([.hour, .minute], from: d); model.updateMail { $0.digest.minutesAfterMidnight = (c.hour ?? 8) * 60 + (c.minute ?? 0) } }),
                           displayedComponents: .hourAndMinute).disabled(!p.digest.enabled)
                Picker("Time zone", selection: Binding(get: { p.digest.timeZoneID ?? "" }, set: { v in model.updateMail { $0.digest.timeZoneID = v.isEmpty ? nil : v } })) {
                    Text("This Mac (\(TimeZone.current.identifier))").tag("")
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 360).disabled(!p.digest.enabled)
                Text("With the digest on, the morning briefing leaves email out so you're not told twice.").font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("Alert me about important new mail", isOn: Binding(get: { p.alertsEnabled }, set: { v in model.updateMail { $0.alertsEnabled = v } }))
                Picker("Alert for", selection: Binding(get: { p.alertLevel }, set: { v in model.updateMail { $0.alertLevel = v } })) {
                    ForEach(MailAlertLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                }.frame(maxWidth: 360).disabled(!p.alertsEnabled)
                Toggle("Include the email's first sentence in alerts", isOn: Binding(get: { p.alertPreview }, set: { v in model.updateMail { $0.alertPreview = v } }))
                    .disabled(!p.alertsEnabled)
                Text("Clicking an alert opens that conversation in Gmail. “Show in Wren” opens it here instead.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Quiet hours (hold alerts until they end)", isOn: Binding(get: { p.quietHours.enabled }, set: { v in model.updateMail { $0.quietHours.enabled = v } }))
                HStack {
                    DatePicker("From", selection: minutes(\.quietHours.startMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("to", selection: minutes(\.quietHours.endMinutes), displayedComponents: .hourAndMinute)
                }.disabled(!p.quietHours.enabled)
                Divider()
                Text("Email is triaged on this Mac with rules. Wren never sends email content to ChatGPT or any other AI service; there's no setting that would.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func minutes(_ kp: WritableKeyPath<MailPreferences, Int>) -> Binding<Date> {
        Binding(get: { model.clock.calendar.time(minutesAfterMidnight: model.mailPrefs[keyPath: kp], on: model.clock.now) },
                set: { d in let c = model.clock.calendar.dateComponents([.hour, .minute], from: d); model.updateMail { $0[keyPath: kp] = (c.hour ?? 0) * 60 + (c.minute ?? 0) } })
    }
}

/// Overview card: the few unread messages that matter most right now.
struct ImportantMailSummary: View {
    var model: AppModel
    var body: some View {
        let _ = model.mailVersion
        if model.gmailUsable {
            let items = model.mailbox.inbox.filter { $0.message.unread && $0.dismissedAt == nil && $0.classification.category.isImportant }.prefix(4)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Important email").font(.title3.weight(.semibold))
                    Spacer()
                    Button("Inbox") { model.route = .inbox }.buttonStyle(.link)
                }
                if items.isEmpty { Text(model.mailbox.lastSyncAt == nil ? "Not checked yet." : "Nothing important unread.").font(.callout).foregroundStyle(.secondary) }
                ForEach(Array(items)) { MailRow(model: model, item: $0) }
            }
        }
    }
}
