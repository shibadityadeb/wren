import SwiftUI
import WrenCore

/// The primary interface: one line, Enter to save, Escape to close.
struct CaptureView: View {
    @Bindable var state: CaptureState
    var submit: (String) -> Void
    var cancel: () -> Void
    var confirm: (ContextProposal) -> Void = { _ in }
    var choose: (Candidate, PendingCommand) -> Void = { _, _ in }
    var saveAsNew: (String) -> Void = { _ in }
    var openAISetup: () -> Void = {}
    var toggleVoice: () -> Void = {}
    /// Actions on the Ask card (run, connect, retry, copy…).
    var askAction: (AskAction) -> Void = { _ in }
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                WrenMarkShape(compact: true)
                    .frame(width: 14, height: 14)
                    .foregroundStyle(.secondary)
                Text("Wren").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(state.status).font(.caption).foregroundStyle(.tertiary)
                if state.voiceEnabled {
                    Button { toggleVoice() } label: {
                        Label(state.recording ? "Stop" : "Speak", systemImage: state.recording ? "stop.circle.fill" : "mic")
                            .foregroundStyle(state.recording ? Color.red : Color.secondary)
                    }
                    .buttonStyle(.borderless).font(.caption)
                    .help("Or press the voice shortcut, or say “Hey Wren”")
                    if state.recording {
                        Button("Cancel", role: .cancel) { cancel() }.buttonStyle(.borderless).font(.caption)
                            .help("Stop listening without doing anything (Escape)")
                    }
                }
                if !state.aiAvailable {
                    Button("Local AI not set up") { openAISetup() }.buttonStyle(.link).font(.caption)
                        .help("Wren still saves everything. Set up local AI for better understanding.")
                }
            }
            TextField("What do you need to do?", text: $state.text)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($focused)
                .onSubmit {
                    // Return does what the card on screen says, once. While a request is running it does nothing.
                    if let card = state.ask {
                        if let a = card.primary { askAction(a) }
                    } else if case let .proposal(p)? = state.reply { confirm(p) } else { submit(state.text) }
                }
                .onChange(of: state.text) {
                    guard !state.busy else { return }
                    if state.reply != nil { state.reply = nil }
                    // Editing the text after a card was shown starts a new request.
                    if let card = state.ask, card.phase != .sending, state.text != card.request.original { state.ask = nil }
                }
            if let v = state.voiceStatus {
                HStack(spacing: 6) {
                    if state.recording { Circle().fill(Color.red).frame(width: 8, height: 8) }
                    Text(v).font(.caption).foregroundStyle(state.recording ? Color.red : Color.secondary)
                }
            }
            if let card = state.ask { AskCardView(card: card, aiAvailable: state.aiAvailable, act: askAction) }
            else if let reply = state.reply { replyView(reply) }
            HStack(spacing: 14) {
                if let card = state.ask {
                    if let p = card.primary { hint("return", p.title(card)) }
                } else if case .proposal? = state.reply { hint("return", "Confirm") } else { hint("return", "Save") }
                hint("esc", "Close")
                Spacer()
                if state.busy { ProgressView().controlSize(.small) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .onAppear { focused = true }
        .onChange(of: state.presentations) { focused = true }
        .onExitCommand(perform: cancel)
    }

    @ViewBuilder private func replyView(_ r: ContextResolution) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch r {
            case let .proposal(p):
                Label(p.preview, systemImage: "arrow.turn.down.right").font(.callout.weight(.medium))
                if let note = p.note { Text(note).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button("Confirm") { confirm(p) }.keyboardShortcut(.defaultAction)
                    Button("Cancel", action: cancel)
                }.controlSize(.small)
            case let .clarify(q, candidates, pending):
                Text(q).font(.callout.weight(.medium))
                ForEach(candidates) { c in
                    Button { choose(c, pending) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.title)
                            Text(c.detail).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
            case let .answer(a):
                Text(a.title).font(.callout.weight(.medium))
                ForEach(a.lines.prefix(8)) { Text("· \($0.text)").font(.callout) }
                if a.lines.count > 8 { Text("and \(a.lines.count - 8) more").font(.caption).foregroundStyle(.secondary) }
                Text(a.basis).font(.caption).foregroundStyle(.secondary)
            case let .notFound(msg):
                Text(msg).font(.callout)
                Button("Save “\(state.text.prefix(40))” as a new item") { saveAsNew(state.text) }.controlSize(.small)
            case let .needsDate(msg):
                Text(msg).font(.callout).foregroundStyle(.secondary)
            case .notACommand:
                EmptyView()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption2.monospaced())
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            Text(label).font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}

@Observable
final class CaptureState {
    var text = ""
    var status = ""
    /// Bumped every time the panel is shown, to refocus the field.
    var presentations = 0
    /// Wren's answer to a command (preview, question, list), shown under the field.
    var reply: ContextResolution?
    var aiAvailable = true
    var voiceEnabled = false
    var recording = false
    var voiceStatus: String?
    var busy = false
    /// The Ask card, when the input is a request for an assistant. Shown instead of `reply`.
    var ask: AskCard?
}

/// "Ask ChatGPT · Question: …" with its state and only the actions that make sense right now.
struct AskCardView: View {
    let card: AskCard
    let aiAvailable: Bool
    let act: (AskAction) -> Void

    var heading: String {
        switch card.destination {
        case .chatgpt: "Ask ChatGPT"
        case .local: "Ask local AI"
        case .choose: "Question for an assistant"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(heading, systemImage: card.destination == .local ? "cpu" : "bubble.left.and.text.bubble.right").font(.callout.weight(.semibold))
            Text("\(card.request.prompt.hasSuffix("?") ? "Question" : "Request"): \(card.request.prompt)").font(.callout).textSelection(.enabled)
            if let note = card.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            switch card.phase {
            case .ready:
                if card.destination == .choose {
                    Text("You didn't name an assistant. Choose who answers, or keep it as a note.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Ask ChatGPT") { act(.run(.chatgpt)) }
                        if aiAvailable { Button("Ask local AI (on this Mac)") { act(.run(.local)) } }
                        Button("Save as a note") { act(.saveAsNote) }
                    }.controlSize(.small)
                } else {
                    Text("Sends only this text, using your ChatGPT plan.").font(.caption).foregroundStyle(.secondary)
                    HStack { Button("Ask ChatGPT") { act(.run(.chatgpt)) }; Button("Save as a note instead") { act(.saveAsNote) } }.controlSize(.small)
                }
            case .sending:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(card.destination == .local ? "Asking the local model…" : "Asking ChatGPT…").font(.caption) }
                if !card.streamed.isEmpty { answerText(card.streamed) }
            case let .answered(text, source, _):
                answerText(text)
                Text(source).font(.caption2).foregroundStyle(.tertiary)
                HStack { Button("Copy answer") { act(.copyAnswer) }; Button("Open in Wren") { act(.openAnswer) } }.controlSize(.small)
            case let .partial(text, source, _, message):
                answerText(text)
                Text(message).font(.caption).foregroundStyle(.orange)
                Text(source).font(.caption2).foregroundStyle(.tertiary)
                HStack { Button("Try again") { act(.run(card.destination == .choose ? .chatgpt : card.destination)) }; Button("Copy answer") { act(.copyAnswer) } }.controlSize(.small)
            case .notConnected:
                Text("ChatGPT isn't connected. Connect your account, then ask; your question stays here.").font(.caption).foregroundStyle(.orange)
                HStack { Button("Connect ChatGPT") { act(.connect) }; Button("Save as a note instead") { act(.saveAsNote) } }.controlSize(.small)
            case .connecting:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Finish signing in to ChatGPT in your browser…").font(.caption) }
            case let .reconnect(m):
                Text(m).font(.caption).foregroundStyle(.orange)
                Button("Reconnect ChatGPT") { act(.connect) }.controlSize(.small)
            case let .needsPermission(m):
                Text(m).font(.caption).foregroundStyle(.orange)
                Button("Allow plan usage…") { act(.allowPlan) }.controlSize(.small)
            case let .usageLimit(m):
                Text(m).font(.caption).foregroundStyle(.orange)
                HStack { Button("Manage usage") { act(.manageUsage) }; Button("Try again") { act(.run(.chatgpt)) } }.controlSize(.small)
            case let .needsReview(m):
                Text(m).font(.caption).foregroundStyle(.orange)
                Button("Review in Delegate") { act(.openDelegate) }.controlSize(.small)
            case let .failed(m, retryable):
                Text(m).font(.caption).foregroundStyle(.orange)
                HStack {
                    if retryable { Button("Try again") { act(.run(card.destination == .choose ? .chatgpt : card.destination)) } }
                    Button("Save as a note instead") { act(.saveAsNote) }
                }.controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    func answerText(_ t: String) -> some View {
        ScrollView { Text(t).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            .frame(maxHeight: 260)
    }
}
