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

/// The audio thread's side of `LiveSpeechStream`: loudness, the voice-activity gate, a short
/// pre-roll so the start of "Hey Wren" isn't cut off, and the request buffers are fed to. Locked,
/// because the tap runs on Core Audio's thread.
final class AudioTapState: @unchecked Sendable {
    private let lock = NSLock()
    private var gate = VoiceActivityGate()
    private var gated = true
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var preroll: [AVAudioPCMBuffer] = []
    private var prerollFrames: AVAudioFrameCount = 0
    private var prerollLimit: AVAudioFrameCount = 19_200
    private var lastLevelSent: TimeInterval = 0
    private let started = Date()

    func reset(gated: Bool, sampleRate: Double) {
        lock.withLock {
            gate = VoiceActivityGate(); self.gated = gated; request = nil; preroll = []; prerollFrames = 0
            prerollLimit = AVAudioFrameCount(sampleRate * 0.8)
        }
    }
    func setGated(_ on: Bool) { lock.withLock { gated = on } }
    func attach(_ r: SFSpeechAudioBufferRecognitionRequest) {
        lock.withLock { preroll.forEach(r.append); preroll = []; prerollFrames = 0; request = r }
    }
    func detach() -> SFSpeechAudioBufferRecognitionRequest? { lock.withLock { defer { request = nil }; return request } }

    struct Result { var event: VoiceActivityGate.Event?; var level: Float?; var db: Float }

    /// Called for every microphone buffer.
    func process(_ buffer: AVAudioPCMBuffer) -> Result {
        let db = Self.level(buffer)
        let t = Date().timeIntervalSince(started)
        return lock.withLock {
            var event: VoiceActivityGate.Event?
            let e = gate.feed(level: db, at: t)
            // While capturing a command the gate never closes; only idle listening is gated.
            if gated { event = e }
            if let request { request.append(buffer) }
            else if let copy = Self.copy(buffer) {
                preroll.append(copy); prerollFrames += copy.frameLength
                while prerollFrames > prerollLimit, let first = preroll.first { prerollFrames -= first.frameLength; preroll.removeFirst() }
            }
            var level: Float?
            if t - lastLevelSent >= 0.05 { lastLevelSent = t; level = min(1, max(0, (db + 60) / 50)) }
            return Result(event: event, level: level, db: db)
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

    static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let src = b.floatChannelData, let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength),
              let dst = out.floatChannelData else { return nil }
        out.frameLength = b.frameLength
        for c in 0..<Int(b.format.channelCount) { dst[c].update(from: src[c], count: Int(b.frameLength)) }
        return out
    }
}

/// Live microphone audio into Apple's speech recogniser, on-device only (`requiresOnDeviceRecognition`):
/// audio never leaves the Mac, and Wren refuses to run if the on-device model isn't installed.
///
/// Two modes. Capturing a command (`wakeListening == false`): recognition runs from `start()` until
/// `stop()`. Waiting for "Hey Wren" (`wakeListening == true`): the microphone is open (macOS shows its
/// indicator, which no app can avoid while listening for a phrase), but only loudness is measured;
/// speech recognition starts when someone speaks and stops after a few seconds of quiet. Silence and
/// background noise are never transcribed, and nothing is stored.
@MainActor
final class LiveSpeechStream: SpeechStreaming {
    var onTranscript: ((String) -> Void)?
    var onEnded: ((VoiceError?) -> Void)?
    /// Input loudness 0…1, about 20 times a second (for the listening animation).
    var onLevel: ((Float) -> Void)?
    private(set) var isRunning = false
    var wakeListening = false { didSet { tap.setGated(wakeListening) } }
    private let engine = AVAudioEngine()
    private let tap = AudioTapState()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var burst = 0
    private var startedAt = Date.distantPast
    private var configObserver: NSObjectProtocol?
    /// Only touch the input node after it was set up: merely reading `inputNode` opens the audio
    /// input (and can make macOS ask for the microphone), which must never happen just by quitting.
    private var tapInstalled = false
    var locale: Locale = .current
    /// For diagnostics: how many recognition bursts ran while waiting for "Hey Wren".
    private(set) var gatedBursts = 0

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
        recognizer = r
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.noMicrophone }
        tap.reset(gated: wakeListening, sampleRate: format.sampleRate)
        generation += 1
        let gen = generation
        let state = tap
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let r = state.process(buffer)
            guard r.event != nil || r.level != nil else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    if let l = r.level { self.onLevel?(l) }
                    switch r.event {
                    case .open?: self.beginRecognition()
                    case .close?: self.endBurst()
                    case nil: break
                    }
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
        // Capturing a command: recognise right away. Waiting for the wake phrase: wait for speech.
        if !wakeListening { beginRecognition() }
        // A new microphone, AirPods connecting, or a sample-rate change invalidates the engine.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.isRunning else { return }; self.finishTask(nil) }
        }
    }

    /// Starts one recognition request (fed the pre-roll first).
    private func beginRecognition() {
        guard isRunning, task == nil, let r = recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        req.contextualStrings = ["Hey Wren", "Wren", "remind me", "snooze", "GPT", "ChatGPT"]
        burst += 1
        if wakeListening { gatedBursts += 1 }
        let gen = generation, b = burst
        task = r.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failure = error.map(Self.classify) ?? nil
            let ended = error != nil || final
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation, b == self.burst else { return }
                    if let text, !text.isEmpty { self.onTranscript?(text) }
                    guard ended else { return }
                    if self.wakeListening && failure == nil {
                        // A burst of speech ended without the wake phrase: keep the microphone, drop the recogniser.
                        self.task = nil
                    } else {
                        self.finishTask(failure)
                    }
                }
            }
        }
        tap.attach(req)
    }

    /// The speaker went quiet while waiting for the wake phrase: finish this burst's recognition.
    private func endBurst() {
        guard wakeListening else { return }
        tap.detach()?.endAudio()
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
