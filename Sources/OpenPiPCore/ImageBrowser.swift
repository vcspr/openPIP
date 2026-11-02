import Foundation

/// Which image an image card shows. The newest one, unless the user picked one in the last
/// `quiet` seconds. Picks are kept by path, so new images arriving do not move them.
public struct ImageBrowser: Equatable, Sendable {
    public static let quiet: TimeInterval = 10

    private var picked: String?
    private var pickedAt = Date.distantPast

    public init() {}

    public mutating func pick(_ path: String, at now: Date) {
        picked = path
        pickedAt = now
    }

    /// Moves `delta` images (negative = older) from the one shown now.
    public mutating func step(_ delta: Int, in paths: [String], at now: Date) {
        guard let i = current(in: paths, now: now) else { return }
        pick(paths[max(0, min(paths.count - 1, i + delta))], at: now)
    }

    public func current(in paths: [String], now: Date) -> Int? {
        guard !paths.isEmpty else { return nil }
        if let picked, now.timeIntervalSince(pickedAt) < Self.quiet, let i = paths.firstIndex(of: picked) { return i }
        return paths.count - 1
    }
}

/// The film strip along the bottom of an image card: a row of equal thumbnails.
public struct ImageStrip: Equatable, Sendable {
    public var width: CGFloat
    public var thumb: CGFloat
    public var gap: CGFloat
    public var inset: CGFloat

    public init(width: CGFloat, thumb: CGFloat, gap: CGFloat, inset: CGFloat) {
        self.width = width
        self.thumb = thumb
        self.gap = gap
        self.inset = inset
    }

    /// How many thumbnails fit.
    public var slots: Int {
        max(1, Int((width - 2 * inset + gap) / (thumb + gap)))
    }

    /// The thumbnail under `x` (from the strip's left edge), or nil for a gap or the margin.
    public func slot(atX x: CGFloat) -> Int? {
        let local = x - inset
        guard local >= 0 else { return nil }
        let i = Int(local / (thumb + gap))
        guard i < slots, local - CGFloat(i) * (thumb + gap) <= thumb else { return nil }
        return i
    }

    /// The images to show: `slots` of them, with `current` near the middle when it can be.
    public static func window(count: Int, current: Int, slots: Int) -> Range<Int> {
        guard count > slots else { return 0..<count }
        let start = max(0, min(current - slots / 2, count - slots))
        return start..<(start + slots)
    }
}

/// The size of an image card: the shown image's shape plus the film strip, so no empty bars show
/// beside the image. Very tall or very wide images stop at `minAspect` / `maxAspect`.
public enum ImageCardShape {
    public static let minAspect: CGFloat = 0.6
    public static let maxAspect: CGFloat = 2.4

    public static func size(imageAspect: CGFloat?, width: CGFloat, stripHeight: CGFloat) -> CGSize {
        let image = imageAspect.flatMap { $0 > 0 ? $0 : nil } ?? 4.0 / 3.0
        let natural = width / (width / image + stripHeight)
        let aspect = max(minAspect, min(maxAspect, natural))
        let height = aspect == natural ? width / image + stripHeight : width / aspect
        return CGSize(width: width, height: height)
    }
}

/// The small "Actions | Images" switch in the top-right corner of a session card and its image
/// card. Card points, top-left origin.
public enum CardSwitch {
    public enum Side: Equatable, Sendable { case actions, images }

    public static let size = CGSize(width: 136, height: 24)
    public static let margin: CGFloat = 10

    public static func frame(cardWidth: CGFloat) -> CGRect {
        CGRect(x: cardWidth - margin - size.width, y: margin, width: size.width, height: size.height)
    }

    /// The side under `p`, or nil when `p` is not on the switch.
    public static func side(at p: CGPoint, cardWidth: CGFloat) -> Side? {
        let f = frame(cardWidth: cardWidth)
        guard f.contains(p) else { return nil }
        return p.x < f.midX ? .actions : .images
    }
}
