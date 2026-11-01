import XCTest
@testable import OpenPiPCore

final class FrameFingerprintTests: XCTestCase {
    func print(_ bytes: [UInt8]) -> UInt64 {
        bytes.withUnsafeBytes { FrameFingerprint.of($0, stride: 3) }
    }

    func testSameBytesGiveSameFingerprint() {
        XCTAssertEqual(print([1, 2, 3, 4, 5, 6, 7]), print([1, 2, 3, 4, 5, 6, 7]))
    }

    func testChangedSampledByteGivesNewFingerprint() {
        // stride 3 samples index 0, 3, 6.
        XCTAssertNotEqual(print([1, 2, 3, 4, 5, 6, 7]), print([1, 2, 3, 9, 5, 6, 7]))
    }

    func testEmptyBufferIsStable() {
        XCTAssertEqual(print([]), print([]))
    }
}

final class FrameChangeDetectorTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 5_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testFirstFrameIsAChange() {
        var d = FrameChangeDetector()
        XCTAssertTrue(d.feed(1, at: t0).changed)
    }

    func testDuplicateFrameIsNotAChange() {
        var d = FrameChangeDetector()
        _ = d.feed(1, at: t0)
        XCTAssertFalse(d.feed(1, at: at(0.1)).changed)
    }

    func testNewContentIsAChange() {
        var d = FrameChangeDetector()
        _ = d.feed(1, at: t0)
        XCTAssertTrue(d.feed(2, at: at(0.1)).changed)
    }

    func testDropsToSlowRateAfterQuietPeriod() {
        var d = FrameChangeDetector(fastFPS: 15, slowFPS: 5, slowAfter: 2)
        _ = d.feed(1, at: t0)
        XCTAssertNil(d.feed(1, at: at(1.9)).newFPS)
        XCTAssertEqual(d.feed(1, at: at(2)).newFPS, 5)
        // Reported once, not on every quiet frame.
        XCTAssertNil(d.feed(1, at: at(3)).newFPS)
    }

    func testReturnsToFastRateOnChange() {
        var d = FrameChangeDetector(fastFPS: 15, slowFPS: 5, slowAfter: 2)
        _ = d.feed(1, at: t0)
        _ = d.feed(1, at: at(2))
        XCTAssertEqual(d.feed(2, at: at(3)).newFPS, 15)
        XCTAssertNil(d.feed(3, at: at(3.1)).newFPS)
    }

    func testStartsAtFastRate() {
        XCTAssertEqual(FrameChangeDetector(fastFPS: 15, slowFPS: 5).fps, 15)
    }
}
