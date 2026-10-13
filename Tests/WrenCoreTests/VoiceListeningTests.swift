import XCTest
@testable import WrenCore

/// Voice is explicitly activated. These pin the guarantees the brief asks for: no background
/// listening exists, the microphone is off whenever no command is being recorded, and the words go
/// through the same router as typed text.
@MainActor
extension VoiceTests {
    func testMicrophoneIsOffUntilTheUserActivatesVoice() async {
        let (v, s, c, _) = make()
        for _ in 0..<50 { c.t += 1; v.tick() }
        s.say("remind me to call Sam")   // stray recogniser output can't start anything
        XCTAssertEqual(v.phase, .off); XCTAssertEqual(s.starts, 0); XCTAssertFalse(s.isRunning)
    }

    func testStopCapturingHandsOffWhatWasSaid() async {
        let p = Perms(); p.microphone = .granted; p.speech = .granted
        let (v, s, _, _) = make(perms: p)
        var got: String?
        v.onCommand = { t, _ in got = t }
        _ = await v.activate(.shortcut)
        s.say("ask GPT what quantum physics is")
        v.stopCapturing()
        XCTAssertEqual(got, "ask GPT what quantum physics is")
        XCTAssertFalse(s.isRunning, "nothing more is recorded")
    }

    func testATranscriptGoesThroughTheSameRouterAsTypedText() async {
        let ist = calendar("Asia/Kolkata")
        let now = at(ist, 2026, 10, 13, 14)
        let (v, s, _, _) = make()
        var spoken: String?
        v.onCommand = { t, _ in spoken = t }
        _ = await v.activate(.button)
        s.say("Ask GPT to research the fundamentals of quantum physics")
        v.stopCapturing()
        let fromVoice = ExecutionRouter.operation(for: spoken ?? "", now: now, calendar: ist)
        let typed = ExecutionRouter.operation(for: "Ask GPT to research the fundamentals of quantum physics", now: now, calendar: ist)
        XCTAssertEqual(fromVoice, typed)
        XCTAssertEqual(fromVoice.name, "DelegateToChatGPT")
    }

    /// Source-level guard: no wake-word listener or continuous-listening setting can come back unnoticed.
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
    /// recogniser, requires on-device recognition, and has no file or network output.
    func testLiveStreamIsOnDeviceOnlyAndKeepsNoAudio() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/WrenKit/VoiceSystem.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("requiresOnDeviceRecognition = true"))
        for banned in ["AVAudioFile", "URLSession", "write(to", "AVAudioRecorder"] { XCTAssertFalse(text.contains(banned), banned) }
    }
}
