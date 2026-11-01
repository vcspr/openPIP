import AppKit
import CoreImage
import OpenPiPCore

/// Borderless, see-through floating panel that never takes focus. Only the cards are drawn,
/// so clicks on empty parts fall through to the windows below.
final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false // each card draws its own shadow
        minSize = NSSize(width: 200, height: 140)
        // Keep the panel out of agents' own screenshots where macOS honours this.
        // OPENPIP_SHOW_IN_CAPTURE=1 lets it be screenshotted or recorded (demos, tests).
        sharingType = ProcessInfo.processInfo.environment["OPENPIP_SHOW_IN_CAPTURE"] == "1" ? .readOnly : .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// What one card shows. Front card first in `PanelController.setCards`.
struct CardModel {
    var id: UInt32
    var surface: IOSurfaceRef?
    var aspect: CGFloat
    /// Small label over the card, e.g. "Window not visible". nil shows none.
    var note: String?
}

@MainActor
final class PanelController {
    private static let autosaveName = "OpenPiPPanel"

    let panel = FloatingPanel()
    private let view = PanelView()

    init() {
        panel.contentView = view
        let restored = panel.setFrameUsingName(Self.autosaveName)
        panel.setFrameAutosaveName(Self.autosaveName)
        if !restored { resetPosition() }
    }

    var contextMenu: NSMenu? {
        get { view.menu }
        set { view.menu = newValue }
    }

    /// Called with a window id when a back card is clicked.
    var onCardClick: ((UInt32) -> Void)? {
        get { view.onCardClick }
        set { view.onCardClick = newValue }
    }

    var opacity: Double {
        get { panel.alphaValue }
        set { panel.alphaValue = max(0.2, min(1, newValue)) }
    }

    var clickThrough: Bool {
        get { panel.ignoresMouseEvents }
        set { panel.ignoresMouseEvents = newValue }
    }

    func setVisible(_ visible: Bool) {
        if visible, !panel.isVisible {
            panel.orderFrontRegardless()
        } else if !visible, panel.isVisible {
            panel.orderOut(nil)
        }
    }

    func resetPosition() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 440, height: 320)
        panel.setFrame(NSRect(x: screen.maxX - size.width - 8, y: screen.minY + 8,
                              width: size.width, height: size.height), display: true)
    }

    /// Replaces the whole stack. Cards slide to their new places.
    func setCards(_ cards: [CardModel]) {
        view.setCards(cards)
    }

    /// Fast path for a new live frame on one card.
    func setFrame(_ surface: IOSurfaceRef, for id: UInt32) {
        view.setFrame(surface, for: id)
    }

    /// A small pill shown when there are no cards, e.g. the agent's caption. nil hides it.
    func setPlaceholder(_ text: String?) {
        view.setPlaceholder(text)
    }
}

/// Draws the card stack with Core Animation layers.
final class PanelView: NSView {
    private static let layout = CardLayout()
    private static let cornerRadius: CGFloat = 10
    private static let edge: CGFloat = 8
    private static let blurRadius: CGFloat = 3

    var onCardClick: ((UInt32) -> Void)?

