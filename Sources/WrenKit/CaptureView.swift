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
                    .help("Or hold the push-to-talk shortcut")
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
                    if case let .proposal(p)? = state.reply { confirm(p) } else { submit(state.text) }
                }
                .onChange(of: state.text) { if state.reply != nil && !state.busy { state.reply = nil } }
            if let v = state.voiceStatus {
                HStack(spacing: 6) {
                    if state.recording { Circle().fill(Color.red).frame(width: 8, height: 8) }
                    Text(v).font(.caption).foregroundStyle(state.recording ? Color.red : Color.secondary)
                }
            }
            if let reply = state.reply { replyView(reply) }
            HStack(spacing: 14) {
                if case .proposal? = state.reply { hint("return", "Confirm") } else { hint("return", "Save") }
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
}
