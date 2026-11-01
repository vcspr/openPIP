import XCTest
@testable import OpenPiPCore

final class CardStackTests: XCTestCase {
    func testEmptyStackHasNoFront() {
        XCTAssertNil(CardStack(limit: 3).front)
    }

    func testPushPutsWindowInFront() {
        var s = CardStack(limit: 3)
        s.push(1)
        s.push(2)
        XCTAssertEqual(s.ids, [2, 1])
        XCTAssertEqual(s.front, 2)
    }

    func testPushingExistingWindowMovesItToFront() {
        var s = CardStack(limit: 3)
        s.push(1); s.push(2); s.push(3)
        s.push(1)
        XCTAssertEqual(s.ids, [1, 3, 2])
    }

    func testOldestWindowDropsOffPastLimit() {
        var s = CardStack(limit: 2)
        s.push(1); s.push(2)
        let dropped = s.push(3)
        XCTAssertEqual(s.ids, [3, 2])
        XCTAssertEqual(dropped, [1])
    }

    func testRemoveTakesWindowOut() {
        var s = CardStack(limit: 3)
        s.push(1); s.push(2); s.push(3)
        s.remove(3)
        XCTAssertEqual(s.ids, [2, 1])
        XCTAssertEqual(s.front, 2)
    }

    func testLowerLimitTrims() {
        var s = CardStack(limit: 3)
        s.push(1); s.push(2); s.push(3)
        let dropped = s.setLimit(1)
        XCTAssertEqual(s.ids, [3])
        XCTAssertEqual(dropped, [2, 1])
    }

    func testLimitIsAtLeastOne() {
        var s = CardStack(limit: 0)
        s.push(1)
        XCTAssertEqual(s.ids, [1])
    }
}

final class CardLayoutTests: XCTestCase {
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    let layout = CardLayout(step: CGSize(width: 20, height: 16), backScale: 0.9, margin: 10)

    func testSingleCardKeepsAspectAndFitsInside() {
        let f = layout.frames(in: bounds, aspects: [2.0])
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].width / f[0].height, 2.0, accuracy: 0.001)
        XCTAssertTrue(bounds.insetBy(dx: 10, dy: 10).contains(f[0]))
    }

    func testTallWindowIsLimitedByHeight() {
        let f = layout.frames(in: bounds, aspects: [0.5])
        XCTAssertEqual(f[0].height, 280, accuracy: 0.001)
        XCTAssertEqual(f[0].width, 140, accuracy: 0.001)
    }

    func testFrontCardSitsBottomRight() {
        let f = layout.frames(in: bounds, aspects: [0.5])
        XCTAssertEqual(f[0].maxX, 390, accuracy: 0.001)
        XCTAssertEqual(f[0].minY, 10, accuracy: 0.001)
    }

    func testBackCardsPeekOutUpAndLeft() {
        let f = layout.frames(in: bounds, aspects: [1.5, 1.5, 1.5])
        XCTAssertEqual(f[1].minX, f[0].minX - 20, accuracy: 0.001)
        XCTAssertEqual(f[1].maxY, f[0].maxY + 16, accuracy: 0.001)
        XCTAssertEqual(f[2].minX, f[0].minX - 40, accuracy: 0.001)
        XCTAssertEqual(f[2].maxY, f[0].maxY + 32, accuracy: 0.001)
    }

    func testBackCardsAreSmaller() {
        let f = layout.frames(in: bounds, aspects: [1.5, 1.5])
        XCTAssertLessThan(f[1].width, f[0].width)
    }

    func testWholeStackFitsInside() {
        let f = layout.frames(in: bounds, aspects: [1.0, 3.0, 0.4])
        let inner = bounds.insetBy(dx: 10, dy: 10)
        for r in f { XCTAssertTrue(inner.insetBy(dx: -0.001, dy: -0.001).contains(r), "\(r)") }
    }

    func testBadAspectFallsBackToFourByThree() {
        let f = layout.frames(in: bounds, aspects: [0])
        XCTAssertEqual(f[0].width / f[0].height, 4.0 / 3.0, accuracy: 0.001)
    }

    func testTinyBoundsGiveNoNegativeSizes() {
        let f = layout.frames(in: CGRect(x: 0, y: 0, width: 10, height: 10), aspects: [1, 1, 1])
        for r in f { XCTAssertGreaterThanOrEqual(r.width, 0); XCTAssertGreaterThanOrEqual(r.height, 0) }
    }
}
