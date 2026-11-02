import XCTest
@testable import OpenPiPCore

final class WelcomePolicyTests: XCTestCase {
    func testShowsOnFirstLaunchWithoutPermission() {
        XCTAssertTrue(WelcomePolicy.showAtLaunch(granted: false, shownBefore: false))
    }

    func testNeverShowsAgainAtLaunch() {
        // People who turned the switch on, but the build is not recognized, are not nagged on every launch.
        XCTAssertFalse(WelcomePolicy.showAtLaunch(granted: false, shownBefore: true))
    }

    func testNotShownWhenGranted() {
        XCTAssertFalse(WelcomePolicy.showAtLaunch(granted: true, shownBefore: false))
    }
}
