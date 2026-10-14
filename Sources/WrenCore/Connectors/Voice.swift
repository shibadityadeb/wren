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
    /// The transcript was fine but the command didn't succeed (the message says why).
    case commandFailed(String)
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
        case let .commandFailed(m): m
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

// MARK: - Voice commands: push-to-talk, one utterance at a time

/// Decides when a command started with the Voice *button* has ended: a pause after speech, no
/// speech at all, or a time cap. Push-to-talk ends on release instead (with only the time cap).
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

/// The recogniser's final text for one utterance. `confidence` is 0…1 when the engine reported it.
public struct FinalTranscript: Equatable, Sendable {
    public var text: String
    public var confidence: Double?
    public init(text: String, confidence: Double?) { self.text = text; self.confidence = confidence }
}

/// Whether a transcript is clear enough to run without asking. Wren never runs an empty or
/// clearly misheard utterance; a low-confidence one is shown for the user to confirm or fix.
public enum TranscriptAssessment: Equatable, Sendable {
    case run
    case confirm(String)
    case empty

    public static let lowConfidence = 0.35

    public static func assess(_ t: FinalTranscript) -> TranscriptAssessment {
        let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split { !$0.isLetter && !$0.isNumber }
        guard !words.isEmpty else { return .empty }
        if let c = t.confidence, c < lowConfidence { return .confirm("I'm not sure I heard that right. Check it, then press Return.") }
        // One short word ("um", "Wren") isn't a command.
        if words.count == 1, words[0].count <= 4 { return .confirm("That was very short. Is this what you meant?") }
        return .run
    }
}

/// Live, on-device speech from the microphone (AVAudioEngine + Apple Speech in the app; a fake in
/// tests). `start()` opens the microphone; `finish` closes it *at once* and then waits for the
/// recogniser's final text; `stop()` closes it and discards everything.
@MainActor
public protocol SpeechStreaming: AnyObject {
    /// Interim text while recording, exactly as the recogniser reports it.
    var onTranscript: ((String) -> Void)? { get set }
    /// The microphone stopped on its own while recording (device change, recogniser error).
    var onEnded: ((VoiceError?) -> Void)? { get set }
    /// The microphone is open.
    var isRunning: Bool { get }
    func start() throws
    func finish(_ completion: @escaping (Result<FinalTranscript, VoiceError>) -> Void)
    func stop()
}

/// One voice command, from key-down to result. Voice never runs in the background: the microphone
/// opens only on an explicit press (holding the push-to-talk shortcut, or the Voice button) and is
/// closed before transcription, processing and every end state.
///
///     idle → requestingPermission? → listening → transcribing → transcriptReady → processing
///          → completed | needsClarification | failed        (and cancelled from any step before processing)
@MainActor
public final class VoiceSession {
    /// How the user started this capture. Both are explicit, deliberate actions.
    public enum Trigger: String, Equatable, Sendable {
        /// Holding the push-to-talk shortcut: releasing it ends the recording.
        case hold
        /// The Voice button: click Stop, or pause, to end it.
        case button
    }
    public enum CancelReason: Equatable, Sendable {
        case byUser, nothingHeard, releasedBeforeRecording, screenLocked
        public var message: String {
            switch self {
            case .byUser: "Cancelled. Nothing was done."
            case .nothingHeard: "Didn't hear anything, so nothing was done."
            case .releasedBeforeRecording: "Microphone access is set. Hold the shortcut again and speak."
            case .screenLocked: "Recording stopped because the screen locked or the Mac went to sleep."
            }
        }
    }
    public enum Phase: Equatable, Sendable {
        case idle
        case requestingPermission
        case listening(Trigger)
        /// The microphone is closed; the recogniser is producing the final text.
        case transcribing
        case transcriptReady(String)
        case processing(String)
        case completed(String)
        case needsClarification(String)
        case failed(VoiceError)
        case cancelled(CancelReason)

        public var isCapturingPhase: Bool { if case .listening = self { true } else { false } }
        /// A command is between key-down and its result: a new press is ignored.
        public var isBusy: Bool {
            switch self {
            case .requestingPermission, .listening, .transcribing, .transcriptReady, .processing: true
            default: false
            }
        }
    }
    /// How the app's command pipeline ended, reported back with `finishProcessing`.
    public enum Outcome: Equatable, Sendable { case completed(String), needsClarification(String), failed(String) }

    let stream: SpeechStreaming
    let permissions: VoicePermissions
    let now: () -> Date
    public private(set) var phase: Phase = .idle { didSet { if phase != oldValue { onPhase?(phase) } } }
    public private(set) var liveText = ""
    /// Push-to-talk longest recording.
    public var maxHold: TimeInterval = 60
    var endpointer: CommandEndpointer?
    var startedAt: Date?
    /// When the microphone actually started recording this command (nil when it isn't recording).
    public var listeningSince: Date? { phase.isCapturingPhase ? startedAt : nil }
    /// Bumped by every start, cancel and shutdown so a late permission answer or a late final
    /// transcript from an abandoned utterance can't change anything.
    var generation = 0
    var releasedDuringPermission = false

    public var onPhase: ((Phase) -> Void)?
    public var onLiveText: ((String) -> Void)?
    /// Exactly once per utterance that produced words.
    public var onTranscript: ((String, TranscriptAssessment) -> Void)?

    public init(stream: SpeechStreaming, permissions: VoicePermissions, now: @escaping () -> Date = { Date() }) {
        self.stream = stream; self.permissions = permissions; self.now = now
        stream.onTranscript = { [weak self] t in self?.heard(t) }
        stream.onEnded = { [weak self] e in self?.streamEnded(e) }
    }

