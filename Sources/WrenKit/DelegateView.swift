import SwiftUI
import WrenCore

/// Pick a task, pick where it runs, see exactly what leaves the Mac, then run it.
struct DelegateView: View {
    @Bindable var model: AppModel
    @State private var task = ""
    @State private var deep = false
    @State private var destination: DelegationDestination = .chatgptPlan
    @State private var streamed = ""
    @State private var selectedItems: Set<UUID> = []
    @State private var notionContext: [HandoffContextItem] = []
    @State private var includedPrivate: Set<String> = []
    @State private var includeSensitive = false
    @State private var current: DelegationRecord?
    @State private var pasted = ""
    @State private var message: String?
    @State private var busy = false
    @State private var lookup: [AnswerLine] = []
    @State private var notionQuery = ""
    @State private var notionResults: [NotionPage] = []

    var available: [DelegationDestination] {
        let h = model.hub!
        return DelegationDestination.allCases.filter {
            switch $0 {
            case .chatgptPlan: h.chatgpt.account.canSend && h.chatgpt.selectedModel != nil
            case .chatgptHandoff: h.chatgpt.handoffAvailable
            case .openaiAPI: false
            case .localModel: model.ai.usableModel != nil
            case .notionSearch: h.notion.state.isUsable
            case .gmailSearch: h.gmail.state.isUsable
            case .calendarLookup: model.calendarUsable
            }
        }
    }

    var draft: HandoffDraft {
        HandoffDraft(task: task, depth: deep ? .deep : .normal, context: model.contextItems(for: Array(selectedItems)) + notionContext,
                     includedPrivate: includedPrivate, includeSensitive: includeSensitive)
    }

    var body: some View {
        let _ = model.connectorVersion
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Delegate").font(.title2.weight(.semibold))
                if available.isEmpty {
                    Notice(text: "No destinations are set up. Continue with ChatGPT, connect Notion, Gmail or Calendar, or set up local AI.", systemImage: "puzzlepiece.extension",
                           action: ("Connectors", { model.route = .connectors })).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                TextField("What should be done? e.g. Brainstorm ten names for this project", text: $task, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...6)
                HStack {
                    Picker("Run with", selection: $destination) {
                        ForEach(available, id: \.self) { d in Text(d.label + (d.leavesMac ? "  ↗" : "")).tag(d) }
                    }
                    .frame(maxWidth: 320)
                    Toggle("Ask for deeper thinking", isOn: $deep).disabled(!destination.leavesMac && destination != .localModel)
                }
                Text(destination.leavesMac ? "↗ Sends the prompt below outside your Mac (\(destination.label))." : "Runs on this Mac or only reads from a connected service.")
                    .font(.caption).foregroundStyle(destination.leavesMac ? .orange : .secondary)
                if destination == .chatgptPlan { planIndicator }

                if destination.leavesMac || destination == .localModel { contextPicker; preview }
                actions
                if let message { Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if !lookup.isEmpty {
                    ForEach(lookup) { l in
                        HStack { Text(l.text).font(.callout); Spacer(); if let u = l.externalURL { Link("Open", destination: u).font(.caption) } }
                    }
                }
                if busy && destination == .chatgptPlan && !streamed.isEmpty {
                    ScrollView { Text(streamed).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 220)
                }
                if let r = current { resultSection(r) }
                history
            }
            .padding(18)
        }
        .onAppear {
            if let d = model.delegationDraft { task = d.task; deep = d.depth == .deep; model.delegationDraft = nil }
            if !available.contains(destination), let f = available.first { destination = f }
        }
    }

    /// Which account and allowance a request uses, before it's sent.
    var planIndicator: some View {
        let c = model.hub.chatgpt
        return HStack(spacing: 8) {
            Label("Using ChatGPT plan", systemImage: "checkmark.seal.fill").foregroundStyle(WrenTheme.accent)
            if let e = c.email { Text(e).foregroundStyle(.secondary) }
            Picker("Model", selection: Binding(get: { c.selectedModel ?? "" }, set: { c.selectedModel = $0.isEmpty ? nil : $0; model.connectorVersion += 1 })) {
                ForEach(c.models) { Text($0.displayName).tag($0.slug) }
            }
            .labelsHidden().frame(maxWidth: 200)
            Link("Manage usage", destination: SIWC.manageUsageURL)
        }
        .font(.caption)
    }

