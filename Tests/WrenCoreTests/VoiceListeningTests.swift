import XCTest
@testable import WrenCore

/// While waiting for "Hey Wren", speech recognition runs only while someone is talking.
final class VoiceActivityGateTests: XCTestCase {
    /// Feeds `seconds` of buffers (~23 ms each) at `db`, returning the events.
    func run(_ g: inout VoiceActivityGate, _ db: Float, seconds: Double, from t0: Double) -> (events: [VoiceActivityGate.Event], end: Double) {
        var t = t0, out: [VoiceActivityGate.Event] = []
        while t < t0 + seconds { if let e = g.feed(level: db, at: t) { out.append(e) }; t += 0.023 }
        return (out, t)
    }

    func testQuietRoomNeverOpens() {
        var g = VoiceActivityGate()
        XCTAssertEqual(run(&g, -65, seconds: 30, from: 0).events, [])
    }

    func testSpeechOpensThenClosesAfterQuiet() {
        var g = VoiceActivityGate()
        var r = run(&g, -62, seconds: 3, from: 0)          // room tone
        r = run(&g, -28, seconds: 1.5, from: r.end)        // "Hey Wren, …"
        XCTAssertEqual(r.events, [.open])
        r = run(&g, -45, seconds: 1, from: r.end)          // trailing quieter speech keeps it open
        XCTAssertEqual(r.events, [])
        r = run(&g, -62, seconds: 3, from: r.end)          // silence
        XCTAssertEqual(r.events, [.close])
        XCTAssertFalse(g.isOpen)
    }

    func testASingleClickDoesntOpen() {
        var g = VoiceActivityGate()
        let r = run(&g, -62, seconds: 2, from: 0)
        XCTAssertNil(g.feed(level: -20, at: r.end))        // one loud buffer
        XCTAssertEqual(run(&g, -62, seconds: 2, from: r.end + 0.023).events, [])
    }

    func testAdaptsToASteadyNoisyRoom() {
        var g = VoiceActivityGate()
        // A fan at -42 dB: after adapting, it's background, not speech.
        _ = run(&g, -42, seconds: 0.05, from: 0)
        var r = run(&g, -42, seconds: 120, from: 0.05)
        // It may open briefly while learning, but ends closed and stays closed.
        XCTAssertFalse(g.isOpen, "a steady fan doesn't keep recognition running")
        r = run(&g, -42, seconds: 30, from: r.end)
        XCTAssertEqual(r.events, [])
        XCTAssertEqual(run(&g, -20, seconds: 1, from: r.end).events, [.open], "speech over the fan still opens")
    }

    func testLongBurstIsCapped() {
        var g = VoiceActivityGate()
        let r = run(&g, -62, seconds: 2, from: 0)
        let events = run(&g, -25, seconds: 60, from: r.end).events
        XCTAssertEqual(Array(events.prefix(2)), [.open, .close], "a burst never exceeds the recogniser's limit")
    }
}

@MainActor
extension VoiceTests {
    func testListeningForTheWakePhraseIsGatedAndCaptureIsNot() async {
        let p = Perms(); p.microphone = .granted; p.speech = .granted
        let (v, s, _, _) = make(perms: p)
        _ = await v.setWakeWord(true)
        XCTAssertTrue(s.wakeListening, "idle: recognise only while someone speaks")
        s.say("hey wren remind me to stretch")
        XCTAssertFalse(s.wakeListening, "after the wake phrase: keep recognising until the command ends")
    }

    func testLockingTheScreenReleasesTheMicrophoneAndUnlockingResumes() async {
        let p = Perms(); p.microphone = .granted; p.speech = .granted
        let (v, s, _, _) = make(perms: p)
        _ = await v.setWakeWord(true)
        XCTAssertTrue(s.isRunning)
        v.suspend()
        XCTAssertFalse(s.isRunning)
        XCTAssertEqual(v.phase, .off)
        _ = await v.setWakeWord(true)
        XCTAssertFalse(s.isRunning, "turning it on while locked doesn't open the microphone")
        v.resumeIfEnabled()
        XCTAssertTrue(s.isRunning)
        XCTAssertEqual(v.phase, .listening)
        _ = await v.setWakeWord(false)
        v.suspend(); v.resumeIfEnabled()
        XCTAssertFalse(s.isRunning, "off stays off")
    }

    func testStopCapturingHandsOffWhatWasSaid() async {
        let p = Perms(); p.microphone = .granted; p.speech = .granted
        let (v, s, _, _) = make(perms: p)
        var got: String?
        v.onCommand = { t, _ in got = t }
        _ = await v.shortcut()
        s.say("ask GPT what quantum physics is")
        v.stopCapturing()
        XCTAssertEqual(got, "ask GPT what quantum physics is")
        XCTAssertFalse(s.isRunning, "nothing more is recorded")
    }
}
