import XCTest
@testable import WrenCore

/// Push-to-talk, as a state machine with a fake microphone (`Stream`) and fake macOS permissions.
/// These check what the brief requires of every voice command: the microphone is open only while
/// listening, closes before transcription, and one utterance produces at most one command. The real
/// microphone, speech model and global shortcut need a Mac and a person: docs/MANUAL_TESTS.md M-PTT.
@MainActor
final class VoiceTests: XCTestCase {
    final class Perms: VoicePermissions {
        var microphone: VoicePermission = .notDetermined
        var speech: VoicePermission = .notDetermined
        var grantMic = true, grantSpeech = true
        var micRequests = 0
        var onAsk: (() -> Void)?
        func requestMicrophone() async -> Bool { micRequests += 1; onAsk?(); microphone = grantMic ? .granted : .denied; return grantMic }
        func requestSpeech() async -> Bool { speech = grantSpeech ? .granted : .denied; return grantSpeech }
    }
    /// Fake microphone + recogniser. `finish` closes the microphone at once and delivers the final
    /// transcript later (like the real recogniser), when the test calls `deliver`.
    final class Stream: SpeechStreaming {
        var onTranscript: ((String) -> Void)?
        var onEnded: ((VoiceError?) -> Void)?
        var isRunning = false
        var starts = 0, stops = 0, finishes = 0
        var failStart: VoiceError?
        var pending: ((Result<FinalTranscript, VoiceError>) -> Void)?
        /// Whether the microphone was already closed when `finish` returned.
        var micClosedOnFinish: Bool?
        func start() throws { if let failStart { throw failStart }; starts += 1; isRunning = true }
        func finish(_ completion: @escaping (Result<FinalTranscript, VoiceError>) -> Void) {
            finishes += 1; isRunning = false; micClosedOnFinish = !isRunning; pending = completion
        }
        func stop() { if isRunning { stops += 1 }; isRunning = false; pending = nil }
        func say(_ t: String) { onTranscript?(t) }
        func deliver(_ text: String, confidence: Double? = 0.9) { let p = pending; pending = nil; p?(.success(FinalTranscript(text: text, confidence: confidence))) }
        func deliver(error: VoiceError) { let p = pending; pending = nil; p?(.failure(error)) }
    }
    final class Clock { var t = Date(timeIntervalSince1970: 1_000_000) }

    func make(perms: Perms = { let p = Perms(); p.microphone = .granted; p.speech = .granted; return p }()) -> (VoiceSession, Stream, Clock) {
        let s = Stream(), c = Clock()
        return (VoiceSession(stream: s, permissions: perms, now: { c.t }), s, c)
    }

    // MARK: Lifecycle

    func testHoldListensReleaseTranscribesThenProcessesOnceWithTheMicrophoneOffThroughout() async {
        let (v, s, _) = make()
        var phases: [VoiceSession.Phase] = []
        var transcripts: [(String, TranscriptAssessment)] = []
        v.onPhase = { phases.append($0) }
        v.onTranscript = { transcripts.append(($0, $1)) }
        XCTAssertEqual(v.phase, .idle); XCTAssertFalse(v.isMicrophoneOpen, "off at launch")

        await v.press(.hold)
        XCTAssertEqual(v.phase, .listening(.hold)); XCTAssertTrue(v.isMicrophoneOpen)
        s.say("remind me to call Sam")
        s.say("remind me to call Sam tomorrow at 10 AM")
        XCTAssertEqual(v.liveText, "remind me to call Sam tomorrow at 10 AM", "interim text is the recogniser's own")

        v.release()
        XCTAssertEqual(v.phase, .transcribing)
        XCTAssertEqual(s.micClosedOnFinish, true, "the microphone closes before transcription")
        XCTAssertFalse(v.isMicrophoneOpen)

        s.deliver("Remind me to call Sam tomorrow at 10 AM.")
        XCTAssertEqual(v.phase, .transcriptReady("Remind me to call Sam tomorrow at 10 AM."))
        XCTAssertEqual(transcripts.map(\.0), ["Remind me to call Sam tomorrow at 10 AM."])
        XCTAssertEqual(transcripts.first?.1, .run)

        v.beginProcessing("Remind me to call Sam tomorrow at 10 AM.")
        XCTAssertEqual(v.phase, .processing("Remind me to call Sam tomorrow at 10 AM."))
        XCTAssertFalse(v.isMicrophoneOpen, "off while the command runs")
        v.finishProcessing(.completed("Reminder created: Call Sam"))
        XCTAssertEqual(v.phase, .completed("Reminder created: Call Sam"))
        XCTAssertFalse(v.isMicrophoneOpen)
        XCTAssertEqual(s.starts, 1, "never restarted")
        XCTAssertEqual(phases, [.listening(.hold), .transcribing, .transcriptReady("Remind me to call Sam tomorrow at 10 AM."),
                                .processing("Remind me to call Sam tomorrow at 10 AM."), .completed("Reminder created: Call Sam")])
    }

