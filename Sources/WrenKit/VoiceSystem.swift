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

/// Records to a temporary file while the shortcut is held.
@MainActor
final class SystemRecorder: AudioRecording {
    private var recorder: AVAudioRecorder?
    private var url: URL?

    func start() throws {
        guard AVCaptureDevice.default(for: .audio) != nil else { throw VoiceError.noMicrophone }
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("wren-voice-\(UUID().uuidString).caf")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        let r = try AVAudioRecorder(url: u, settings: settings)
        guard r.record() else { throw VoiceError.recordingFailed("the microphone didn't start") }
        recorder = r; url = u
    }

    func stop() -> (URL, TimeInterval)? {
        guard let r = recorder, let u = url else { return nil }
        let d = r.currentTime
        r.stop(); recorder = nil; url = nil
        return (u, d)
    }

    func cancel() {
        recorder?.stop()
        if let url { try? FileManager.default.removeItem(at: url) }
        recorder = nil; url = nil
    }
}

/// Apple Speech, on-device only (`requiresOnDeviceRecognition`). Refuses server recognition.
struct OnDeviceTranscriber: SpeechTranscribing {
    var locale: Locale = .current

    static func availability(locale: Locale = .current) -> String? {
        guard let r = SFSpeechRecognizer(locale: locale) else { return "Speech recognition doesn't support \(locale.identifier)." }
        guard r.supportsOnDeviceRecognition else {
            return "On-device recognition isn't installed for \(locale.identifier). Turn on Dictation in System Settings › Keyboard once so macOS downloads it."
        }
        return r.isAvailable ? nil : "Speech recognition is temporarily unavailable."
    }

    func transcribe(_ file: URL) async throws -> Transcript {
        guard let r = SFSpeechRecognizer(locale: locale) else { throw VoiceError.onDeviceUnavailable(locale.identifier) }
        guard r.supportsOnDeviceRecognition else { throw VoiceError.onDeviceUnavailable(locale.identifier) }
        let req = SFSpeechURLRecognitionRequest(url: file)
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        return try await withCheckedThrowingContinuation { c in
            var done = false
            r.recognitionTask(with: req) { result, error in
                guard !done else { return }
                if let error { done = true; c.resume(throwing: VoiceError.transcriptionFailed(error.localizedDescription)); return }
                guard let result, result.isFinal else { return }
                done = true
                let segs = result.bestTranscription.segments
                let conf = segs.isEmpty ? nil : Double(segs.map(\.confidence).reduce(0, +)) / Double(segs.count)
                c.resume(returning: Transcript(text: result.bestTranscription.formattedString, confidence: conf, onDevice: true))
            }
        }
    }
}

/// Voice connector state from real macOS permissions and on-device availability.
@MainActor
final class VoiceConnector: Connector {
    let descriptor = ConnectorCatalog.descriptor(.voice)
    let permissions: SystemVoicePermissions
    var enabled: Bool
    init(permissions: SystemVoicePermissions, enabled: Bool) { self.permissions = permissions; self.enabled = enabled }

    var state: ConnectorState {
        guard enabled else { return .available }
        if !permissions.hasMicrophone { return .temporarilyUnavailable("No microphone found.") }
        if permissions.microphone == .denied || permissions.microphone == .restricted { return .permissionDenied(VoiceError.microphoneDenied.localizedDescription) }
        if permissions.speech == .denied || permissions.speech == .restricted { return .permissionDenied(VoiceError.speechDenied.localizedDescription) }
        if let problem = OnDeviceTranscriber.availability() { return .setupRequired(problem) }
        if permissions.microphone == .notDetermined || permissions.speech == .notDetermined {
            return .partiallyConnected("Ready. macOS will ask for Microphone and Speech Recognition the first time you record.")
        }
        return .connected(account: "On-device, \(Locale.current.identifier)")
    }
    func refresh() async {}
    func disconnect() async { enabled = false }
}