    public var isCapturing: Bool { phase.isCapturingPhase }
    public var isMicrophoneOpen: Bool { stream.isRunning }

    /// Key-down of the push-to-talk shortcut, or a click on Voice. A repeated key-down while
    /// holding, or any press while a command is still being transcribed or run, does nothing.
    /// A click on Voice while the button recording runs stops it.
    @discardableResult
    public func press(_ trigger: Trigger) async -> VoiceError? {
        if case let .listening(t) = phase {
            if t == .button && trigger == .button { release() }
            return nil
        }
        guard !phase.isBusy else { return nil }
        generation += 1
        let ticket = generation
        releasedDuringPermission = false
        if permissions.microphone == .notDetermined || permissions.speech == .notDetermined {
            phase = .requestingPermission
            if permissions.microphone == .notDetermined { _ = await permissions.requestMicrophone() }
            if permissions.microphone == .granted, permissions.speech == .notDetermined { _ = await permissions.requestSpeech() }
            guard ticket == generation else { return nil }   // cancelled or shut down meanwhile
        }
        if permissions.microphone != .granted { phase = .failed(.microphoneDenied); return .microphoneDenied }
        if permissions.speech != .granted { phase = .failed(.speechDenied); return .speechDenied }
        // Held, then released while macOS asked: don't start recording without the keys held.
        if trigger == .hold, releasedDuringPermission { phase = .cancelled(.releasedBeforeRecording); return nil }
        do { try stream.start() } catch {
            let e = (error as? VoiceError) ?? .recordingFailed(error.localizedDescription)
            stream.stop()
            phase = .failed(e); return e
        }
        liveText = ""
        startedAt = now()
        endpointer = trigger == .button ? CommandEndpointer(start: now()) : nil
        phase = .listening(trigger)
        onLiveText?("")
        return nil
    }

    /// Key-up of the shortcut (either key), or Stop: closes the microphone immediately, then
    /// produces the final transcript locally.
    public func release() {
        switch phase {
        case .requestingPermission: releasedDuringPermission = true
        case .listening: transcribe()
        default: break
        }
    }

    /// A push-to-talk press that ended almost at once (a tap, or a key-up macOS reported while the
    /// keys were still down): keep listening hands-free, ending on a pause, Stop or another press,
    /// instead of throwing the recording away. Only from a hold that's listening.
    public func continueHandsFree() {
        guard case .listening(.hold) = phase else { return }
        var e = CommandEndpointer(start: now())
        e.transcript(liveText, at: now())
        endpointer = e
        phase = .listening(.button)
    }

    func transcribe() {
        endpointer = nil
        let ticket = generation
        phase = .transcribing
        stream.finish { [weak self] result in
            guard let self, ticket == self.generation, self.phase == .transcribing else { return }
            switch result {
            case let .failure(e): self.phase = .failed(e)
            case let .success(t): self.transcribed(t)
            }
        }
    }

    func transcribed(_ t: FinalTranscript) {
        let assessment = TranscriptAssessment.assess(t)
        let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
        liveText = ""
        guard assessment != .empty else { phase = .cancelled(.nothingHeard); return }
        phase = .transcriptReady(text)
        onTranscript?(text, assessment)
    }

    func heard(_ transcript: String) {
        guard isCapturing else { return }
        liveText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        endpointer?.transcript(liveText, at: now())
        onLiveText?(liveText)
    }

    /// Call about ten times a second while listening: ends a button recording on a pause, and any
    /// recording at its time cap.
    public func tick() {
        guard case let .listening(trigger) = phase else { return }
        if trigger == .hold, let s = startedAt, now().timeIntervalSince(s) >= maxHold { release(); return }
        if let end = endpointer?.check(now()) {
            if end == .nothingSaid && liveText.isEmpty { cancel(.nothingHeard) } else { release() }
        }
    }

    /// The app started running the transcript (automatically, or after the user confirmed it).
    public func beginProcessing(_ text: String) {
        switch phase {
        case .transcriptReady, .idle, .completed, .needsClarification, .failed, .cancelled: phase = .processing(text)
        default: break
        }
    }

    /// The command pipeline's real result.
    public func finishProcessing(_ outcome: Outcome) {
        guard case .processing = phase else { return }
        switch outcome {
        case let .completed(m): phase = .completed(m)
        case let .needsClarification(q): phase = .needsClarification(q)
        case let .failed(m): phase = .failed(.commandFailed(m))
        }
    }

    /// Escape or Cancel: closes the microphone and drops the utterance. A command already being
    /// run isn't interrupted (it may have side effects); its result still arrives.
    public func cancel(_ reason: CancelReason = .byUser) {
        switch phase {
        case .requestingPermission, .listening, .transcribing, .transcriptReady:
            generation += 1
            stream.stop(); endpointer = nil; liveText = ""
            phase = .cancelled(reason)
        default: break
        }
    }

    /// The panel closed: back to idle (only between commands).
    public func reset() {
        guard !phase.isBusy else { return }
        phase = .idle
    }

    func streamEnded(_ error: VoiceError?) {
        guard isCapturing else { return }
        if let error { generation += 1; stream.stop(); endpointer = nil; phase = .failed(error) }
        else { transcribe() }
    }

    /// Quit: microphone off, nothing pending.
    public func shutdown() {
        generation += 1
        stream.stop(); endpointer = nil; liveText = ""
        phase = .idle
    }
}
