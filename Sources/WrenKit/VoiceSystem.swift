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

/// Live microphone audio into Apple's speech recogniser, on-device only (`requiresOnDeviceRecognition`):
/// audio never leaves the Mac, and Wren refuses to run if the on-device model isn't installed.
/// Each `start()` is a fresh recognition; `stop()` turns the microphone off.
@MainActor
final class LiveSpeechStream: SpeechStreaming {
    var onTranscript: ((String) -> Void)?
    var onEnded: ((VoiceError?) -> Void)?
    private(set) var isRunning = false
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var startedAt = Date.distantPast
    private var configObserver: NSObjectProtocol?
    /// Only touch the input node after it was set up: merely reading `inputNode` opens the audio
    /// input (and can make macOS ask for the microphone), which must never happen just by quitting.
    private var tapInstalled = false
    var locale: Locale = .current

    static func availability(locale: Locale = .current) -> String? {
        guard let r = SFSpeechRecognizer(locale: locale) else { return "Speech recognition doesn't support \(locale.identifier)." }
        guard r.supportsOnDeviceRecognition else {
            return "On-device recognition isn't installed for \(locale.identifier). Turn on Dictation in System Settings › Keyboard once so macOS downloads it."
        }
        return r.isAvailable ? nil : "Speech recognition is temporarily unavailable."
    }

    func start() throws {
        stop()
        guard let r = SFSpeechRecognizer(locale: locale), r.supportsOnDeviceRecognition else { throw VoiceError.onDeviceUnavailable(locale.identifier) }
        guard AVCaptureDevice.default(for: .audio) != nil else { throw VoiceError.noMicrophone }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        req.contextualStrings = ["Hey Wren", "Wren", "remind me", "snooze"]
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.noMicrophone }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }
        tapInstalled = true
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw VoiceError.recordingFailed(error.localizedDescription)
        }
        generation += 1
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
        request = req
        startedAt = Date()
        isRunning = true
        // A new microphone, AirPods connecting, or a sample-rate change invalidates the engine.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.isRunning else { return }; self.finishTask(nil) }
        }
    }

    /// "No speech" and cancellations are normal ends, not failures.
    nonisolated static func classify(_ error: Error) -> VoiceError? {
        let ns = error as NSError
        if ns.domain == "kAFAssistantErrorDomain", [203, 209, 216, 1101, 1107, 1110].contains(ns.code) { return nil }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSUserCancelledError { return nil }
        return .recordingFailed(ns.localizedDescription)
    }

    private func finishTask(_ failure: VoiceError?) {
        let quick = Date().timeIntervalSince(startedAt) < 1
        teardown()
        // Avoid a tight restart loop when the recogniser ends immediately.
        if quick && failure == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in MainActor.assumeIsolated { self?.onEnded?(nil) } }
        } else {
            onEnded?(failure)
        }
    }

    func stop() {
        generation += 1
        teardown()
    }

    private func teardown() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
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
    /// "Hey Wren" is on.
    var wakeWord: Bool = false
    /// The live session's phase, set by the app.
    var phase: VoiceSession.Phase = .off
    init(permissions: SystemVoicePermissions, enabled: Bool) { self.permissions = permissions; self.enabled = enabled }

    var state: ConnectorState {
        guard enabled || wakeWord else { return .available }
        if case let .failed(e) = phase { return e == .microphoneDenied || e == .speechDenied ? .missingPermissions(e.localizedDescription) : .temporarilyUnavailable(e.localizedDescription) }
        if !permissions.hasMicrophone { return .temporarilyUnavailable("No microphone found.") }
        if permissions.microphone == .denied || permissions.microphone == .restricted { return .missingPermissions(VoiceError.microphoneDenied.localizedDescription) }
        if permissions.speech == .denied || permissions.speech == .restricted { return .missingPermissions(VoiceError.speechDenied.localizedDescription) }
        if let problem = LiveSpeechStream.availability() { return .setupRequired(problem) }
        if permissions.microphone == .notDetermined || permissions.speech == .notDetermined {
            return .partiallyConnected("Ready. macOS will ask for Microphone and Speech Recognition the first time Wren listens.")
        }
        let mode = phase == .listening ? "listening for “Hey Wren”" : (wakeWord ? "“Hey Wren” on" : "shortcut only")
        return .connected(account: "On-device, \(Locale.current.identifier), \(mode)")
    }
    func refresh() async {}
    func disconnect() async { enabled = false; wakeWord = false }
}
