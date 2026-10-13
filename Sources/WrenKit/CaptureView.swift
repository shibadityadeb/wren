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
    /// Discard the transcript and record the command again (wrong transcription).
    var retryVoice: () -> Void = {}
    /// Actions on the Ask card (run, connect, retry, copy…).
    var askAction: (AskAction) -> Void = { _ in }
    /// The user started typing while Wren was recording: stop recording, keep the text.
    var editedWhileListening: () -> Void = {}
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
                    if state.recording {
                        Button("Cancel", role: .cancel) { cancel() }.buttonStyle(.borderless).font(.caption)
                            .help("Stop recording without doing anything (Escape)")
                    } else {
                        Button { toggleVoice() } label: { Label("Voice", systemImage: "mic.fill") }
                            .buttonStyle(.bordered).controlSize(.small).tint(WrenTheme.accent)
                            .disabled(state.busy)
                            .help("Record one spoken command. The microphone turns off when you stop speaking. You can also press the voice shortcut.")
                            .accessibilityLabel("Start a voice command")
                    }
                }
                if !state.aiAvailable {
                    Button("Local AI not set up") { openAISetup() }.buttonStyle(.link).font(.caption)
                        .help("Wren still saves everything. Set up local AI for better understanding.")
                }
            }
            // Grows to show a whole spoken sentence so it can be checked and edited. Return still submits.
            TextField("What do you need to do?", text: $state.text, axis: .vertical)
                .lineLimit(1...4)
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
                    if state.recording, state.text != state.lastVoiceText { editedWhileListening() }
                    guard !state.busy else { return }
                    if state.reply != nil { state.reply = nil }
                    // Editing the text after a card was shown starts a new request.
                    if let card = state.ask, !card.phase.isSending, state.text != card.request.original { state.ask = nil }
                }
            if state.recording {
                HStack(spacing: 12) {
                    ListeningOrb(level: state.voiceLevel)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Circle().fill(.red).frame(width: 7, height: 7)
                            Text("Recording…").font(.headline)
                        }
                        Text(state.voiceStatus ?? "Say what you need, then pause.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Stop") { toggleVoice() }.controlSize(.small).help("Stop recording and use what Wren heard")
                }
                .transition(.opacity)
            } else if state.reviewingVoice {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.badge.checkmark").foregroundStyle(WrenTheme.accent)
                    Text("Transcribed on this Mac. Fix any wrong words, then press Return. Esc cancels.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Record again") { retryVoice() }.controlSize(.small).help("Discard this transcript and say the command again")
                }
            } else if let v = state.voiceStatus {
                Text(v).font(.caption).foregroundStyle(.secondary)
            }
            if let card = state.ask { AskCardView(card: card, aiAvailable: state.aiAvailable, act: askAction) }
            else if let reply = state.reply { replyView(reply) }
            HStack(spacing: 14) {
                if state.recording {
                    hint("esc", "Cancel")
                } else if let card = state.ask {
                    if let p = card.primary { hint("return", p.title(card)) }
                } else if case .proposal? = state.reply { hint("return", "Confirm") }
                else if state.reviewingVoice { hint("return", "Run") }
                else { hint("return", "Save") }
                if !state.recording { hint("esc", "Close") }
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
    var voiceEnabled = true
    var recording = false
    var voiceStatus: String?
    /// Input loudness 0…1 while recording (drives the animation).
    var voiceLevel: Float = 0
    /// Text the voice service last wrote into the field (to tell it apart from typing).
    var lastVoiceText = ""
    /// A spoken command is in the field, waiting for the user to check it and press Return.
    var reviewingVoice = false
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
                    Text(Self.planNote(card.request)).font(.caption).foregroundStyle(.secondary)
                    HStack { Button("Ask ChatGPT") { act(.run(.chatgpt)) }; Button("Save as a note instead") { act(.saveAsNote) } }.controlSize(.small)
                }
            case .sending:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(card.destination == .local ? "Asking the local model…" : "Running in ChatGPT…").font(.caption) }
                if !card.streamed.isEmpty { answerText(card.streamed) }
                if card.recordID != nil { Button("Open in Wren") { act(.openAnswer) }.controlSize(.small) }
            case let .answered(text, source, _):
                answerText(text)
                Text(source).font(.caption2).foregroundStyle(.tertiary)
                HStack { Button("Copy answer") { act(.copyAnswer) }; Button("Open result") { act(.openAnswer) } }.controlSize(.small)
            case let .partial(text, source, _, message):
                answerText(text)
                Text(message).font(.caption).foregroundStyle(.orange)
                Text(source).font(.caption2).foregroundStyle(.tertiary)
                HStack { Button("Try again") { act(.run(card.destination == .choose ? .chatgpt : card.destination)) }; Button("Copy answer") { act(.copyAnswer) }; Button("Open result") { act(.openAnswer) } }.controlSize(.small)
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
            case let .unsupported(m):
                Text(m).font(.caption).foregroundStyle(.orange)
                HStack { Button("Run with standard settings") { act(.runStandard) }; Button("Open result") { act(.openAnswer) } }.controlSize(.small)
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

    /// What will be asked of ChatGPT, in plain words, before anything is sent.
    static func planNote(_ r: AIRequest) -> String {
        var parts = ["Sends only this text, using your ChatGPT plan."]
        if r.wantsHighEffort { parts.append("Asks for high reasoning effort.") }
        if r.wantsWebSearch { parts.append("Offers ChatGPT web search for sources (if your account allows it; Wren will say whether it ran).") }
        return parts.joined(separator: " ")
    }

    func answerText(_ t: String) -> some View {
        ScrollView { Text(t).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            .frame(maxHeight: 260)
    }
}


/// Recording indicator: soft, overlapping coloured rings that swell with your voice.
struct ListeningOrb: View {
    var level: Float
    @Environment(\.colorScheme) private var scheme
    static let colors: [Color] = [.cyan, .purple, .pink]

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in ring(i, t) }
                Circle().fill(scheme == .dark ? Color.white.opacity(0.9) : Color.purple.opacity(0.85)).frame(width: dot, height: dot).blur(radius: 1)
            }
        }
        .accessibilityLabel("Recording")
    }

    var l: CGFloat { CGFloat(level) }
    var dot: CGFloat { 8 + l * 6 }

    func ring(_ i: Int, _ t: Double) -> some View {
        let phase: Double = t * (1.4 + Double(i) * 0.5) + Double(i) * 2.1
        let wobble: CGFloat = CGFloat(sin(phase)) * (0.05 + l * 0.12)
        let scale: CGFloat = 0.62 + l * 0.42 + wobble
        let drift: CGFloat = 2 + l * 5
        let gradient = RadialGradient(colors: [Self.colors[i].opacity(0.85), Color.clear], center: .center, startRadius: 2, endRadius: 24)
        return Circle().fill(gradient)
            .scaleEffect(scale)
            .offset(x: CGFloat(cos(phase)) * drift, y: CGFloat(sin(phase * 1.3)) * drift)
            .blendMode(scheme == .dark ? .plusLighter : .multiply)
    }
}