    func testRepeatedKeyDownAndPressesWhileBusyStartNothing() async {
        let (v, s, _) = make()
        var transcripts = 0
        v.onTranscript = { _, _ in transcripts += 1 }
        await v.press(.hold)
        await v.press(.hold); await v.press(.hold)          // key repeat while held
        XCTAssertEqual(s.starts, 1)
        s.say("what am I waiting for"); v.release()
        await v.press(.hold); await v.press(.button)        // while transcribing
        XCTAssertEqual(v.phase, .transcribing); XCTAssertEqual(s.starts, 1)
        s.deliver("What am I waiting for?")
        await v.press(.hold)                                // while the transcript is about to run
        v.beginProcessing("What am I waiting for?")
        await v.press(.hold)                                // while processing
        XCTAssertEqual(s.starts, 1); XCTAssertEqual(transcripts, 1)
        v.release(); v.release()                            // stray key-ups do nothing
        XCTAssertEqual(v.phase, .processing("What am I waiting for?"))
        v.finishProcessing(.completed("Nothing you're waiting on"))
        await v.press(.hold)
        XCTAssertEqual(s.starts, 2, "a new utterance after the result is fine")
    }

    func testALateTranscriptFromACancelledUtteranceIsIgnored() async {
        let (v, s, _) = make()
        var transcripts = 0
        v.onTranscript = { _, _ in transcripts += 1 }
        await v.press(.hold); s.say("remind me"); v.release()
        let late = s.pending
        v.cancel()
        XCTAssertEqual(v.phase, .cancelled(.byUser)); XCTAssertFalse(v.isMicrophoneOpen)
        late?(.success(FinalTranscript(text: "remind me to buy milk", confidence: 0.9)))
        XCTAssertEqual(transcripts, 0); XCTAssertEqual(v.phase, .cancelled(.byUser))
    }

    func testReleasingBeforeSpeakingCancelsInsteadOfRunningAnything() async {
        let (v, s, _) = make()
        var transcripts = 0
        v.onTranscript = { _, _ in transcripts += 1 }
        await v.press(.hold); v.release()
        s.deliver("")
        XCTAssertEqual(v.phase, .cancelled(.nothingHeard)); XCTAssertEqual(transcripts, 0); XCTAssertFalse(v.isMicrophoneOpen)
    }

    func testEscapeCancelsAtEveryStepBeforeProcessing() async {
        for step in 0..<3 {
            let (v, s, _) = make()
            var transcripts = 0
            v.onTranscript = { _, _ in transcripts += 1 }
            await v.press(.hold); s.say("ask GPT to research quantum physics")
            if step >= 1 { v.release() }
            if step >= 2 { s.deliver("Ask GPT to research quantum physics.") }
            v.cancel()
            XCTAssertEqual(v.phase, .cancelled(.byUser), "step \(step)")
            XCTAssertFalse(v.isMicrophoneOpen)
            v.beginProcessing("x")   // a cancelled utterance can only run if the user explicitly runs edited text
            XCTAssertEqual(transcripts, step >= 2 ? 1 : 0)
        }
    }

