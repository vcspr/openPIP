import XCTest
@testable import OpenPiPCore

final class LineBufferTests: XCTestCase {
    func testSplitsCompleteLines() {
        var b = LineBuffer()
        XCTAssertEqual(b.append(Data("a\nb\n".utf8)), ["a", "b"])
    }

    func testKeepsPartialLineUntilNewlineArrives() {
        var b = LineBuffer()
        XCTAssertEqual(b.append(Data("hel".utf8)), [])
        XCTAssertEqual(b.append(Data("lo\nwor".utf8)), ["hello"])
        XCTAssertEqual(b.append(Data("ld\n".utf8)), ["world"])
    }

    func testFlushReturnsTrailingLineWithoutNewline() {
        var b = LineBuffer()
        _ = b.append(Data("tail".utf8))
        XCTAssertEqual(b.flush(), ["tail"])
        XCTAssertEqual(b.flush(), [])
    }

    func testSkipsEmptyLinesAndCarriageReturns() {
        var b = LineBuffer()
        XCTAssertEqual(b.append(Data("a\r\n\n\nb\n".utf8)), ["a", "b"])
    }

    func testDropsLineThatGrowsPastLimit() {
        var b = LineBuffer(maxLineBytes: 8)
        XCTAssertEqual(b.append(Data("0123456789".utf8)), [])
        // The rest of the oversize line is thrown away too.
        XCTAssertEqual(b.append(Data("abc\nok\n".utf8)), ["ok"])
    }
}
