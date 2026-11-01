import XCTest
@testable import OpenPiPCore

final class CursorMapperTests: XCTestCase {
    // A 673 x 439 point window at (234, 103) on a 2x display, like the TextEdit window OCU saw as 1280 x 834.
    let frame = CGRect(x: 234, y: 103, width: 673, height: 439)

    func event(_ x: Double, _ y: Double, coords: String? = nil, w: Double? = nil, h: Double? = nil,
               maxEdge: Double? = nil) -> Event {
        Event(agent: "t", status: .step, text: "", x: x, y: y, coords: coords, w: w, h: h, maxEdge: maxEdge)
    }

    func testNoCoordinatesGiveNoCursor() {
        let e = Event(agent: "t", status: .step, text: "")
        XCTAssertNil(CursorMapper.fraction(for: e, windowFrame: frame, scale: 2))
    }

    func testWindowPointsAreTheDefault() throws {
        let p = try XCTUnwrap(CursorMapper.fraction(for: event(336.5, 219.5), windowFrame: frame, scale: 2))
        XCTAssertEqual(p.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(p.y, 0.5, accuracy: 0.001)
    }

    func testScreenPointsAreMadeWindowRelative() throws {
        let p = try XCTUnwrap(CursorMapper.fraction(for: event(234, 542, coords: "screen"), windowFrame: frame, scale: 2))
        XCTAssertEqual(p.x, 0, accuracy: 0.001)
        XCTAssertEqual(p.y, 1, accuracy: 0.001)
    }

    func testPixelsUndoTheScreenshotShrink() throws {
        // 1346 x 878 pixels shrunk so the long edge is 1280 -> 1280 x 835.
        let p = try XCTUnwrap(CursorMapper.fraction(for: event(640, 417.5, coords: "pixels", maxEdge: 1280),
                                                    windowFrame: frame, scale: 2))
        XCTAssertEqual(p.x, 0.5, accuracy: 0.002)
        XCTAssertEqual(p.y, 0.5, accuracy: 0.002)
    }

    func testPixelsWithoutShrinkUseTheScale() throws {
        let small = CGRect(x: 0, y: 0, width: 300, height: 200)
        let p = try XCTUnwrap(CursorMapper.fraction(for: event(300, 100, coords: "pixels", maxEdge: 1280),
                                                    windowFrame: small, scale: 2))
        XCTAssertEqual(p.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(p.y, 0.25, accuracy: 0.001)
    }

    func testExplicitImageSizeWins() throws {
        let p = try XCTUnwrap(CursorMapper.fraction(for: event(50, 25, coords: "pixels", w: 100, h: 100),
                                                    windowFrame: frame, scale: 2))
        XCTAssertEqual(p.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(p.y, 0.25, accuracy: 0.001)
    }

    func testPointOutsideWindowGivesNoCursor() {
        XCTAssertNil(CursorMapper.fraction(for: event(-5, 10), windowFrame: frame, scale: 2))
        XCTAssertNil(CursorMapper.fraction(for: event(10, 900), windowFrame: frame, scale: 2))
    }

    func testEmptyWindowGivesNoCursor() {
        XCTAssertNil(CursorMapper.fraction(for: event(1, 1), windowFrame: .zero, scale: 2))
    }
}
