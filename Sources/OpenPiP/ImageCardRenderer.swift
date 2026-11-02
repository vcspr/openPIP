import AppKit
import CoreImage
import ImageIO
import OpenPiPCore

/// Loads small copies of image files off the main thread and keeps them. A file that changes on
/// disk (same name, new render) is loaded again.
@MainActor
final class ImageLoader {
    var onLoad: (() -> Void)?

    private struct Key: Hashable {
        var path: String
        var maxPixel: Int
        var blurred: Bool
        var modified: Date
    }

    private var cache: [Key: CGImage] = [:]
    private var pending: Set<Key> = []
    private static let maxEntries = 160
    private let queue = DispatchQueue(label: "app.hemii.openpip.images", qos: .utility, attributes: .concurrent)

    /// The cached copy, or nil while it loads (`onLoad` runs when it is ready). `blurred` gives a
    /// softly blurred copy, used to fill the card around very tall or wide images.
    func image(_ path: String, maxPixel: Int, blurred: Bool = false) -> CGImage? {
        guard let modified = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date else {
            return nil
        }
        let key = Key(path: path, maxPixel: maxPixel, blurred: blurred, modified: modified)
        if let hit = cache[key] { return hit }
        guard !pending.contains(key) else { return nil }
        pending.insert(key)
        queue.async { [weak self] in
            let image = Self.load(path, maxPixel: maxPixel).flatMap { blurred ? Self.blur($0) : $0 }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pending.remove(key)
                    guard let image else { return }
                    if self.cache.count >= Self.maxEntries { self.cache.removeAll() }
                    self.cache[key] = image
                    self.onLoad?()
                }
            }
        }
        return nil
    }

    nonisolated private static let ciContext = CIContext()

    nonisolated private static func blur(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let out = input.clampedToExtent().applyingGaussianBlur(sigma: 6).cropped(to: input.extent)
        return ciContext.createCGImage(out, from: input.extent)
    }

    nonisolated private static func load(_ path: String, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// Draws an image card: the picked image, a ★ and the agent's name, "3 / 24", the file name, and a
/// film strip of the latest images along the bottom (gold edge = shared, white = shown now).
/// The card takes the shape of the image (see `ImageCardShape`), so no bars show beside it.
@MainActor
enum ImageCardRenderer {
    nonisolated static let width: CGFloat = 560
    nonisolated static let stripHeight: CGFloat = 60
    static let strip = ImageStrip(width: width, thumb: 44, gap: 6, inset: 8)
    /// Thumbnails are loaded at this size (2x the strip), and stretched for the soft backdrop.
    private static let thumbPixels = 88

    enum Hit: Equatable {
        case thumb(Int)
        case image
        case none
    }

    /// What is under `p` (card points, top-left origin) on a card of `size`.
    static func hit(_ p: CGPoint, size: CGSize, count: Int, current: Int) -> Hit {
        let stripTop = size.height - stripHeight
        guard p.y >= stripTop else { return count > 0 ? .image : .none }
        let window = ImageStrip.window(count: count, current: current, slots: strip.slots)
        let thumbTop = stripTop + (stripHeight - strip.thumb) / 2
        guard p.y >= thumbTop, p.y <= thumbTop + strip.thumb, let slot = strip.slot(atX: p.x),
              window.lowerBound + slot < window.upperBound else { return .none }
        return .thumb(window.lowerBound + slot)
    }

    /// The card picture. Its size in points is the image size divided by `scale`.
    /// `fallbackAspect` is used while the shown image is still loading.
    static func render(_ images: [AgentImage], current: Int?, title: String, loader: ImageLoader,
                       now: Date, fallbackAspect: CGFloat?, scale: CGFloat = 2) -> CGImage? {
        let shown = current.flatMap { images.indices.contains($0) ? images[$0] : nil }
        let full = shown.flatMap { loader.image($0.path, maxPixel: 1400) }
        let imageAspect = full.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? fallbackAspect
        let size = ImageCardShape.size(imageAspect: shown == nil ? nil : imageAspect, width: width,
                                       stripHeight: stripHeight)
        let stripTop = size.height - stripHeight
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.current = previous }

        NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()

        let area = NSRect(x: 0, y: 0, width: size.width, height: stripTop)
        guard let current, let shown else {
            pill(title, at: NSPoint(x: 10, y: 10), align: .left)
            pill("No images yet", at: NSPoint(x: area.midX, y: area.midY - 11), align: .center)
            return ctx.makeImage()
        }
        // Very tall or wide images do not fill the card. A blurred copy fills the rest, instead of
        // black bars.
        if let soft = loader.image(shown.path, maxPixel: 160, blurred: true) {
            draw(soft, in: area, ctx: ctx, fill: true)
            NSColor(white: 0, alpha: 0.45).setFill()
            area.fill()
        }
        if let full { draw(full, in: area, ctx: ctx, fill: false) }

        pill((shown.kind == .shared ? "★  " : "") + title, at: NSPoint(x: 10, y: 10), align: .left)
        pill("\(current + 1) / \(images.count)", at: NSPoint(x: size.width - 10, y: 10), align: .right)
        let name = (shown.path as NSString).lastPathComponent
        pill([name, shown.time.map { ago($0, now: now) }].compactMap { $0 }.joined(separator: " · "),
             at: NSPoint(x: 10, y: stripTop - 32), align: .left)

        filmStrip(images, current: current, stripTop: stripTop, loader: loader, ctx: ctx)
        return ctx.makeImage()
    }

    private static func filmStrip(_ images: [AgentImage], current: Int, stripTop: CGFloat, loader: ImageLoader,
                                  ctx: CGContext) {
        NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: stripTop, width: width, height: stripHeight).fill()
        let window = ImageStrip.window(count: images.count, current: current, slots: strip.slots)
        let top = stripTop + (stripHeight - strip.thumb) / 2
        for (slot, i) in window.enumerated() {
            let r = NSRect(x: strip.inset + CGFloat(slot) * (strip.thumb + strip.gap), y: top,
                           width: strip.thumb, height: strip.thumb)
            let rounded = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
            NSColor(white: 1, alpha: 0.08).setFill()
            rounded.fill()
            if let thumb = loader.image(images[i].path, maxPixel: thumbPixels) {
                ctx.saveGState()
                rounded.addClip()
                draw(thumb, in: r, ctx: ctx, fill: true)
                ctx.restoreGState()
                if i != current {
                    NSColor(white: 0, alpha: 0.25).setFill()
                    rounded.fill()
                }
            }
            if images[i].kind == .shared {
                NSColor.systemYellow.setStroke()
                outline(r.insetBy(dx: 1, dy: 1), width: 2)
            }
            if i == current {
                NSColor.white.setStroke()
                outline(r.insetBy(dx: -1.5, dy: -1.5), width: 2)
            }
        }
    }

    private static func outline(_ r: NSRect, width: CGFloat) {
        let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        p.lineWidth = width
        p.stroke()
    }

    /// Draws `image` into `r`: fit (whole image shows) or fill (crop to cover).
    private static func draw(_ image: CGImage, in r: NSRect, ctx: CGContext, fill: Bool) {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0 else { return }
        let s = fill ? max(r.width / iw, r.height / ih) : min(r.width / iw, r.height / ih)
        let dw = iw * s, dh = ih * s
        let dest = CGRect(x: r.midX - dw / 2, y: r.midY - dh / 2, width: dw, height: dh)
        // The context is flipped (top-left origin); flip back so the picture is upright.
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.translateBy(x: 0, y: dest.minY + dest.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: dest)
        ctx.restoreGState()
    }

    private enum Align { case left, center, right }

    private static func pill(_ s: String, at p: NSPoint, align: Align) {
        guard !s.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.white,
                                                              .paragraphStyle: para])
        let w = min(320, ceil(text.size().width) + 18), h: CGFloat = 22
        let x = switch align {
        case .left: p.x
        case .center: p.x - w / 2
        case .right: p.x - w
        }
        let box = NSRect(x: x, y: p.y, width: w, height: h)
        NSColor(white: 0, alpha: 0.5).setFill()
        NSBezierPath(roundedRect: box, xRadius: 11, yRadius: 11).fill()
        text.draw(with: box.insetBy(dx: 9, dy: 4), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private static func ago(_ date: Date, now: Date) -> String {
        let s = Int(max(0, now.timeIntervalSince(date)))
        switch s {
        case ..<10: return "now"
        case ..<60: return "\(s)s ago"
        case ..<3600: return "\(s / 60)m ago"
        default: return "\(s / 3600)h ago"
        }
    }
}
