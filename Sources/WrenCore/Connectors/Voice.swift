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
        case .tooShort: "That was too short. Hold the shortcut while you speak."
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

@MainActor
public protocol AudioRecording: AnyObject {
    /// Starts recording to a temporary file.
    func start() throws
    /// Stops; returns the file and its duration.
    func stop() -> (URL, TimeInterval)?
    func cancel()
}

public protocol SpeechTranscribing: Sendable {
    /// Must transcribe on this device or throw.
    func transcribe(_ file: URL) async throws -> Transcript
}

/// Push-to-talk: begin() on key down, end() on key up. Never listens outside that.
@MainActor
public final class VoiceCapture {
    public enum State: Equatable {
        case idle
        case recording(since: Date)
        case transcribing
        /// Text ready for correction and submission.
        case review(Transcript)
        case failed(VoiceError)
    }

    public private(set) var state: State = .idle { didSet { onChange?(state) } }
    public var onChange: ((State) -> Void)?
    public var maxDuration: TimeInterval = 60
    public var minDuration: TimeInterval = 0.4
    let permissions: VoicePermissions
    let recorder: AudioRecording
    let transcriber: SpeechTranscribing
    let now: () -> Date
    var startedAt: Date?

    public init(permissions: VoicePermissions, recorder: AudioRecording, transcriber: SpeechTranscribing, now: @escaping () -> Date = { Date() }) {
        self.permissions = permissions; self.recorder = recorder; self.transcriber = transcriber; self.now = now
    }

    /// Asks for permissions the first time (only now, when needed), then records.
    public func begin() async {
        switch state {
        case .idle: break
        case .failed, .review: state = .idle
        case .recording, .transcribing: return
        }
        if permissions.microphone == .notDetermined, !(await permissions.requestMicrophone()) { state = .failed(.microphoneDenied); return }
        guard permissions.microphone == .granted else { state = .failed(.microphoneDenied); return }
        if permissions.speech == .notDetermined, !(await permissions.requestSpeech()) { state = .failed(.speechDenied); return }
        guard permissions.speech == .granted else { state = .failed(.speechDenied); return }
        do {
            try recorder.start()
            startedAt = now()
            state = .recording(since: startedAt!)
        } catch {
            state = .failed((error as? VoiceError) ?? .recordingFailed((error as? LocalizedError)?.errorDescription ?? "\(error)"))
        }
    }

    /// Key released (or the time limit reached): stop and transcribe on device.
    public func end() async {
        guard case .recording = state else { return }
        guard let (file, duration) = recorder.stop() else { state = .failed(.recordingFailed("no audio")); return }
        defer { try? FileManager.default.removeItem(at: file) }   // audio is never kept
        guard duration >= minDuration else { state = .failed(.tooShort); return }
        state = .transcribing
        do {
            let t = try await transcriber.transcribe(file)
            let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.onDevice else { state = .failed(.onDeviceUnavailable("this language")); return }
            guard !text.isEmpty else { state = .failed(.nothingHeard); return }
            state = .review(Transcript(text: text, confidence: t.confidence, onDevice: true))
        } catch let e as VoiceError {
            state = .failed(e)
        } catch {
            state = .failed(.transcriptionFailed((error as? LocalizedError)?.errorDescription ?? "\(error)"))
        }
    }

    public func cancel() {
        if case .recording = state { recorder.cancel() }
        state = .idle
    }

    /// After review: hand the (possibly corrected) text to the capture pipeline.
    public func accept() -> String? {
        guard case let .review(t) = state else { return nil }
        state = .idle
        return t.text
    }

    public func reset() { state = .idle }

    /// True once the recording has run past the limit (the app then calls end()).
    public var overLimit: Bool { startedAt.map { now().timeIntervalSince($0) >= maxDuration } ?? false }
}