    func testRecognitionErrorsAndDeviceLossFailCleanly() async {
        let (v, s, _) = make()
        await v.press(.hold); v.release()
        s.deliver(error: .transcriptionFailed("model busy"))
        XCTAssertEqual(v.phase, .failed(.transcriptionFailed("model busy"))); XCTAssertFalse(v.isMicrophoneOpen)
        // The microphone stops on its own while recording (device unplugged): transcribe what was heard.
        await v.press(.hold); s.say("remind me to stretch")
        s.isRunning = false; s.onEnded?(nil)
        XCTAssertEqual(v.phase, .transcribing)
        await v.press(.hold)
        XCTAssertEqual(s.starts, 2)
        // A hard recogniser error while recording: failed, microphone released.
        let (v2, s2, _) = make()
        await v2.press(.hold); s2.onEnded?(.recordingFailed("device gone"))
        XCTAssertEqual(v2.phase, .failed(.recordingFailed("device gone"))); XCTAssertFalse(s2.isRunning)
    }

    // MARK: Permissions

    func testPermissionIsAskedOnlyWhenNeededAndDenialNeverOpensTheMicrophone() async {
        let p = Perms(); p.grantMic = false
        let (v, s, _) = make(perms: p)
        let e = await v.press(.hold)
        XCTAssertEqual(e, .microphoneDenied); XCTAssertEqual(s.starts, 0); XCTAssertEqual(v.phase, .failed(.microphoneDenied))
        await v.press(.hold)
        XCTAssertEqual(p.micRequests, 1, "macOS isn't asked again once it's denied")
        let p2 = Perms(); p2.grantSpeech = false
        let (v2, s2, _) = make(perms: p2)
        let e2 = await v2.press(.button)
        XCTAssertEqual(e2, .speechDenied); XCTAssertEqual(s2.starts, 0)
        let (v3, s3, _) = make()
        s3.failStart = .onDeviceUnavailable("en_US")
        let e3 = await v3.press(.hold)
        XCTAssertEqual(e3, .onDeviceUnavailable("en_US")); XCTAssertFalse(s3.isRunning)
    }

    func testReleasingTheKeysWhileMacOSAsksDoesntStartRecordingAfterwards() async {
        let p = Perms()
        let (v, s, _) = make(perms: p)
        p.onAsk = { v.release() }   // the user lets go to click Allow
        await v.press(.hold)
        XCTAssertEqual(v.phase, .cancelled(.releasedBeforeRecording)); XCTAssertEqual(s.starts, 0)
        await v.press(.hold)
        XCTAssertEqual(v.phase, .listening(.hold), "the next hold records normally")
    }

    func testCancellingWhileMacOSAsksDoesntOpenTheMicrophone() async {
        let p = Perms()
        let (v, s, _) = make(perms: p)
        p.onAsk = { v.cancel() }
        await v.press(.hold)
        XCTAssertEqual(s.starts, 0); XCTAssertFalse(v.isMicrophoneOpen)
    }

    // MARK: Button mode, caps, quit

    func testVoiceButtonStopsOnSecondClickOrAPause() async {
        let (v, s, c) = make()
        await v.press(.button); s.say("note: buy milk")
        await v.press(.button)
        XCTAssertEqual(v.phase, .transcribing)
        let (v2, s2, c2) = make()
        await v2.press(.button); s2.say("what's due today")
        c2.t += 2; v2.tick()
        XCTAssertEqual(v2.phase, .transcribing, "a pause ends a button recording")
        _ = c
    }

    func testAHeldShortcutIsCappedAndNothingSaidOnTheButtonCancels() async {
        let (v, _, c) = make()
        await v.press(.hold)
        c.t += 61; v.tick()
        XCTAssertEqual(v.phase, .transcribing, "a stuck key can't record forever")
        let (v2, s2, c2) = make()
        await v2.press(.button)
        c2.t += 8; v2.tick()
        XCTAssertEqual(v2.phase, .cancelled(.nothingHeard)); XCTAssertFalse(s2.isRunning)
    }

