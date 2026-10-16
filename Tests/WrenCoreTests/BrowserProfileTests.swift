import XCTest
@testable import WrenCore

final class BrowserProfileTests: XCTestCase {
    let localState = Data(#"""
    {"profile":{"profiles_order":["Default","Profile 6","Profile 15"],"info_cache":{
      "Profile 15":{"name":"adypu.edu.in","user_name":"me@adypu.edu.in"},
      "Default":{"name":"Shibaditya","user_name":"me@gmail.com"},
      "Profile 6":{"name":"Work","user_name":""},
      "../evil":{"name":"x"}}}}
    """#.utf8)

    func testProfilesAreReadInTheBrowsersOrderWithTheirAccounts() {
        let p = BrowserProfiles.parse(localState)
        XCTAssertEqual(p.map(\.directory), ["Default", "Profile 6", "Profile 15"], "unsafe folder names are dropped")
        XCTAssertEqual(p[0].label, "Shibaditya (me@gmail.com)")
        XCTAssertEqual(p[1].label, "Work", "no account: just the name")
        XCTAssertEqual(BrowserProfiles.parse(Data("not json".utf8)), [])
    }

    func testOpenArgumentsTargetThatProfileAndOnlyWebAddresses() {
        let url = URL(string: "https://chatgpt.com/?q=hello")!
        XCTAssertEqual(BrowserProfiles.openArguments(appPath: "/Applications/Google Chrome.app", profile: "Default", url: url),
                       ["-na", "/Applications/Google Chrome.app", "--args", "--profile-directory=Default", "https://chatgpt.com/?q=hello"])
        XCTAssertNil(BrowserProfiles.openArguments(appPath: "/x.app", profile: "Default --incognito", url: url), "no extra flags through the name")
        XCTAssertNil(BrowserProfiles.openArguments(appPath: "/x.app", profile: "Default", url: URL(string: "file:///etc/passwd")!))
    }
}
