import AppKit
import OpenPiPCore

/// Draws an agent session as a card picture: header, progress, task list, last step, terminal.
enum SessionCardRenderer {
    static let size = CGSize(width: 560, height: 420)
    static var aspect: CGFloat { size.width / size.height }

    private static let pad: CGFloat = 18
    private static let activeWithin: TimeInterval = 30

    /// `hasImages` draws the "Actions | Images" switch in the top-right corner.
    static func render(_ s: SessionState, label: String, now: Date, hasImages: Bool = false,
                       scale: CGFloat = 2) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Top-left origin in points, like a flipped view.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.current = previous }

        draw(s, label: label, now: now, hasImages: hasImages)
        return ctx.makeImage()
    }

    private static func draw(_ s: SessionState, label: String, now: Date, hasImages: Bool) {
        let width = size.width, inner = width - 2 * pad
        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()

        // Header
        let active = s.lastTimestamp.map { now.timeIntervalSince($0) < activeWithin } ?? false
        (active ? NSColor.systemGreen : NSColor.systemGray).setFill()
        NSBezierPath(ovalIn: NSRect(x: pad, y: 23, width: 8, height: 8)).fill()

        let (done, total) = s.progress
        let count = total > 0 ? "\(done)/\(total)" : ""
        let countWidth = text(count, font: .systemFont(ofSize: 13, weight: .semibold), color: .white)
            .size().width
        // The header ends at the card edge, or at the switch when there is one.
        let headerEnd = hasImages ? CardSwitch.frame(cardWidth: width).minX - 10 : width - pad
        if hasImages { CardSwitchView.draw(active: .actions, cardWidth: width) }
        line(s.title ?? label, at: NSPoint(x: pad + 16, y: 16), width: headerEnd - pad - 16 - countWidth - 12,
             font: .systemFont(ofSize: 15, weight: .semibold), color: .white)
        line(count, at: NSPoint(x: headerEnd - countWidth, y: 18), width: countWidth + 1,
             font: .systemFont(ofSize: 13, weight: .semibold), color: NSColor(white: 1, alpha: 0.85))
        let sub = [s.title == nil ? nil : label, s.lastTimestamp.map { ago($0, now: now) }].compactMap { $0 }
        line(sub.joined(separator: " · "), at: NSPoint(x: pad + 16, y: 38), width: inner - 16,
             font: .systemFont(ofSize: 11), color: NSColor(white: 1, alpha: 0.5))

        var y: CGFloat = 62
        if total > 0 {
            let bar = NSRect(x: pad, y: y, width: inner, height: 4)
            NSColor(white: 1, alpha: 0.1).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: pad, y: y, width: inner * CGFloat(done) / CGFloat(total), height: 4),
                         xRadius: 2, yRadius: 2).fill()
            y += 14

            let maxRows = s.terminal.isEmpty ? 12 : 6
            let firstOpen = s.tasks.firstIndex { $0.status != .completed } ?? max(0, s.tasks.count - 1)
            let start = max(0, min(firstOpen - 1, s.tasks.count - maxRows))
            for task in s.tasks[start..<min(s.tasks.count, start + maxRows)] {
                let (mark, markColor, textColor, weight): (String, NSColor, NSColor, NSFont.Weight) = switch task.status {
                case .completed: ("✓", .systemGreen, NSColor(white: 1, alpha: 0.45), .regular)
                case .inProgress: ("◉", .controlAccentColor, .white, .semibold)
                case .pending: ("○", NSColor(white: 1, alpha: 0.4), NSColor(white: 1, alpha: 0.8), .regular)
                }
                line(mark, at: NSPoint(x: pad, y: y), width: 16, font: .systemFont(ofSize: 12, weight: .bold), color: markColor)
                line(task.title, at: NSPoint(x: pad + 18, y: y), width: inner - 18,
                     font: .systemFont(ofSize: 12.5, weight: weight), color: textColor)
                y += 20
            }
            y += 4
        }

        if let action = s.lastAction {
            line("▸ " + action, at: NSPoint(x: pad, y: y), width: inner,
                 font: NSFontManager.shared.convert(.systemFont(ofSize: 12), toHaveTrait: .italicFontMask),
                 color: NSColor(white: 1, alpha: 0.6))
            y += 22
        }

        if s.terminal.isEmpty {
            if total == 0, s.lastAction == nil {
                line("Waiting for activity…", at: NSPoint(x: pad, y: y), width: inner,
                     font: .systemFont(ofSize: 12), color: NSColor(white: 1, alpha: 0.5))
            }
            return
        }
        terminal(s.terminal, in: NSRect(x: pad, y: y + 2, width: inner, height: size.height - pad - y - 2))
    }

    /// Newest commands at the bottom; older lines scroll off the top.
    private static func terminal(_ entries: [TerminalEntry], in box: NSRect) {
        guard box.height > 30 else { return }
        NSColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 1).setFill()
        let path = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        path.fill()
        NSColor(white: 1, alpha: 0.08).setStroke()
        path.stroke()

        let mono = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let lineHeight: CGFloat = 14.5
        var rows: [(String, NSColor, String, NSColor)] = []
        for e in entries {
            let promptColor: NSColor = e.running ? .systemYellow : (e.failed ? .systemRed : .systemGreen)
            for (i, cmd) in e.command.split(whereSeparator: \.isNewline).prefix(3).enumerated() {
                rows.append((i == 0 ? (e.running ? "… " : "$ ") : "  ", promptColor, String(cmd), .white))
            }
            for out in e.output { rows.append(("", .clear, out, NSColor(white: 1, alpha: e.failed ? 0.7 : 0.5))) }
        }
        let fit = Int((box.height - 16) / lineHeight)
        var y = box.minY + 8
        for (prompt, pColor, body, bColor) in rows.suffix(fit) {
            var x = box.minX + 10
            if !prompt.isEmpty {
                line(prompt, at: NSPoint(x: x, y: y), width: 18, font: mono, color: pColor)
                x += 16
            }
            line(body, at: NSPoint(x: x, y: y), width: box.maxX - 10 - x, font: mono, color: bColor)
            y += lineHeight
        }
    }

    private static func text(_ s: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
    }

    private static func line(_ s: String, at p: NSPoint, width: CGFloat, font: NSFont, color: NSColor) {
        guard width > 0, !s.isEmpty else { return }
        text(s, font: font, color: color)
            .draw(with: NSRect(x: p.x, y: p.y, width: width, height: font.pointSize * 1.4),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
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
