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

// MARK: - Voice commands: explicitly started, one at a time

/// Decides when a spoken command has ended: a pause after speech, no speech at all, or a time cap.
public struct CommandEndpointer: Sendable, Equatable {
    public enum End: Equatable, Sendable { case pause, nothingSaid, timeLimit }
    public var pauseAfterSpeech: TimeInterval = 1.6
    public var waitForSpeech: TimeInterval = 7
    public var maxDuration: TimeInterval = 30
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

/// Live, on-device speech from the microphone (AVAudioEngine + Apple Speech in the app; a fake in
/// tests). Each `start()` opens the microphone and begins a fresh transcript; `stop()` closes it.
@MainActor
public protocol SpeechStreaming: AnyObject {
    var onTranscript: ((String) -> Void)? { get set }
    /// The recogniser stopped on its own (time limit, silence or error). nil error: just ended.
    var onEnded: ((VoiceError?) -> Void)? { get set }
    var isRunning: Bool { get }
    func start() throws
    func stop()
}

/// Voice is a tool the user picks up, never an always-on listener. The microphone opens only when
/// the user presses the voice shortcut or clicks a Voice button, records one command, and closes
/// when the speaker pauses, presses Stop, cancels, or a time cap is reached. Nothing restarts it
/// afterwards: not a finished command, an error, a screen unlock, a relaunch or a permission change.
@MainActor
public final class VoiceSession {
    /// How the user started this capture. Both are explicit, deliberate actions.
    public enum Trigger: String, Equatable, Sendable { case shortcut, button }
    public enum Phase: Equatable, Sendable {
        /// Microphone closed.
        case off
        case capturing(Trigger)
        /// The command was handed off; waiting for the app to finish with it. Microphone closed.
        case handling
        case failed(VoiceError)
        public var isCapturingPhase: Bool { if case .capturing = self { true } else { false } }
    }

    let stream: SpeechStreaming
    let permissions: VoicePermissions
    let now: () -> Date
    public private(set) var phase: Phase = .off { didSet { if phase != oldValue { onPhase?(phase) } } }
    public private(set) var liveCommand = ""
    var endpointer: CommandEndpointer?
    /// Bumped by every start, cancel and shutdown: a permission prompt answered after the user
    /// cancelled (or quit) must not open the microphone.
    var activation = 0

    public var onPhase: ((Phase) -> Void)?
    /// Live text of the command being spoken.
    public var onLiveCommand: ((String) -> Void)?
    /// The finished command, exactly once per capture. Call `finishedHandling()` afterwards.
    public var onCommand: ((String, Trigger) -> Void)?
    public var onEndedWithoutCommand: ((CommandEndpointer.End) -> Void)?

    public init(stream: SpeechStreaming, permissions: VoicePermissions, now: @escaping () -> Date = { Date() }) {
        self.stream = stream; self.permissions = permissions; self.now = now
        stream.onTranscript = { [weak self] t in self?.heard(t) }
        stream.onEnded = { [weak self] e in self?.streamEnded(e) }
    }

    public var isCapturing: Bool { if case .capturing = phase { true } else { false } }

    /// Asks for Microphone and Speech Recognition if needed. A reason when refused.
    func ensurePermissions() async -> VoiceError? {
        if permissions.microphone == .notDetermined { _ = await permissions.requestMicrophone() }
        guard permissions.microphone == .granted else { return .microphoneDenied }
        if permissions.speech == .notDetermined { _ = await permissions.requestSpeech() }
        guard permissions.speech == .granted else { return .speechDenied }
        return nil
    }

    /// The voice shortcut or a Voice button. Starts capturing one command; pressed again while
    /// capturing, it ends the command (like Stop). While a command is being handled, or while a
    /// permission prompt is open, repeated presses do nothing: one recording at a time.
    @discardableResult
    public func activate(_ trigger: Trigger) async -> VoiceError? {
        switch phase {
        case .capturing: finish(.pause); return nil
        case .handling: return nil
        default: break
        }
        guard !requesting else { return nil }
        activation += 1
        let ticket = activation
        requesting = true
        let denied = await ensurePermissions()
        requesting = false
        // Cancelled, shut down or started again while macOS was asking: don't open the microphone.
        guard ticket == activation else { return nil }
        if let denied { phase = .failed(denied); return denied }
        do { try stream.start() } catch {
            let e = (error as? VoiceError) ?? .recordingFailed(error.localizedDescription)
            stream.stop()
            phase = .failed(e); return e
        }
        liveCommand = ""
        endpointer = CommandEndpointer(start: now())
        phase = .capturing(trigger)
        onLiveCommand?("")
        return nil
    }
    var requesting = false

    func heard(_ transcript: String) {
        guard case .capturing = phase else { return }
        let cmd = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        liveCommand = cmd
        endpointer?.transcript(cmd, at: now())
        onLiveCommand?(cmd)
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
        liveCommand = ""
        if text.isEmpty {
            phase = .off
            onEndedWithoutCommand?(end == .timeLimit ? .timeLimit : .nothingSaid)
            return
        }
        phase = .handling
        onCommand?(text, trigger)
    }

    /// The app has shown the result. The microphone stays off.
    public func finishedHandling() {
        guard phase == .handling else { return }
        phase = .off
    }

    /// Stop: ends the command being captured now, as if the speaker had paused.
    public func stopCapturing() { finish(.pause) }

    /// Escape or Cancel: drops the command being captured (or a pending permission prompt's start).
    public func cancel() {
        activation += 1
        switch phase {
        case .capturing, .handling, .failed:
            stream.stop(); endpointer = nil; liveCommand = ""
            phase = .off
        case .off: break
        }
    }

    func streamEnded(_ error: VoiceError?) {
        guard case .capturing = phase else { return }
        if let error { stream.stop(); endpointer = nil; liveCommand = ""; phase = .failed(error) } else { finish(.pause) }
    }

    /// Screen locked, Mac asleep, window closed with the panel, quit: microphone off, nothing pending.
    public func shutdown() {
        activation += 1
        stream.stop(); endpointer = nil; liveCommand = ""
        phase = .off
    }
}