    var contextPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Context (optional)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Menu("Add a Wren item…") {
                ForEach(model.pending.prefix(30)) { c in
                    Button((c.isPrivate ? "🔒 " : "") + c.title) { selectedItems.insert(c.id) }
                }
            }.fixedSize()
            if model.hub.notion.state.isUsable {
                HStack {
                    TextField("Search Notion pages to include", text: $notionQuery).textFieldStyle(.roundedBorder).controlSize(.small)
                        .onSubmit { Task { notionResults = (try? await model.notionSearch(notionQuery)) ?? [] } }
                }
                ForEach(notionResults) { p in
                    Button("+ \(p.title)") {
                        Task {
                            if let text = try? await model.notionPageText(p) {
                                notionContext.append(HandoffContextItem(id: p.id, source: "Notion page", title: p.title, text: text, isPrivate: false))
                            }
                        }
                    }.buttonStyle(.link).font(.caption)
                }
            }
            ForEach(draft.context) { c in
                HStack {
                    Image(systemName: c.isPrivate ? "lock" : "doc.text").foregroundStyle(.secondary)
                    Text("\(c.title) · \(c.source)").font(.caption)
                    Spacer()
                    if c.isPrivate {
                        Toggle("Include (private)", isOn: Binding(get: { includedPrivate.contains(c.id) }, set: { on in if on { includedPrivate.insert(c.id) } else { includedPrivate.remove(c.id) } }))
                            .toggleStyle(.checkbox).font(.caption)
                    }
                    Button { selectedItems.remove(UUID(uuidString: c.id) ?? UUID()); notionContext.removeAll { $0.id == c.id } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
            }
        }
    }