    private var cards: [CardModel] = []
    private var layers: [UInt32: CardLayer] = [:]
    private var frames: [CGRect] = []
    private let placeholder = PillLayer()

    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
    }
    private var dragEdges: Edges = []
    private var startFrame = NSRect.zero
    private var startMouse = NSPoint.zero

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 320))
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.backgroundColor = NSColor.clear.cgColor
        placeholder.isHidden = true
        layer?.addSublayer(placeholder)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        placeholder.setScale(scale)
        layers.values.forEach { $0.setScale(scale) }
    }

    func setCards(_ newCards: [CardModel]) {
        let scale = window?.backingScaleFactor ?? 2
        let keep = Set(newCards.map(\.id))
        for (id, l) in layers where !keep.contains(id) {
            l.removeFromSuperlayer()
            layers[id] = nil
        }
        for (index, card) in newCards.enumerated() {
            let l = layers[card.id] ?? {
                let l = CardLayer()
                l.setScale(scale)
                layer?.addSublayer(l)
                layers[card.id] = l
                return l
            }()
            if let surface = card.surface { l.setContent(surface) }
            l.setNote(card.note)
            l.zPosition = CGFloat(-index)
            l.setBack(depth: index, blurRadius: Self.blurRadius)
        }
        cards = newCards
        relayout(animated: true)
    }

    func setFrame(_ surface: IOSurfaceRef, for id: UInt32) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        layers[id]?.setContent(surface)
        let aspect = CGFloat(IOSurfaceGetWidth(surface)) / CGFloat(max(1, IOSurfaceGetHeight(surface)))
        if abs(aspect - cards[index].aspect) > 0.01 {
            cards[index].aspect = aspect
            relayout(animated: false)
        }
    }

    func setPlaceholder(_ text: String?) {
        placeholder.setText(text)
        placeholder.isHidden = text == nil
        relayout(animated: false)
    }

    override func layout() {
        super.layout()
        relayout(animated: false)
    }

    private func relayout(animated: Bool) {
        frames = Self.layout.frames(in: bounds, aspects: cards.map(\.aspect))
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.25)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        for (card, frame) in zip(cards, frames) {
            layers[card.id]?.place(in: frame, cornerRadius: Self.cornerRadius)
        }
        let size = placeholder.preferredSize
        placeholder.frame = CGRect(x: bounds.maxX - size.width - 14, y: 14, width: size.width, height: size.height)
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: mouse

    /// Front-most card under the point, as an index into `cards`.
    private func cardIndex(at p: NSPoint, slop: CGFloat = 0) -> Int? {
        frames.indices.first { frames[$0].insetBy(dx: -slop, dy: -slop).contains(p) }
    }

    // Only cards (and the pill) take clicks. Empty space belongs to the windows below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        if cardIndex(at: p, slop: Self.edge / 2) != nil { return self }
        if !placeholder.isHidden, placeholder.frame.contains(p) { return self }
        return nil
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func edges(at p: NSPoint) -> Edges {
        guard let f = frames.first else { return [] }
        let e = Self.edge
        var r: Edges = []
        if abs(p.x - f.minX) < e { r.insert(.left) }
        if abs(p.x - f.maxX) < e { r.insert(.right) }
        if abs(p.y - f.minY) < e { r.insert(.bottom) }
        if abs(p.y - f.maxY) < e { r.insert(.top) }
        return r
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragEdges = edges(at: p)
        if dragEdges.isEmpty, let i = cardIndex(at: p), i > 0 {
            onCardClick?(cards[i].id)
            return
        }
        if dragEdges.isEmpty {
            window.performDrag(with: event)
            return
        }
        startFrame = window.frame
        startMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragEdges.isEmpty, let window else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - startMouse.x, dy = m.y - startMouse.y
        let minSize = window.minSize
        var f = startFrame
        if dragEdges.contains(.right) { f.size.width = max(minSize.width, startFrame.width + dx) }
        if dragEdges.contains(.left) {
            f.size.width = max(minSize.width, startFrame.width - dx)
            f.origin.x = startFrame.maxX - f.size.width
        }
        if dragEdges.contains(.top) { f.size.height = max(minSize.height, startFrame.height + dy) }
        if dragEdges.contains(.bottom) {
            f.size.height = max(minSize.height, startFrame.height - dy)
            f.origin.y = startFrame.maxY - f.size.height
        }
        window.setFrame(f, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        dragEdges = []
    }

    override func resetCursorRects() {
        guard let f = frames.first else { return }
        let e = Self.edge
        addCursorRect(NSRect(x: f.minX - e, y: f.minY + e, width: 2 * e, height: f.height - 2 * e), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: f.maxX - e, y: f.minY + e, width: 2 * e, height: f.height - 2 * e), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: f.minX + e, y: f.minY - e, width: f.width - 2 * e, height: 2 * e), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: f.minX + e, y: f.maxY - e, width: f.width - 2 * e, height: 2 * e), cursor: .resizeUpDown)
        for i in frames.indices.dropFirst() {
            addCursorRect(frames[i], cursor: .pointingHand)
        }
    }
}

