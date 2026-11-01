import CoreGraphics

/// Turns an event's `x`/`y` into a spot on the window, as fractions from the top-left (0...1).
public enum CursorMapper {
    /// - Parameters:
    ///   - windowFrame: the target window in global screen points, top-left origin (ScreenCaptureKit's frame).
    ///   - scale: pixels per point of the display the window is on.
    /// - Returns: nil when the event has no point, or the point falls outside the window.
    public static func fraction(for event: Event, windowFrame: CGRect, scale: CGFloat) -> CGPoint? {
        guard let x = event.x, let y = event.y,
              windowFrame.width > 0, windowFrame.height > 0 else { return nil }

        let size: CGSize
        var px = CGFloat(x), py = CGFloat(y)
        if let w = event.w, let h = event.h, w > 0, h > 0 {
            size = CGSize(width: w, height: h)
        } else {
            switch event.coords {
            case "screen":
                px -= windowFrame.minX
                py -= windowFrame.minY
                size = windowFrame.size
            case "pixels":
                var pixels = CGSize(width: windowFrame.width * scale, height: windowFrame.height * scale)
                if let maxEdge = event.maxEdge, maxEdge > 0 {
                    let shrink = min(1, CGFloat(maxEdge) / max(pixels.width, pixels.height))
                    pixels = CGSize(width: pixels.width * shrink, height: pixels.height * shrink)
                }
                size = pixels
            default:
                size = windowFrame.size
            }
        }

        let f = CGPoint(x: px / size.width, y: py / size.height)
        guard (0...1).contains(f.x), (0...1).contains(f.y) else { return nil }
        return f
    }
}
