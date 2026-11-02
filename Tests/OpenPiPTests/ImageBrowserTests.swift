import XCTest
@testable import OpenPiPCore

final class ImageBrowserTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1000)

    func testShowsNewestWhenNotBrowsing() {
        let b = ImageBrowser()
        XCTAssertEqual(b.current(in: ["a", "b", "c"], now: t0), 2)
        XCTAssertNil(b.current(in: [], now: t0))
    }

    func testPickedImageStaysWhileBrowsing() {
        var b = ImageBrowser()
        b.pick("a", at: t0)
        XCTAssertEqual(b.current(in: ["a", "b"], now: t0 + 5), 0)
        // A new image arrives: still on the picked one.
        XCTAssertEqual(b.current(in: ["a", "b", "c"], now: t0 + 9), 0)
    }

    func testGoesBackToNewestAfterTenQuietSeconds() {
        var b = ImageBrowser()
        b.pick("a", at: t0)
        XCTAssertEqual(b.current(in: ["a", "b", "c"], now: t0 + 11), 2)
    }

    func testPickedImageThatDroppedOffFallsBackToNewest() {
        var b = ImageBrowser()
        b.pick("gone", at: t0)
        XCTAssertEqual(b.current(in: ["a", "b"], now: t0 + 1), 1)
    }

    func testStepMovesAndStopsAtTheEnds() {
        var b = ImageBrowser()
        let paths = ["a", "b", "c"]
        b.step(-1, in: paths, at: t0)
        XCTAssertEqual(b.current(in: paths, now: t0), 1)
        b.step(-5, in: paths, at: t0)
        XCTAssertEqual(b.current(in: paths, now: t0), 0)
        b.step(9, in: paths, at: t0)
        XCTAssertEqual(b.current(in: paths, now: t0), 2)
    }

    func testStripWindowKeepsTheCurrentImageInView() {
        XCTAssertEqual(ImageStrip.window(count: 4, current: 3, slots: 8), 0..<4)
        XCTAssertEqual(ImageStrip.window(count: 30, current: 29, slots: 8), 22..<30)
        XCTAssertEqual(ImageStrip.window(count: 30, current: 0, slots: 8), 0..<8)
        XCTAssertEqual(ImageStrip.window(count: 30, current: 10, slots: 8), 6..<14)
    }

    func testStripHitTest() {
        let strip = ImageStrip(width: 400, thumb: 44, gap: 6, inset: 8)
        XCTAssertEqual(strip.slots, 7)
        // x from the strip's left edge
        XCTAssertEqual(strip.slot(atX: 10), 0)
        XCTAssertEqual(strip.slot(atX: 8 + 50 + 1), 1)
        XCTAssertNil(strip.slot(atX: 8 + 44 + 2)) // in the gap
        XCTAssertNil(strip.slot(atX: 2))
    }
}

final class ImageCardShapeTests: XCTestCase {
    func testCardTakesTheImageShapePlusTheStrip() {
        let s = ImageCardShape.size(imageAspect: 2, width: 560, stripHeight: 60)
        XCTAssertEqual(s.width, 560)
        XCTAssertEqual(s.height, 280 + 60)
    }

    func testTallImagesStopAtTheNarrowLimit() {
        // A 1:3 image would make a thin strip; the card stops at minAspect.
        let s = ImageCardShape.size(imageAspect: 1.0 / 3, width: 560, stripHeight: 60)
        XCTAssertEqual(s.width / s.height, ImageCardShape.minAspect, accuracy: 0.001)
    }

    func testWideImagesStopAtTheWideLimit() {
        let s = ImageCardShape.size(imageAspect: 6, width: 560, stripHeight: 60)
        XCTAssertEqual(s.width / s.height, ImageCardShape.maxAspect, accuracy: 0.001)
    }

    func testUnknownShapeUsesFourByThree() {
        let s = ImageCardShape.size(imageAspect: nil, width: 560, stripHeight: 60)
        XCTAssertEqual(s.height, 420 + 60)
    }
}
