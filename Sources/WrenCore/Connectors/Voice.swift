import Foundation

public enum VoicePermission: String, Sendable { case notDetermined, granted, denied, restricted }

public struct Transcript: Equatable, Sendable {
    public var text: String
    /// 0…1 when the engine reports it.
    public var confidence: Double?
    public var onDevice: Bool
    public init(text: String, confidence: Double?, onDevice: Bool) { self.text = text; self.confidence = confidence; self.onDevice = onDevice }
}

public enum VoiceError: Error, Equatable, LocalizedError {
    case microphoneDenied, speechDenied, noMicrophone, onDeviceUnavailable(String), tooShort, nothingHeard, recordingFailed(String), transcriptionFailed(String)
    public var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Wren isn't allowed to use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
        case .speechDenied: "Speech Recognition is turned off for Wren in System Settings › Privacy & Security › Speech Recognition."
        case .noMicrophone: "No microphone is available."
        case let .onDeviceUnavailable(l): "On-device speech recognition isn't available for \(l) on this Mac. Wren won't send audio to a server."
        case .tooShort: "That was too short. Try again and say the whole request."
        case .nothingHeard: "Wren didn't catch any words. Try again a little closer to the microphone."
        case let .recordingFailed(m): "Recording failed: \(m)"
        case let .transcriptionFailed(m): "Transcription failed: \(m)"
        }
    }
}

/// System pieces, injected so the lifecycle is testable.
@MainActor
public protocol VoicePermissions: AnyObject {
    var microphone: VoicePermission { get }
    var speech: VoicePermission { get }
    func requestMicrophone() async -> Bool
    func requestSpeech() async -> Bool
}

// MARK: - Voice commands: "Hey Wren" and the voice shortcut, one pipeline

/// Finds "Hey Wren" at the start of an utterance in a running transcript. Speech recognisers write
/// the name several ways, so a few close spellings count; anything else doesn't.
public enum WakeWord {
    public static let phrase = "Hey Wren"
    static let pattern = #"(?:^|[\s,.!?])(?:hey|hay|hi|okay|ok)[\s,]+(?:wren|wrenn|ren|renn|wren's|wrens|rhen)(?=$|[\s,.!?:])"#

