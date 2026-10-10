import SwiftUI

/// The primary interface: one line, Enter to save, Escape to close.
struct CaptureView: View {
    @Bindable var state: CaptureState
    var submit: (String) -> Void
    var cancel: () -> Void
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
            }
            TextField("What do you need to do?", text: $state.text)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($focused)
                .onSubmit { submit(state.text) }
            HStack(spacing: 14) {
                hint("return", "Save")
                hint("esc", "Close")
                Spacer()
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
}
