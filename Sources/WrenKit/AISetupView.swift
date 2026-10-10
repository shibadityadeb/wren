import SwiftUI
import WrenCore

/// Local AI setup: says exactly what's missing and offers the one next step.
struct AISetupView: View {
    @Bindable var model: AppModel
    @State private var customModel = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.route = .list } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(.borderless)
                Spacer()
                Text("Local AI").font(.headline)
                Spacer()
                Button { Task { await model.refreshAI() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Check again")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    status
                    Toggle("Use local AI", isOn: Binding(get: { model.settings.useModel }, set: { model.setUseModel($0) }))
                    nextStep
                    if let report = model.aiReport { diagnostics(report) }
                    explainer
                }
                .padding(14)
            }
        }
        .task { await model.refreshAI() }
    }

    var status: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.ai.title).font(.title3.weight(.semibold))
                if !model.ai.detail.isEmpty { Text(model.ai.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    var color: Color {
        switch model.ai {
        case .ready: WrenTheme.accent
        case .configured, .checking, .disabled: .secondary
        default: .orange
        }
    }

    @ViewBuilder var nextStep: some View {
        switch model.ai {
        case .disabled, .checking:
            EmptyView()
        case .notInstalled:
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Download and install Ollama (free, from ollama.com).\n2. Open it once.\n3. Come back here and press Check again.").font(.callout)
                HStack {
                    Link("Download Ollama", destination: URL(string: "https://ollama.com/download")!)
                    Button("Check again") { Task { await model.refreshAI() } }
                }
            }
        case .notRunning:
            HStack {
                if FileSystemOllamaProbe().appURL() != nil {
                    Button("Start Ollama") { model.startOllama() }
                } else {
                    Text("Start it from Terminal with `ollama serve`.").font(.callout)
                }
                Button("Check again") { Task { await model.refreshAI() } }
            }
        case .noChatModel:
            downloadSection
        case let .selectModel(models):
            modelPicker(models)
            downloadSection
        case let .configured(_, models), let .ready(_, models, _, _), let .unavailable(_, models, _):
            modelPicker(models)
            HStack {
                Button(model.aiTesting ? "Testing…" : "Test local AI") { Task { await model.testAI() } }
                    .disabled(model.aiTesting)
                if model.aiTesting { ProgressView().controlSize(.small) }
            }
            DisclosureGroup("Download another model") { downloadSection.padding(.top, 6) }.font(.callout)
        }
    }

    func modelPicker(_ models: [String]) -> some View {
        Picker("Model", selection: Binding(get: { model.selectedModel ?? "" }, set: { model.selectModel($0) })) {
            if model.selectedModel == nil || !models.contains(model.selectedModel ?? "") { Text("Choose…").tag("") }
            ForEach(models, id: \.self) { Text($0).tag($0) }
        }
    }

    @ViewBuilder var downloadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.download {
            case let .running(name, u):
                Text("Downloading \(name)…").font(.callout.weight(.medium))
                if let f = u?.fraction {
                    ProgressView(value: f)
                    Text("\(bytes(u!.completedBytes)) of \(bytes(u!.totalBytes)) · \(u!.status)").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text(u?.status ?? "Starting…").font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancel download") { model.cancelDownload() }.controlSize(.small)
            default:
                if case let .failed(name, reason) = model.download {
                    Label("\(name): \(reason)", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                if case let .cancelled(name) = model.download {
                    Text("Download of \(name) cancelled. Ollama keeps what was already downloaded, so trying again resumes.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(ModelSuggestion.recommended) { s in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name).font(.callout.monospaced())
                            Text("About \(bytes(s.approxBytes)). \(s.note)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(retryLabel(s.name)) { model.startDownload(s.name) }.controlSize(.small)
                            .disabled(!hasRoom(for: s.approxBytes))
                    }
                }
                HStack {
                    TextField("Other model, e.g. mistral:7b", text: $customModel).textFieldStyle(.roundedBorder).controlSize(.small)
                    Button("Download") { model.startDownload(customModel.trimmingCharacters(in: .whitespaces)) }
                        .controlSize(.small).disabled(!OllamaClient.isValidModelName(customModel.trimmingCharacters(in: .whitespaces)))
                }
                if let free = AIDiagnostics.freeDiskBytes() {
                    Text("Free disk space: \(bytes(free)). Models are stored by Ollama, not inside Wren.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    func retryLabel(_ name: String) -> String {
        if case let .failed(n, _) = model.download, n == name { return "Retry" }
        if case let .cancelled(n) = model.download, n == name { return "Resume" }
        return "Download"
    }

    /// Leave 2 GB spare after the model.
    func hasRoom(for size: Int64) -> Bool { (AIDiagnostics.freeDiskBytes() ?? .max) > size + 2_000_000_000 }

    func diagnostics(_ r: DiagnosticReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last test").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(r.steps) { st in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: st.outcome == .passed ? "checkmark.circle.fill" : st.outcome == .failed ? "xmark.circle.fill" : "minus.circle")
                        .foregroundStyle(st.outcome == .passed ? WrenTheme.accent : st.outcome == .failed ? .orange : .secondary)
                    Text(st.name).font(.callout)
                    Text(st.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    var explainer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How this works").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("""
            The model runs on your Mac through Ollama at 127.0.0.1. Nothing you type is sent to an external AI service. \
            Wren never downloads a model unless you press Download. Without a model, Wren still saves everything and reads dates with built-in rules. \
            With a model, it also writes cleaner titles, recognises goals, ideas and waiting items, and understands more ways of asking for changes. \
            Any change it proposes still needs your confirmation.
            """).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}

/// Compact AI state in the popover header. Click to open setup.
struct AIBadge: View {
    var model: AppModel
    var body: some View {
        Button { model.route = .aiSetup } label: {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(short).font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(model.ai.title)
    }
    var short: String {
        switch model.ai {
        case .ready: "Local AI"
        case .configured: "AI untested"
        case .checking: "…"
        case .disabled: "AI off"
        case .unavailable: "AI unavailable"
        default: "Set up AI"
        }
    }
    var color: Color {
        switch model.ai {
        case .ready: WrenTheme.accent
        case .configured, .checking, .disabled: .secondary
        default: .orange
        }
    }
}
