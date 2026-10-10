import XCTest
@testable import WrenCore

/// P3-15/P3-16. "now" is Thursday 8 Oct 2026, 15:00 local, in each zone.
final class DateParserTests: XCTestCase {
    struct Case { let text: String; let y, mo, d, h, mi: Int; let hasTime: Bool }

    let cases: [Case] = [
        .init(text: "submit the form tomorrow", y: 2026, mo: 10, d: 9, h: 0, mi: 0, hasTime: false),
        .init(text: "call my friend at 8 tonight", y: 2026, mo: 10, d: 8, h: 20, mi: 0, hasTime: true),
        .init(text: "tonight at 8", y: 2026, mo: 10, d: 8, h: 20, mi: 0, hasTime: true),
        .init(text: "submit by Friday", y: 2026, mo: 10, d: 9, h: 0, mi: 0, hasTime: false),
        .init(text: "do it Thursday", y: 2026, mo: 10, d: 15, h: 0, mi: 0, hasTime: false),
        .init(text: "next monday", y: 2026, mo: 10, d: 12, h: 0, mi: 0, hasTime: false),
        .init(text: "read it this weekend", y: 2026, mo: 10, d: 10, h: 0, mi: 0, hasTime: false),
        .init(text: "tomorrow evening", y: 2026, mo: 10, d: 9, h: 18, mi: 0, hasTime: true),
        .init(text: "tomorrow at 9:30am", y: 2026, mo: 10, d: 9, h: 9, mi: 30, hasTime: true),
        .init(text: "remind me at 9", y: 2026, mo: 10, d: 8, h: 21, mi: 0, hasTime: true),
        .init(text: "9pm", y: 2026, mo: 10, d: 8, h: 21, mi: 0, hasTime: true),
        .init(text: "at 10am", y: 2026, mo: 10, d: 9, h: 10, mi: 0, hasTime: true),
        .init(text: "in 2 hours", y: 2026, mo: 10, d: 8, h: 17, mi: 0, hasTime: true),
        .init(text: "in 20 minutes", y: 2026, mo: 10, d: 8, h: 15, mi: 20, hasTime: true),
        .init(text: "in 3 days", y: 2026, mo: 10, d: 11, h: 0, mi: 0, hasTime: false),
        .init(text: "by end of month", y: 2026, mo: 10, d: 31, h: 0, mi: 0, hasTime: false),
        .init(text: "on 15 october", y: 2026, mo: 10, d: 15, h: 0, mi: 0, hasTime: false),
        .init(text: "Oct 2nd", y: 2027, mo: 10, d: 2, h: 0, mi: 0, hasTime: false),
        .init(text: "friday at noon", y: 2026, mo: 10, d: 9, h: 12, mi: 0, hasTime: true),
    ]

    func testTable() {
        for tz in zones {
            let cal = calendar(tz)
            let p = DateParser(calendar: cal)
            let now = at(cal, 2026, 10, 8, 15)
            for c in cases {
                let r = p.parse(c.text, now: now)
                XCTAssertEqual(r?.date, at(cal, c.y, c.mo, c.d, c.h, c.mi), "\(tz): \(c.text)")
                XCTAssertEqual(r?.hasTime, c.hasTime, "\(tz): \(c.text)")
            }
        }
    }

    func testNoDateNoGuess() {
        let p = DateParser(calendar: calendar("Asia/Kolkata"))
        for text in ["I have an idea for a new AI startup", "publish 3 articles", "waiting for the recruiter",
                     "read chapter 10", "call 911", "the 2 forms"] {
            XCTAssertNil(p.parse(text, now: .now), text)
        }
    }

    // P3-16: 23:50 IST "tomorrow" means the IST tomorrow, not UTC's.
    func testLateNightUsesLocalZone() {
        let cal = calendar("Asia/Kolkata")
        let r = DateParser(calendar: cal).parse("tomorrow", now: at(cal, 2026, 10, 8, 23, 50))
        XCTAssertEqual(r?.date, at(cal, 2026, 10, 9))
    }

    func testApproximateFlag() {
        let cal = calendar("Asia/Kolkata")
        let p = DateParser(calendar: cal)
        XCTAssertEqual(p.parse("this weekend", now: .now)?.isApproximate, true)
        XCTAssertEqual(p.parse("friday", now: .now)?.isApproximate, false)
    }
}