    var preview: some View {
        let d = draft
        return VStack(alignment: .leading, spacing: 6) {
            Text(destination.leavesMac ? "Exactly what will leave your Mac" : "Prompt for the local model (stays on this Mac)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView { Text(d.prompt.isEmpty ? "(empty)" : d.prompt).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(minHeight: 80, maxHeight: 220)
                .padding(8).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            if !d.excludedContext.isEmpty {
                Label("Left out because they're private: " + d.excludedContext.map(\.title).joined(separator: ", "), systemImage: "lock").font(.caption).foregroundStyle(.secondary)
            }
            if !d.findings.isEmpty {
                Label("Removed \(d.findings.map(\.label).joined(separator: ", ")).", systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.orange)
                Toggle("Send them as written (not recommended)", isOn: $includeSensitive).toggleStyle(.checkbox).font(.caption)
            }
            if deep && destination == .chatgptHandoff {
                Text("“Deeper thinking” is a request written into the prompt. Wren can't choose or verify ChatGPT's model or thinking mode in the ChatGPT app.").font(.caption2).foregroundStyle(.tertiary)
            } else if deep && destination == .chatgptPlan {
                Text("“Deeper thinking” is a request written into the prompt; the model is the one chosen below.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder var actions: some View {
        HStack {
            switch destination {
            case .chatgptHandoff:
                Button("Copy and open ChatGPT") { run { r in
                    if let e = await model.handOff(draft, record: r) { message = e } else {
                        message = "Copied and opened ChatGPT. Paste (⌘V) and press send there; nothing has been sent by Wren. Then paste the answer below."
                    } } }
                    .buttonStyle(.borderedProminent).tint(WrenTheme.accent).disabled(task.isEmpty || busy)
            case .chatgptPlan:
                Button("Send with ChatGPT") { run { r in
                    streamed = ""
                    await model.sendToChatGPT(draft, record: r) { streamed += $0 }
                    streamed = ""
                    message = r.error } }
                    .buttonStyle(.borderedProminent).tint(WrenTheme.accent).disabled(task.isEmpty || busy)
            case .openaiAPI:
                EmptyView()
            case .localModel:
                Button("Ask local model") { run { r in
                    r.prompt = draft.prompt
                    if let name = model.ai.usableModel, let client = try? OllamaClient() {
                        let schema: JSONValue = .object(["type": .string("object"), "properties": .object(["answer": .object(["type": .string("string")])]), "required": .array([.string("answer")])])
                        if let raw = try? await client.chatJSON(model: name, system: "Answer helpfully. Reply with JSON {\"answer\": …}.", user: draft.prompt, schema: schema, timeout: 120),
                           let d = raw.data(using: .utf8), let v = try? JSONDecoder().decode(JSONValue.self, from: d), let a = v["answer"]?.string {
                            r.response = a; r.responseSource = "Local model \(name) on this Mac"; r.status = .responseImported
                        } else { r.status = .failed; r.error = "The local model didn't answer." }
                    }
                    model.saveDelegation(r) } }
                    .disabled(task.isEmpty || busy)
            case .gmailSearch:
                Button("Search Gmail") { search { (try await model.emailAnswer(task)).lines } }.disabled(task.isEmpty || busy)
            case .calendarLookup:
                Button("Look up calendar") { search { (try await model.calendarAnswer(task)).lines } }.disabled(task.isEmpty || busy)
            case .notionSearch:
                Button("Search Notion") { search { try await model.notionSearch(task).map { AnswerLine($0.title, recordID: nil, externalURL: $0.url) } } }.disabled(task.isEmpty || busy)
            }
            if busy { ProgressView().controlSize(.small) }
        }
    }

    func run(_ op: @escaping (DelegationRecord) async -> Void) {
        guard let r = model.newDelegation(task, destination: destination, depth: deep ? .deep : .normal) else { return }
        busy = true; current = r; message = nil
        Task { await op(r); busy = false }
    }

    func search(_ op: @escaping () async throws -> [AnswerLine]) {
        busy = true; lookup = []
        Task {
            do { lookup = try await op(); message = lookup.isEmpty ? "Nothing found." : nil } catch { message = model.errorText(error) }
            busy = false
        }
    }

    @ViewBuilder func resultSection(_ r: DelegationRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Status: \(r.status.label)").font(.callout.weight(.medium))
            if r.status == .handedOff {
                TextField("Paste ChatGPT's answer here", text: $pasted, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(3...12)
                HStack {
                    Button("Import answer") { model.importResponse(pasted, into: r); pasted = "" }.disabled(pasted.isEmpty)
                    Button("Copy prompt again") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.prompt ?? "", forType: .string) }
                    Button("Cancel", role: .destructive) { r.status = .cancelled; model.saveDelegation(r) }
                }.controlSize(.small)
            }
            if let resp = r.response {
                if let src = r.responseSource { Text(src).font(.caption).foregroundStyle(.secondary) }
                ScrollView { Text(resp).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 220)
                HStack {
                    Button(model.ai.usableModel != nil ? "Summarise on this Mac" : "Short excerpt") { Task { await model.summarizeLocally(r) } }
                    Button("Done") { r.status = .completed; model.saveDelegation(r) }
                    Button("Discard", role: .destructive) { r.response = nil; r.status = .cancelled; model.saveDelegation(r) }
                }.controlSize(.small)
                if let s = r.summary { Text(s).font(.callout).padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6)) }
                let follow = HandoffRequest.followUps(in: resp)
                if !follow.isEmpty {
                    Text("Possible follow-ups (you choose)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(follow, id: \.self) { f in
                        HStack { Text(f).font(.callout); Spacer(); Button("Add as task") { _ = model.capture(f, source: .popover) }.controlSize(.mini) }
                    }
                }
            }
            if let e = r.error { Text(e).font(.caption).foregroundStyle(.orange) }
        }
    }

    var history: some View {
        let items = model.delegations.prefix(15)
        return VStack(alignment: .leading, spacing: 4) {
            if !items.isEmpty { Divider(); Text("History").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            ForEach(Array(items)) { r in
                Button { current = r } label: {
                    HStack {
                        Text(r.task).lineLimit(1)
                        Spacer()
                        Text("\(r.destination.label) · \(r.status == .handedOff ? "waiting for your paste" : r.status.label)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.buttonStyle(.plain).font(.callout)
            }
        }
    }
}
