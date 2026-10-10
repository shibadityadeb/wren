import Foundation
@testable import WrenCore

func calendar(_ tz: String) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: tz)!
    c.locale = Locale(identifier: "en_US_POSIX")
    return c
}

/// Builds a date in the given calendar's zone.
func at(_ cal: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

let zones = ["Asia/Kolkata", "America/Los_Angeles"]