    func testQuitAndScreenLockReleaseTheMicrophone() async {
        let (v, s, _) = make()
        await v.press(.hold)
        v.cancel(.screenLocked)
        XCTAssertEqual(v.phase, .cancelled(.screenLocked)); XCTAssertFalse(s.isRunning)
        await v.press(.hold)
        v.shutdown()
        XCTAssertEqual(v.phase, .idle); XCTAssertFalse(s.isRunning)
    }

    func testMicrophoneIsOffUntilTheUserPresses() async {
        let (v, s, c) = make()
        for _ in 0..<50 { c.t += 1; v.tick() }
        s.say("remind me to call Sam")   // stray recogniser output can't start anything
        v.release()
        XCTAssertEqual(v.phase, .idle); XCTAssertEqual(s.starts, 0); XCTAssertFalse(s.isRunning)
    }

    // MARK: Transcript quality

    func testTranscriptAssessment() {
        XCTAssertEqual(TranscriptAssessment.assess(.init(text: "  ", confidence: nil)), .empty)
        XCTAssertEqual(TranscriptAssessment.assess(.init(text: "...", confidence: 0.9)), .empty)
        XCTAssertEqual(TranscriptAssessment.assess(.init(text: "Remind me to call Sam tomorrow at 10 AM.", confidence: 0.92)), .run)
        XCTAssertEqual(TranscriptAssessment.assess(.init(text: "Remind me to call Sam tomorrow at 10 AM.", confidence: nil)), .run, "unknown confidence isn't low")
        guard case .confirm = TranscriptAssessment.assess(.init(text: "remind me to coal some tomorrow", confidence: 0.2)) else { return XCTFail("low confidence must be confirmed") }
        guard case .confirm = TranscriptAssessment.assess(.init(text: "um", confidence: 0.9)) else { return XCTFail("one short word isn't a command") }
    }

    func testLowConfidenceTranscriptIsHandedOverForConfirmationNotRun() async {
        let (v, s, _) = make()
        var got: TranscriptAssessment?
        v.onTranscript = { _, a in got = a }
        await v.press(.hold); v.release()
        s.deliver("remind me to coal some tomorrow", confidence: 0.2)
        guard case .confirm? = got else { return XCTFail() }
        XCTAssertEqual(v.phase, .transcriptReady("remind me to coal some tomorrow"))
    }

