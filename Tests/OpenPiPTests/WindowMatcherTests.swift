import XCTest
@testable import OpenPiPCore

final class WindowMatcherTests: XCTestCase {
    func w(_ id: UInt32, _ app: String, _ bundle: String, _ title: String?, pid: Int32 = 1,
           area: Double = 100, onScreen: Bool = true) -> WindowInfo {
        WindowInfo(id: id, appName: app, bundleID: bundle, title: title, pid: pid, area: area, isOnScreen: onScreen)
    }

    func ev(app: String? = nil, window: String? = nil, pid: Int32? = nil) -> Event {
        Event(agent: "t", status: .step, text: "", app: app, window: window, pid: pid)
    }

    lazy var windows = [
        w(1, "Notes", "com.apple.Notes", "Shopping", pid: 10, area: 500),
        w(2, "Notes", "com.apple.Notes", "Work", pid: 10, area: 900),
        w(3, "Google Chrome", "com.google.Chrome", "Inbox - Gmail", pid: 20, area: 2000),
        w(4, "Mail", "com.apple.mail", "Inbox", pid: 30, area: 800, onScreen: false),
    ]

    func testNoHintReturnsNil() {
        XCTAssertNil(WindowMatcher.match(ev(), in: windows))
    }

    func testAppNameMatchPicksLargestWindow() {
        XCTAssertEqual(WindowMatcher.match(ev(app: "Notes"), in: windows)?.id, 2)
    }

    func testAppMatchIsCaseInsensitive() {
        XCTAssertEqual(WindowMatcher.match(ev(app: "google chrome"), in: windows)?.id, 3)
    }

    func testBundleIDMatches() {
        XCTAssertEqual(WindowMatcher.match(ev(app: "com.google.Chrome"), in: windows)?.id, 3)
    }

    func testWindowTitleSubstringNarrowsChoice() {
        XCTAssertEqual(WindowMatcher.match(ev(app: "Notes", window: "shop"), in: windows)?.id, 1)
    }

    func testTitleThatMatchesNothingFallsBackToApp() {
        XCTAssertEqual(WindowMatcher.match(ev(app: "Notes", window: "zzz"), in: windows)?.id, 2)
    }

    func testWindowOnlyHintSearchesAllApps() {
        XCTAssertEqual(WindowMatcher.match(ev(window: "gmail"), in: windows)?.id, 3)
    }

    func testPidWins() {
        XCTAssertEqual(WindowMatcher.match(ev(app: "Notes", pid: 20), in: windows)?.id, 3)
    }

    func testOnScreenPreferredOverLargerOffScreen() {
        let list = [w(1, "Mail", "com.apple.mail", "A", area: 9000, onScreen: false),
                    w(2, "Mail", "com.apple.mail", "B", area: 10)]
        XCTAssertEqual(WindowMatcher.match(ev(app: "Mail"), in: list)?.id, 2)
    }

    func testOffScreenStillReturnedWhenOnlyChoice() {
        XCTAssertEqual(WindowMatcher.match(ev(app: "Mail"), in: windows)?.id, 4)
    }

    func testSameWindowNeedsTitleMatchWhenWindowGiven() {
        let notes = windows[0] // "Shopping"
        XCTAssertTrue(WindowMatcher.isSameWindow(ev(app: "Notes", window: "shop"), notes))
        XCTAssertFalse(WindowMatcher.isSameWindow(ev(app: "Notes", window: "work"), notes))
    }

    func testSameWindowChecksAppAndPid() {
        let notes = windows[0]
        XCTAssertTrue(WindowMatcher.isSameWindow(ev(app: "com.apple.notes"), notes))
        XCTAssertFalse(WindowMatcher.isSameWindow(ev(app: "Mail"), notes))
        XCTAssertFalse(WindowMatcher.isSameWindow(ev(pid: 99), notes))
        XCTAssertFalse(WindowMatcher.isSameWindow(ev(), notes))
    }

    func testUnknownAppReturnsNil() {
        XCTAssertNil(WindowMatcher.match(ev(app: "Xcode"), in: windows))
    }
}
