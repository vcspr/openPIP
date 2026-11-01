import CoreGraphics

/// The windows on screen as a stack of cards, front first. The front card is the live one.
public struct CardStack {
    public private(set) var ids: [UInt32] = []
    public private(set) var limit: Int

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public var front: UInt32? { ids.first }

    /// Moves `id` to the front. Returns windows that fell off the back.
    @discardableResult
    public mutating func push(_ id: UInt32) -> [UInt32] {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        return trim()
    }

    public mutating func remove(_ id: UInt32) {
        ids.removeAll { $0 == id }
    }

    public mutating func removeAll() {
        ids.removeAll()
    }

    @discardableResult
    public mutating func setLimit(_ newLimit: Int) -> [UInt32] {
        limit = max(1, newLimit)
        return trim()
    }

    private mutating func trim() -> [UInt32] {
        guard ids.count > limit else { return [] }
        let dropped = Array(ids[limit...])
        ids.removeLast(ids.count - limit)
        return dropped
    }
}

/// Places the cards: front card bottom-right, each older card shifted up and left by `step`
/// and shrunk by `backScale`, so its top-left corner peeks out. Every card keeps its window's aspect ratio.
public struct CardLayout {
    public var step: CGSize
    public var backScale: CGFloat
    public var margin: CGFloat

    public init(step: CGSize = CGSize(width: 22, height: 18), backScale: CGFloat = 0.92, margin: CGFloat = 14) {
        self.step = step
        self.backScale = backScale
        self.margin = margin
    }

    /// `aspects` are width / height, front first. Returns one frame per card in the same order.
    public func frames(in bounds: CGRect, aspects: [CGFloat]) -> [CGRect] {
        guard !aspects.isEmpty else { return [] }
        let inner = bounds.insetBy(dx: min(margin, bounds.width / 2), dy: min(margin, bounds.height / 2))
        let back = CGFloat(aspects.count - 1)
        let area = CGRect(x: inner.minX + back * step.width, y: inner.minY,
                          width: max(0, inner.width - back * step.width),
                          height: max(0, inner.height - back * step.height))

        let frontSize = fit(aspects[0], in: area.size)
        let front = CGRect(x: area.maxX - frontSize.width, y: area.minY,
                           width: frontSize.width, height: frontSize.height)
        var frames = [front]
        var scale: CGFloat = 1
        for i in 1..<aspects.count {
            scale *= backScale
            let size = fit(aspects[i], in: CGSize(width: area.width * scale, height: area.height * scale))
            let shift = CGFloat(i)
            var x = front.minX - shift * step.width
            var y = front.maxY + shift * step.height - size.height
            // A wide card behind a narrow one could stick out; keep it inside.
            x = max(inner.minX, min(x, inner.maxX - size.width))
            y = max(inner.minY, min(y, inner.maxY - size.height))
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
        }
        return frames
    }

    private func fit(_ aspect: CGFloat, in box: CGSize) -> CGSize {
        let a = aspect.isFinite && aspect > 0 ? aspect : 4.0 / 3.0
        guard box.width > 0, box.height > 0 else { return .zero }
        return box.width / box.height > a
            ? CGSize(width: box.height * a, height: box.height)
            : CGSize(width: box.width, height: box.width / a)
    }
}