    func testEndpointer() {
        var e = CommandEndpointer(start: Date(timeIntervalSince1970: 0))
        XCTAssertNil(e.check(Date(timeIntervalSince1970: 3)))
        XCTAssertEqual(e.check(Date(timeIntervalSince1970: 7)), .nothingSaid)
        e.transcript("remind me", at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(e.check(Date(timeIntervalSince1970: 3.7)), .pause)
        e.transcript("remind me to call", at: Date(timeIntervalSince1970: 3.5))
        XCTAssertNil(e.check(Date(timeIntervalSince1970: 4)), "still talking")
        XCTAssertEqual(e.check(Date(timeIntervalSince1970: 31)), .timeLimit)
    }

    // MARK: The spoken words take the typed path

    func testSpokenTranscriptsReachTheSameOperationsAsTypedText() async {
        let ist = calendar("Asia/Kolkata")
        let now = at(ist, 2026, 10, 13, 14)
        let cases: [(String, String)] = [
            ("Remind me to call Sam tomorrow at 10 AM.", "CreateReminder"),
            ("I need to finish the report by Friday.", "CreateTask"),
            ("Ask GPT to research quantum physics.", "DelegateToChatGPT"),
            ("What am I waiting for?", "QueryStoredItems"),
            ("Remind me every weekday at 3 PM.", "CreateReminder"),
        ]
        for (spoken, op) in cases {
            let (v, s, _) = make()
            var heard: String?
            v.onTranscript = { t, _ in heard = t }
            await v.press(.hold); s.say(spoken); v.release(); s.deliver(spoken)
            XCTAssertEqual(ExecutionRouter.operation(for: heard ?? "", now: now, calendar: ist).name, op, spoken)
        }
    }

    /// Source-level guard: no wake word or background listener can come back unnoticed.
    func testNoContinuousListeningCodeOrSetting() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/WrenCore/Connectors/Voice.swift", "Sources/WrenKit/VoiceSystem.swift", "Sources/WrenKit/Settings.swift", "Sources/WrenKit/ConnectorViews.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for banned in ["WakeWord", "wakeListening", "VoiceActivityGate", "setWakeWord", "Listen for “Hey Wren”"] {
                XCTAssertFalse(text.contains(banned), "\(file) contains \(banned)")
            }
        }
    }

    /// Audio isn't written anywhere: the live stream feeds buffers straight to the on-device
    /// recogniser, requires on-device recognition, has no file or network output, and closes the
    /// microphone in `finish` before waiting for the final text.
    func testLiveStreamIsOnDeviceOnlyKeepsNoAudioAndClosesTheMicrophoneFirst() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/WrenKit/VoiceSystem.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("requiresOnDeviceRecognition = true"))
        for banned in ["AVAudioFile", "URLSession", "write(to", "AVAudioRecorder"] { XCTAssertFalse(text.contains(banned), banned) }
        let finish = try XCTUnwrap(text.range(of: "func finish(")).upperBound
        let body = String(text[finish...].prefix(600))
        let close = try XCTUnwrap(body.range(of: "closeMicrophone()")), end = try XCTUnwrap(body.range(of: "endAudio()"))
        XCTAssertLessThan(close.lowerBound, end.lowerBound, "microphone closed before the recogniser finalises")
    }

    // MARK: A press that ends almost at once (a tap, or a spurious key-up)

    func testAShortPressKeepsListeningHandsFreeAndEndsOnAPause() async {
        let (v, s, c) = make()
        var heard: [String] = []
        v.onTranscript = { t, _ in heard.append(t) }
        await v.press(.hold)
        v.continueHandsFree()
        XCTAssertEqual(v.phase, .listening(.button), "still recording")
        XCTAssertTrue(v.isMicrophoneOpen)
        s.say("remind me to call Sam tomorrow at 10 AM")
        c.t += 1; v.tick()
        XCTAssertEqual(v.phase, .listening(.button), "mid-sentence")
        c.t += 1; v.tick()
        XCTAssertEqual(v.phase, .transcribing, "a pause ends it")
        XCTAssertFalse(v.isMicrophoneOpen)
        s.deliver("Remind me to call Sam tomorrow at 10 AM.")
        XCTAssertEqual(heard, ["Remind me to call Sam tomorrow at 10 AM."])
    }

    func testHandsFreeEndsOnAnotherPressAndSilenceCancels() async {
        let (v, s, c) = make()
        await v.press(.hold); v.continueHandsFree()
        s.say("what am I waiting for")
        await v.press(.button)            // the shortcut pressed again maps to Stop
        XCTAssertEqual(v.phase, .transcribing)
        let (v2, s2, c2) = make()
        await v2.press(.hold); v2.continueHandsFree()
        c2.t += 8; v2.tick()
        XCTAssertEqual(v2.phase, .cancelled(.nothingHeard)); XCTAssertFalse(s2.isRunning)
        _ = c
    }

    func testHandsFreeOnlyFromAHoldThatsListening() async {
        let (v, _, _) = make()
        v.continueHandsFree()
        XCTAssertEqual(v.phase, .idle)
        await v.press(.button)
        v.continueHandsFree()
        XCTAssertEqual(v.phase, .listening(.button))
        await v.press(.hold); v.release()
        v.continueHandsFree()
        XCTAssertEqual(v.phase, .transcribing, "after release it's too late to switch")
    }
}