/// One card: soft shadow outside, rounded clip inside, the window picture, and an optional note.
final class CardLayer: CALayer {
    private let clip = CALayer()
    private let content = CALayer()
    private let veil = CALayer()
    private let note = PillLayer()

    override init() {
        super.init()
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.28
        shadowRadius = 14
        shadowOffset = CGSize(width: 0, height: -5)

        clip.masksToBounds = true
        clip.borderWidth = 0.5
        clip.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        // Shown only until the first frame arrives: a light frosted card, not a black box.
        clip.backgroundColor = NSColor(white: 0.92, alpha: 0.35).cgColor
        addSublayer(clip)

        content.contentsGravity = .resize
        clip.addSublayer(content)

        veil.backgroundColor = NSColor(white: 0.85, alpha: 1).cgColor
        veil.opacity = 0
        clip.addSublayer(veil)

        note.isHidden = true
        addSublayer(note)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    func setScale(_ scale: CGFloat) {
        contentsScale = scale
        note.setScale(scale)
    }

    func setContent(_ surface: IOSurfaceRef) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.contents = surface
        CATransaction.commit()
    }

    func setNote(_ text: String?) {
        note.setText(text)
        note.isHidden = text == nil
        placeNote()
    }

    /// Depth 0 is the live front card. Older cards get a light blur and a soft light veil.
    /// They stay solid, so whatever is behind the panel does not bleed through.
    func setBack(depth: Int, blurRadius: CGFloat) {
        if depth == 0 {
            content.filters = nil
            veil.opacity = 0
        } else {
            // Clamp first so the blur does not pull transparent edge pixels in.
            let clamp = CIFilter(name: "CIAffineClamp")
            clamp?.setValue(NSAffineTransform(), forKey: kCIInputTransformKey)
            let blur = CIFilter(name: "CIGaussianBlur")
            blur?.setValue(blurRadius * CGFloat(depth), forKey: kCIInputRadiusKey)
            content.filters = [clamp, blur].compactMap { $0 }
            veil.opacity = Float(min(0.45, 0.22 * Double(depth)))
        }
    }

    func place(in frame: CGRect, cornerRadius: CGFloat) {
        self.frame = frame
        let local = CGRect(origin: .zero, size: frame.size)
        shadowPath = CGPath(roundedRect: local, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        clip.frame = local
        clip.cornerRadius = cornerRadius
        content.frame = local
        veil.frame = local
        placeNote()
    }

    private func placeNote() {
        let size = note.preferredSize
        note.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                            width: size.width, height: size.height)
    }
}

/// Small rounded translucent label.
final class PillLayer: CALayer {
    private let text = CATextLayer()
    private static let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    override init() {
        super.init()
        backgroundColor = NSColor(white: 0.1, alpha: 0.55).cgColor
        cornerRadius = 9
        text.font = Self.font
        text.fontSize = Self.font.pointSize
        text.foregroundColor = NSColor.white.cgColor
        text.alignmentMode = .center
        text.truncationMode = .end
        addSublayer(text)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    func setScale(_ scale: CGFloat) {
        contentsScale = scale
        text.contentsScale = scale
    }

    func setText(_ value: String?) {
        text.string = value ?? ""
    }

    var preferredSize: CGSize {
        let s = (text.string as? String ?? "") as NSString
        let w = s.size(withAttributes: [.font: Self.font]).width
        return CGSize(width: min(320, ceil(w) + 20), height: 22)
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        text.frame = bounds.insetBy(dx: 10, dy: 4)
    }
}
