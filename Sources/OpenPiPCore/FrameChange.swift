import Foundation

/// Cheap fingerprint of a frame: FNV-1a over every `stride`-th byte.
/// ScreenCaptureKit marks repeat frames of a still window as complete with a full dirty rect,
/// so the app compares fingerprints to tell real changes from copies.
public enum FrameFingerprint {
    public static func of(_ bytes: UnsafeRawBufferPointer, stride: Int = 61) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var i = 0
        while i < bytes.count {
            hash = (hash ^ UInt64(bytes[i])) &* 0x0000_0100_0000_01b3
            i += stride
        }
        return hash
    }
}

/// Tells new content from repeat frames, and picks the stream rate:
/// fast while the window changes, slow after `slowAfter` seconds without a change.
public struct FrameChangeDetector {
    public let fastFPS: Int
    public let slowFPS: Int
    public let slowAfter: TimeInterval
    public private(set) var fps: Int

    private var last: UInt64?
    private var lastChange: Date?

    public init(fastFPS: Int = 15, slowFPS: Int = 5, slowAfter: TimeInterval = 2) {
        self.fastFPS = fastFPS
        self.slowFPS = slowFPS
        self.slowAfter = slowAfter
        fps = fastFPS
    }

    /// `newFPS` is set only when the stream should switch rate.
    public mutating func feed(_ fingerprint: UInt64, at now: Date) -> (changed: Bool, newFPS: Int?) {
        let changed = fingerprint != last
        last = fingerprint
        var wanted = fps
        if changed {
            lastChange = now
            wanted = fastFPS
        } else if let lastChange, now.timeIntervalSince(lastChange) >= slowAfter {
            wanted = slowFPS
        }
        defer { fps = wanted }
        return (changed, wanted == fps ? nil : wanted)
    }
}