    /// The text after the wake phrase (possibly empty), or nil when the phrase isn't there.
    public static func command(in transcript: String) -> String? {
        let t = transcript
        guard let r = t.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(t[r.upperBound...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.:!?")))
    }
}

/// Decides when a spoken command has ended: a pause after speech, no speech at all, or a time cap.
public struct CommandEndpointer: Sendable, Equatable {
    public enum End: Equatable, Sendable { case pause, nothingSaid, timeLimit }
    public var pauseAfterSpeech: TimeInterval = 1.6
    public var waitForSpeech: TimeInterval = 7
    public var maxDuration: TimeInterval = 20
    var started: Date
    var lastChange: Date?
    var text = ""

    public init(start: Date) { started = start }

    public mutating func transcript(_ t: String, at now: Date) {
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != text { text = trimmed; lastChange = now }
    }

    public func check(_ now: Date) -> End? {
        if now.timeIntervalSince(started) >= maxDuration { return .timeLimit }
        guard !text.isEmpty, let last = lastChange else {
            return now.timeIntervalSince(started) >= waitForSpeech ? .nothingSaid : nil
        }
        return now.timeIntervalSince(last) >= pauseAfterSpeech ? .pause : nil
    }
}

/// Decides, from input loudness alone, when someone is speaking. While Wren waits for "Hey Wren",
/// speech recognition runs only between `open` and `close`; silence and background noise are never
/// transcribed. Adapts to the room's noise floor. Pure, so it's tested without a microphone.
public struct VoiceActivityGate: Sendable, Equatable {
    public enum Event: Equatable, Sendable { case open, close }
    /// How far above the noise floor counts as speech (dB).
    public var margin: Float = 10
    /// Never treat anything quieter than this as speech (dBFS).
    public var absoluteMinimum: Float = -52
    /// Consecutive loud buffers (~23 ms each) before opening.
    public var loudBuffersToOpen = 3
    /// Quiet time before closing.
    public var closeAfter: TimeInterval = 2.5
    /// A single burst is closed after this long (the recogniser has a time limit).
    public var maxOpen: TimeInterval = 50
    public private(set) var noiseFloor: Float = -60
    public private(set) var isOpen = false
    var loudRun = 0
    var lastLoud: TimeInterval = 0
    var openedAt: TimeInterval = 0

    public init() {}

    public mutating func feed(level db: Float, at t: TimeInterval) -> Event? {
        let threshold = max(absoluteMinimum, noiseFloor + margin)
        let loud = db >= threshold
        if !isOpen {
            // Track the room: fall quickly to quieter levels, rise slowly.
            noiseFloor = db < noiseFloor ? noiseFloor * 0.7 + db * 0.3 : noiseFloor * 0.995 + db * 0.005
            noiseFloor = min(-25, max(-90, noiseFloor))
            loudRun = loud ? loudRun + 1 : 0
            guard loudRun >= loudBuffersToOpen else { return nil }
            isOpen = true; openedAt = t; lastLoud = t; loudRun = 0
            return .open
        }
        // Keep learning slowly while open, so a steady noise (fan, hum) can't hold the gate open.
        noiseFloor = min(-25, max(-90, noiseFloor * 0.998 + db * 0.002))
        // Hysteresis: once open, quieter speech still counts.
        if db >= max(absoluteMinimum, noiseFloor + margin) - margin * 0.4 { lastLoud = t }
        if t - lastLoud >= closeAfter || t - openedAt >= maxOpen { isOpen = false; return .close }
        return nil
    }
}

/// Live, on-device speech from the microphone (AVAudioEngine + Apple Speech in the app; a fake in
/// tests). Each `start()` begins a fresh transcript.
@MainActor
public protocol SpeechStreaming: AnyObject {
    var onTranscript: ((String) -> Void)? { get set }
    /// The recogniser stopped on its own (time limit, silence or error). nil error: just ended.
    var onEnded: ((VoiceError?) -> Void)? { get set }
    var isRunning: Bool { get }
    /// True while only waiting for "Hey Wren": recognise speech only while someone is talking.
    /// False while capturing a command: recognise continuously until stopped.
    var wakeListening: Bool { get set }
    func start() throws
    func stop()
}

/// One voice service with two ways in: saying "Hey Wren" (opt-in, listening in the background) and
/// the voice shortcut. Either way the same capture, end-of-speech detection and single hand-off run.
/// Only one command is captured at a time, and nothing is recorded once a command has ended.
@MainActor
public final class VoiceSession {
    public enum Trigger: String, Equatable, Sendable { case wakeWord, shortcut }
    public enum Phase: Equatable, Sendable {
        case off
        /// Listening for "Hey Wren" only.
        case listening
        case capturing(Trigger)
        /// The command was handed off; waiting for the app to finish with it.
        case handling
        case failed(VoiceError)
    }

    let stream: SpeechStreaming
    let permissions: VoicePermissions
    let now: () -> Date
    public private(set) var phase: Phase = .off { didSet { if phase != oldValue { onPhase?(phase) } } }
    public private(set) var wakeWordEnabled = false
    /// Listening is paused (screen locked or asleep); it resumes by itself afterwards.
    public private(set) var suspended = false
    public private(set) var liveCommand = ""
    var endpointer: CommandEndpointer?

    public var onPhase: ((Phase) -> Void)?
    /// Live text of the command being spoken (without the wake phrase).
    public var onLiveCommand: ((String) -> Void)?
    /// The finished command, exactly once per capture. Call `finishedHandling()` afterwards.
    public var onCommand: ((String, Trigger) -> Void)?
    public var onEndedWithoutCommand: ((CommandEndpointer.End) -> Void)?

    public init(stream: SpeechStreaming, permissions: VoicePermissions, now: @escaping () -> Date = { Date() }) {
        self.stream = stream; self.permissions = permissions; self.now = now
        stream.onTranscript = { [weak self] t in self?.heard(t) }
        stream.onEnded = { [weak self] e in self?.streamEnded(e) }
    }

    /// Asks for Microphone and Speech Recognition if needed. False with a reason when refused.
    func ensurePermissions() async -> VoiceError? {
        if permissions.microphone == .notDetermined { _ = await permissions.requestMicrophone() }
        guard permissions.microphone == .granted else { return .microphoneDenied }
        if permissions.speech == .notDetermined { _ = await permissions.requestSpeech() }
        guard permissions.speech == .granted else { return .speechDenied }
        return nil
    }

    /// Turns "Hey Wren" on or off. Off stops the microphone unless a command is being captured.
    @discardableResult
    public func setWakeWord(_ on: Bool) async -> VoiceError? {
        wakeWordEnabled = on
        if !on {
            if phase == .listening { stream.stop(); phase = .off }
            return nil
        }
        if let e = await ensurePermissions() { wakeWordEnabled = false; phase = .failed(e); return e }
        if (phase == .off || isFailed) && !suspended { return startListening() }
        return nil
    }

    /// Screen locked or display asleep: the microphone is released. A command already being
    /// captured is left to finish.
    public func suspend() {
        suspended = true
        if phase == .listening { stream.stop(); phase = .off }
    }

    /// Screen unlocked or awake again: back to listening if "Hey Wren" is on.
    public func resumeIfEnabled() {
        guard suspended else { return }
        suspended = false
        if wakeWordEnabled, phase == .off || isFailed { _ = startListening() }
    }

    var isFailed: Bool { if case .failed = phase { true } else { false } }

    func startListening() -> VoiceError? {
        stream.wakeListening = true
        do { try stream.start() } catch {
            let e = (error as? VoiceError) ?? .recordingFailed(error.localizedDescription)
            phase = .failed(e); return e
        }
        liveCommand = ""; endpointer = nil
        phase = .listening
        return nil
    }

    /// The voice shortcut: starts capturing a command now; pressed again while capturing, it ends it.
    @discardableResult
    public func shortcut() async -> VoiceError? {
        switch phase {
        case .capturing: finish(.pause); return nil
        case .handling: return nil
        default: break
        }
        if let e = await ensurePermissions() { phase = .failed(e); return e }
        stream.stop()
        stream.wakeListening = false
        do { try stream.start() } catch {
            let e = (error as? VoiceError) ?? .recordingFailed(error.localizedDescription)
            phase = .failed(e); return e
        }
        beginCapture(.shortcut, initial: "")
        return nil
    }

    func beginCapture(_ t: Trigger, initial: String) {
        // From here on, keep recognising (don't stop at a pause in the gate; the endpointer decides).
        stream.wakeListening = false
        liveCommand = initial
        endpointer = CommandEndpointer(start: now())
        endpointer?.transcript(initial, at: now())
        phase = .capturing(t)
        onLiveCommand?(initial)
    }

    func heard(_ transcript: String) {
        switch phase {
        case .listening:
            if let cmd = WakeWord.command(in: transcript) { beginCapture(.wakeWord, initial: cmd) }
        case let .capturing(t):
            let cmd = t == .wakeWord ? (WakeWord.command(in: transcript) ?? liveCommand) : transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            liveCommand = cmd
            endpointer?.transcript(cmd, at: now())
            onLiveCommand?(cmd)
        default: break
        }
    }

    /// Call about ten times a second while capturing.
    public func tick() {
        guard case .capturing = phase, let end = endpointer?.check(now()) else { return }
        finish(end)
    }

    func finish(_ end: CommandEndpointer.End) {
        guard case let .capturing(trigger) = phase else { return }
        stream.stop()   // nothing more is recorded once the command has ended
        endpointer = nil
        let text = liveCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            onEndedWithoutCommand?(end == .timeLimit ? .timeLimit : .nothingSaid)
            resume()
            return
        }
        phase = .handling
        onCommand?(text, trigger)
    }

    /// The app has shown the result; go back to listening (if "Hey Wren" is on) or off.
    public func finishedHandling() {
        guard phase == .handling else { return }
        resume()
    }

    /// Ends the command being captured now, as if the speaker had paused.
    public func stopCapturing() { finish(.pause) }

    /// Escape or the Cancel button: drops the command being captured.
    public func cancel() {
        switch phase {
        case .capturing, .handling:
            stream.stop(); endpointer = nil; liveCommand = ""
            resume()
        default: break
        }
    }

    func resume() {
        liveCommand = ""
        if wakeWordEnabled && !suspended { _ = startListening() } else { stream.stop(); phase = .off }
    }

    func streamEnded(_ error: VoiceError?) {
        switch phase {
        case .listening:
            // The recogniser has a time limit; keep listening with a fresh one unless it failed.
            if let error { phase = .failed(error) } else { _ = startListening() }
        case .capturing:
            if let error { stream.stop(); phase = .failed(error) } else { finish(.pause) }
        default: break
        }
    }

    /// Quit or disable: microphone off, nothing pending.
    public func shutdown() {
        wakeWordEnabled = false
        stream.stop(); endpointer = nil; liveCommand = ""
        phase = .off
    }
}
