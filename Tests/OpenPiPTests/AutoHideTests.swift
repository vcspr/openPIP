import XCTest
@testable import OpenPiPCore

final class AutoHideTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testHiddenBeforeAnyEvent() {
        let h = AutoHide()
        XCTAssertFalse(h.isVisible(at: t0))
    }

    func testStartEventShowsPanel() {
        var h = AutoHide()
        h.event(.start, at: t0)
        XCTAssertTrue(h.isVisible(at: at(1)))
    }

    func testHidesFiveSecondsAfterEnd() {
        var h = AutoHide()
        h.event(.start, at: t0)
        h.event(.end, at: at(2))
        XCTAssertTrue(h.isVisible(at: at(6.9)))
        XCTAssertFalse(h.isVisible(at: at(7)))
    }

    func testErrorBehavesLikeEnd() {
        var h = AutoHide()
        h.event(.error, at: t0)
        XCTAssertTrue(h.isVisible(at: at(4)))
        XCTAssertFalse(h.isVisible(at: at(5)))
    }

    func testHidesAfterTenQuietSecondsWhileActive() {
        var h = AutoHide()
        h.event(.step, at: t0)
        XCTAssertTrue(h.isVisible(at: at(9.9)))
        XCTAssertFalse(h.isVisible(at: at(10)))
    }

    func testFrameChangeKeepsActivePanelOpen() {
        var h = AutoHide()
        h.event(.step, at: t0)
        h.frameChanged(at: at(8))
        XCTAssertTrue(h.isVisible(at: at(15)))
        XCTAssertFalse(h.isVisible(at: at(18)))
    }

    func testFrameChangeDoesNotExtendAfterEnd() {
        var h = AutoHide()
        h.event(.end, at: t0)
        h.frameChanged(at: at(4))
        XCTAssertFalse(h.isVisible(at: at(5)))
    }

    func testFrameChangeAloneDoesNotShowPanel() {
        var h = AutoHide()
        h.frameChanged(at: t0)
        XCTAssertFalse(h.isVisible(at: at(1)))
    }

    func testNewEventAfterHideShowsAgain() {
        var h = AutoHide()
        h.event(.end, at: t0)
        XCTAssertFalse(h.isVisible(at: at(6)))
        h.event(.step, at: at(20))
        XCTAssertTrue(h.isVisible(at: at(21)))
    }

    func testStepAfterEndCancelsEndTimer() {
        var h = AutoHide()
        h.event(.end, at: t0)
        h.event(.step, at: at(1))
        XCTAssertTrue(h.isVisible(at: at(8)))
    }

    func testAlwaysShowOverrides() {
        var h = AutoHide()
        h.alwaysShow = true
        XCTAssertTrue(h.isVisible(at: at(1000)))
    }

    func testPinnedStaysVisible() {
        var h = AutoHide()
        h.pinned = true
        XCTAssertTrue(h.isVisible(at: at(1000)))
        h.pinned = false
        XCTAssertFalse(h.isVisible(at: at(1000)))
    }

    func testCustomDelays() {
        var h = AutoHide(endDelay: 1, idleDelay: 2)
        h.event(.step, at: t0)
        XCTAssertFalse(h.isVisible(at: at(2)))
        h.event(.end, at: at(10))
        XCTAssertFalse(h.isVisible(at: at(11)))
    }
}
