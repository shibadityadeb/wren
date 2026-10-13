import AVFoundation
import Speech
import WrenCore

/// Microphone + Speech Recognition permissions. Asked only when you first record.
@MainActor
final class SystemVoicePermissions: VoicePermissions {
    var microphone: VoicePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }
    var speech: VoicePermission {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }
    func requestMicrophone() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }
    func requestSpeech() async -> Bool {
        await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }
    var hasMicrophone: Bool { AVCaptureDevice.default(for: .audio) != nil }
}

/// The audio thread's side of `LiveSpeechStream`: loudness for the recording indicator, and the
/// recognition request buffers are fed to. Locked, because the tap runs on Core Audio's thread.
/// Audio is passed straight to the on-device recogniser and never kept or written anywhere.
final class AudioTapState: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var lastLevelSent: TimeInterval = 0
    private let started = Date()

    func attach(_ r: SFSpeechAudioBufferRecognitionRequest) { lock.withLock { request = r } }
    func detach() -> SFSpeechAudioBufferRecognitionRequest? { lock.withLock { defer { request = nil }; return request } }

    /// Called for every microphone buffer. Returns a loudness level about 20 times a second.
    func process(_ buffer: AVAudioPCMBuffer) -> Float? {
        let db = Self.level(buffer)
        let t = Date().timeIntervalSince(started)
        return lock.withLock {
            request?.append(buffer)
            guard t - lastLevelSent >= 0.05 else { return nil }
            lastLevelSent = t
            return min(1, max(0, (db + 60) / 50))
        }
    }

    static func level(_ b: AVAudioPCMBuffer) -> Float {
        guard let ch = b.floatChannelData, b.frameLength > 0 else { return -90 }
        let n = Int(b.frameLength)
        var sum: Float = 0
        for i in 0..<n { let v = ch[0][i]; sum += v * v }
        let rms = (sum / Float(n)).squareRoot()
        return rms > 0 ? max(-90, 20 * log10(rms)) : -90
    }
}

/// Whether this Mac can transcribe speech locally for the current language. The speech model is
/// Apple's on-device model, installed and updated by macOS (System Settings › Keyboard › Dictation);
/// Wren doesn't download, bundle or delete a model of its own and never uses server recognition.
enum LocalSpeechModel {
    enum Status: Equatable {
        case ready(String)
        case notInstalled(String)
        case unsupportedLanguage(String)
        case temporarilyUnavailable

        var label: String {
            switch self {
            case let .ready(l): "Installed: Apple on-device speech (\(l))"
            case let .notInstalled(l): "Not installed for \(l)"
            case let .unsupportedLanguage(l): "No on-device model for \(l)"
            case .temporarilyUnavailable: "Temporarily unavailable"
            }
        }
        var isReady: Bool { if case .ready = self { true } else { false } }
    }

    static func status(locale: Locale = .current) -> Status {
        let l = locale.identifier
        guard let r = SFSpeechRecognizer(locale: locale) else { return .unsupportedLanguage(l) }
        guard r.supportsOnDeviceRecognition else { return .notInstalled(l) }
        return r.isAvailable ? .ready(l) : .temporarilyUnavailable
    }

    static let dictationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
}

/// Live microphone audio into Apple's speech recogniser, on-device only (`requiresOnDeviceRecognition`):
/// audio never leaves the Mac, and Wren refuses to run if the on-device model isn't installed.
/// Recognition runs from `start()` until `stop()`; the microphone is closed at every other time.
@MainActor
final class LiveSpeechStream: SpeechStreaming {
    var onTranscript: ((String) -> Void)?
    var onEnded: ((VoiceError?) -> Void)?
    /// Input loudness 0…1, about 20 times a second (for the recording indicator).
    var onLevel: ((Float) -> Void)?
    private(set) var isRunning = false
    /// Replaced on every start: after a device or sample-rate change the old engine keeps a stale
    /// input format, and installing a tap with it raises an Objective-C exception that ends the app.
    private var engine = AVAudioEngine()
    private let tap = AudioTapState()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var startedAt = Date.distantPast
    private var configObserver: NSObjectProtocol?
    /// Only touch the input node after it was set up: merely reading `inputNode` opens the audio
    /// input (and can make macOS ask for the microphone), which must never happen just by quitting.
    private var tapInstalled = false
    var locale: Locale = .current

    static func availability(locale: Locale = .current) -> String? {
        switch LocalSpeechModel.status(locale: locale) {
        case .ready: return nil
        case .unsupportedLanguage: return "Speech recognition doesn't support \(locale.identifier)."
        case .notInstalled:
            return "On-device recognition isn't installed for \(locale.identifier). Turn on Dictation in System Settings › Keyboard once so macOS downloads it."
        case .temporarilyUnavailable: return "Speech recognition is temporarily unavailable."
        }
    }

    func start() throws {
        stop()
        guard let r = SFSpeechRecognizer(locale: locale), r.supportsOnDeviceRecognition else { throw VoiceError.onDeviceUnavailable(locale.identifier) }
        guard AVCaptureDevice.default(for: .audio) != nil else { throw VoiceError.noMicrophone }
        recognizer = r
        engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.noMicrophone }
        // The tap must match the hardware rate; a mismatch is an exception, not a Swift error.
        guard input.inputFormat(forBus: 0).sampleRate == format.sampleRate else {
            throw VoiceError.recordingFailed("The microphone changed. Try again in a moment.")
        }
        generation += 1
        let gen = generation
        let state = tap
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let level = state.process(buffer) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    self.onLevel?(level)
                }
            }
        }
        tapInstalled = true
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw VoiceError.recordingFailed(error.localizedDescription)
        }
        startedAt = Date()
        isRunning = true
        beginRecognition()
        // A new microphone, AirPods connecting, or a sample-rate change invalidates the engine.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.isRunning else { return }; self.finishTask(nil) }
        }
    }

    private func beginRecognition() {
        guard isRunning, task == nil, let r = recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        req.contextualStrings = ["Wren", "remind me", "snooze", "GPT", "ChatGPT", "Gmail"]
        let gen = generation
        task = r.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failure = error.map(Self.classify) ?? nil
            let ended = error != nil || final
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    if let text, !text.isEmpty { self.onTranscript?(text) }
                    if ended { self.finishTask(failure) }
                }
            }
        }
        tap.attach(req)
    }

    /// "No speech" and cancellations are normal ends, not failures.
    nonisolated static func classify(_ error: Error) -> VoiceError? {
        let ns = error as NSError
        if ns.domain == "kAFAssistantErrorDomain", [203, 209, 216, 1101, 1107, 1110].contains(ns.code) { return nil }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSUserCancelledError { return nil }
        return .recordingFailed(ns.localizedDescription)
    }

    private func finishTask(_ failure: VoiceError?) {
        teardown()
        onEnded?(failure)
    }

    func stop() {
        generation += 1
        teardown()
    }

    private func teardown() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        task?.cancel(); task = nil
        tap.detach()?.endAudio()
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        isRunning = false
    }
}

/// Voice connector state from real macOS permissions, on-device availability and the live session.
@MainActor
final class VoiceConnector: Connector {
    let descriptor = ConnectorCatalog.descriptor(.voice)
    let permissions: SystemVoicePermissions
    /// The voice shortcut is on.
    var enabled: Bool
    /// The live session's phase, set by the app.
    var phase: VoiceSession.Phase = .off
    init(permissions: SystemVoicePermissions, enabled: Bool) { self.permissions = permissions; self.enabled = enabled }

    var state: ConnectorState {
        guard enabled else { return .available }
        if case let .failed(e) = phase { return e == .microphoneDenied || e == .speechDenied ? .missingPermissions(e.localizedDescription) : .temporarilyUnavailable(e.localizedDescription) }
        if !permissions.hasMicrophone { return .temporarilyUnavailable("No microphone found.") }
        if permissions.microphone == .denied || permissions.microphone == .restricted { return .missingPermissions(VoiceError.microphoneDenied.localizedDescription) }
        if permissions.speech == .denied || permissions.speech == .restricted { return .missingPermissions(VoiceError.speechDenied.localizedDescription) }
        if let problem = LiveSpeechStream.availability() { return .setupRequired(problem) }
        if permissions.microphone == .notDetermined || permissions.speech == .notDetermined {
            return .partiallyConnected("Ready. macOS will ask for Microphone and Speech Recognition the first time Wren listens.")
        }
        let mode = isCapturing ? "recording a command" : "microphone off until you press the shortcut or Voice"
        return .connected(account: "On-device, \(Locale.current.identifier), \(mode)")
    }
    func refresh() async {}
    var isCapturing: Bool { if case .capturing = phase { true } else { false } }
    func disconnect() async { enabled = false }
}
