import AppKit
import ScreenCaptureKit
import OpenPiPCore

/// Wires the pieces together: events -> auto-hide + window stack -> capture of the front window -> panel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// One window in the stack and the last picture we have of it.
    private struct Card {
        var info: WindowInfo
        var surface: IOSurfaceRef?
        var aspect: CGFloat
        var note: String?
        var hidden: Bool
    }

    /// An agent session shown as a drawn card: tasks, last step, terminal.
    private final class TrackedSession {
        let url: URL
        var label: String
        let watcher: SessionWatcher
        var state = SessionState()
        var image: CGImage?
        /// Id of this session's image card.
        let imageID: UInt32
        let trackedAt = Date()
        /// New images in the work folder ("Show All New Images"), with their dates.
        var found: [String: Date] = [:]
        var scanning = false

        init(url: URL, label: String, imageID: UInt32) {
            self.url = url
            self.label = label
            self.imageID = imageID
            watcher = SessionWatcher(url: url)
        }
    }

    /// The images of one tracked session, with a film strip to browse them.
    private final class ImageCard {
        let sessionID: UInt32
        var list: [AgentImage] = []
        var browser = ImageBrowser()
        var image: CGImage?
        /// Size of the drawn card in points; it follows the shown image's shape.
        var size = CGSize(width: ImageCardRenderer.width, height: 480)
        /// Shape of the image shown last, used while the next one loads.
        var lastAspect: CGFloat?
        /// Set once the card was in the stack. After that it comes back only for a new image.
        var shown = false
        var scroll: CGFloat = 0

        init(sessionID: UInt32) { self.sessionID = sessionID }
    }

    private let panel = PanelController()
    private let capture = CaptureSession()
    private let picker = WindowPicker()
    private let hotKey = HotKey()
    private var server: EventServer?
    private var welcome: WelcomeWindowController?

    private var statusItem: NSStatusItem!
    private let mainMenu = NSMenu()
    private let windowMenu = NSMenu()
    private let stackSizeMenu = NSMenu()
    private let statusLine = NSMenuItem(title: "Waiting for an agent", action: nil, keyEquivalent: "")
    private var followItem: NSMenuItem!
    private var alwaysShowItem: NSMenuItem!
    private var clickThroughItem: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var clearItem: NSMenuItem!
    private var cursorItem: NSMenuItem!
    private let agentsMenu = NSMenu()
    private var autoTrackItem: NSMenuItem!

    private var autoHide = AutoHide()
    private let denyList = DenyList(extra: Settings.extraDenyList)
    private var stack = CardStack(limit: Settings.maxCards)
    private var cards: [UInt32: Card] = [:]
    private var sessions: [UInt32: TrackedSession] = [:]
    private var imageCards: [UInt32: ImageCard] = [:]
    private let loader = ImageLoader()
    private var imageRedrawQueued = false
    private var lastFolderScan = Date.distantPast
    /// Session cards get ids far above any window id, so the two kinds never collide. A session's
    /// image card id is its own id minus `imageIDOffset`.
    private var nextSessionID: UInt32 = 0xF000_0000
    private static let imageIDOffset: UInt32 = 0x1000_0000
    private var openImageItem: NSMenuItem!
    private var revealImageItem: NSMenuItem!
    private var showAllImagesItem: NSMenuItem!
    private var switchItem: NSMenuItem!
    private let scanner = AgentScanner()
    private var activeAgents: [AgentSession] = []
    private var lastAgentScan = Date.distantPast
    private var lastSessionRedraw = Date.distantPast
    /// Latest caption, shown as a pill only while there is no window to mirror.
    private var caption: String?
    /// True while the front window should be streaming. Cleared when the stream fails, so we do not retry in a loop.
    private var wantsCapture = false
    private var paused = false
    private var lastWindowCheck = Date.distantPast
    private var tickTimer: Timer?

    private var front: Card? { stack.front.flatMap { cards[$0] } }

    // MARK: launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        autoHide.alwaysShow = Settings.alwaysShow
        panel.opacity = Settings.opacity
        panel.clickThrough = Settings.clickThrough
        buildMenu()
        panel.contextMenu = mainMenu
        panel.onCardClick = { [weak self] id in self?.bringToFront(id) }
        panel.onFrontClick = { [weak self] id, point in self?.frontClicked(id, at: point) }
        panel.onFrontScroll = { [weak self] id, delta, precise in self?.frontScrolled(id, delta: delta, precise: precise) }
        loader.onLoad = { [weak self] in self?.queueImageRedraw() }

        capture.onFrame = { [weak self] surface in
            guard let self, let id = self.capture.windowID, self.cards[id] != nil else { return }
            self.cards[id]?.surface = surface
            self.panel.setFrame(surface, for: id)
            self.autoHide.frameChanged(at: Date())
        }
        capture.onStop = { [weak self] reason in
            guard let self, let id = self.stack.front else { return }
            self.wantsCapture = false
            self.cards[id]?.note = reason
            self.render()
        }

        let server = EventServer { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            caption = "Event socket failed: \(error.localizedDescription)"
            statusLine.title = caption ?? ""
        }

        hotKey.register { [weak self] in
            MainActor.assumeIsolated { self?.toggleClickThrough() }
        }

        if !Permissions.hasScreenRecording { showWelcome() }

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        render()
        tick()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    // MARK: events

    private func handle(_ event: Event) {
        autoHide.event(event.status, at: Date())
        let text = event.text.isEmpty ? "\(event.agent): \(event.status.rawValue)" : event.text
        caption = text
        statusLine.title = "\(event.agent): \(text)"
        statusItem.button?.toolTip = statusLine.title

        let hasHint = event.app != nil || event.window != nil || event.pid != nil
        if Settings.followAgent, hasHint, !paused {
            // Skip the window lookup when the event still points at the front window.
            let alreadyThere = front.map { WindowMatcher.isSameWindow(event, $0.info) } ?? false
            if alreadyThere && capture.state != .idle {
                showCursor(for: event, on: front?.info)
            } else {
                Task {
                    let list = await picker.refresh()
                    if let match = WindowMatcher.match(event, in: list) {
                        mirror(match)
                        showCursor(for: event, on: match)
                    } else if stack.front == nil {
                        caption = "No window found for \(event.app ?? event.window ?? "this agent")"
                        render()
                    }
                }
            }
        } else if let front, WindowMatcher.isSameWindow(event, front.info) {
            showCursor(for: event, on: front.info)
        }
        if event.status == .end || event.status == .error, let id = stack.front {
            panel.setCursor(nil, for: id, click: false)
        }
        render()
        tick()
    }

    /// Moves the agent cursor on `window`'s card when the event carries a point. Events without a
    /// point leave the cursor where it was.
    private func showCursor(for event: Event, on window: WindowInfo?) {
        guard Settings.showCursor, event.x != nil, event.y != nil,
              let window, window.id == stack.front, cards[window.id]?.hidden == false else { return }
        let fraction = CursorMapper.fraction(for: event, windowFrame: window.frame,
                                             scale: WindowPicker.displayScale(for: window.frame))
        panel.setCursor(fraction, for: window.id, click: fraction != nil)
    }

    // MARK: stack

    /// Puts `window` at the front of the stack and streams it. The old front card keeps its last frame.
    private func mirror(_ window: WindowInfo) {
        let switching = window.id != stack.front
        forget(stack.push(window.id))

        let hidden = denyList.isDenied(bundleID: window.bundleID)
        var card = cards[window.id] ?? Card(info: window, surface: nil,
                                            aspect: aspect(of: window.id), note: nil, hidden: hidden)
        card.info = window
        card.hidden = hidden
        if hidden { card.surface = nil }
        card.note = hidden ? "Hidden for privacy" : (window.isOnScreen ? nil : Self.notVisible)
        cards[window.id] = card
        wantsCapture = !hidden
        render()

        if switching, capture.state != .idle {
            Task {
                await capture.stop()
                startCaptureIfNeeded()
            }
        } else {
            startCaptureIfNeeded()
        }
    }

    private func aspect(of id: UInt32) -> CGFloat {
        guard let f = picker.scWindow(id: id)?.frame, f.height > 0 else { return 4.0 / 3.0 }
        return f.width / f.height
    }

    private func bringToFront(_ id: UInt32) {
        if imageCards[id] != nil {
            forget(stack.push(id))
            autoHide.pinned = true
            render()
            tick()
            return
        }
        if sessions[id] != nil {
            showSession(id)
            autoHide.pinned = true
            return
        }
        // Clicking a card is a manual pick: it wins over auto-follow until "Follow Agent" is back on.
        Settings.followAgent = false
        autoHide.pinned = true
        Task {
            await picker.refresh()
            if let sc = picker.scWindow(id: id) {
                mirror(WindowPicker.info(sc))
            } else {
                drop(id)
            }
        }
    }

    /// Takes a closed window out of the stack. If it was the front one, the next card goes live.
    private func drop(_ id: UInt32) {
        let wasFront = id == stack.front
        stack.remove(id)
        cards[id] = nil
        if wasFront {
            Task { await capture.stop() }
            if let next = front, !next.hidden {
                wantsCapture = true
                startCaptureIfNeeded()
            } else {
                wantsCapture = false
            }
        }
        render()
    }

    private static let notVisible = "Window not visible (minimized or on another Space)"

    private func render() {
        if paused {
            panel.setCards([])
            panel.setPlaceholder("Paused")
            return
        }
        let models = stack.ids.compactMap { id -> CardModel? in
            if let t = sessions[id] {
                return CardModel(id: id, content: t.image, aspect: SessionCardRenderer.aspect, note: nil)
            }
            if let c = imageCards[id] {
                return CardModel(id: id, content: c.image, aspect: c.size.width / c.size.height, note: nil)
            }
            guard let c = cards[id] else { return nil }
            return CardModel(id: id, content: c.hidden ? nil : c.surface, aspect: c.aspect, note: c.note)
        }
        panel.setCards(models)
        panel.setPlaceholder(models.isEmpty ? (caption ?? "Waiting for an agent") : nil)
    }

    private func startCaptureIfNeeded() {
        guard wantsCapture, !paused, autoHide.isVisible(at: Date()),
              capture.state == .idle, let id = stack.front, cards[id] != nil else { return }
        guard let scWindow = picker.scWindow(id: id) else {
            drop(id)
            return
        }
        Task {
            do {
                try await capture.start(scWindow)
            } catch {
                wantsCapture = false
                cards[id]?.note = Permissions.hasScreenRecording
                    ? "Cannot capture: \(error.localizedDescription)"
                    : "Screen Recording not granted"
                render()
            }
        }
    }

    /// Runs twice a second: show or hide the panel, pause capture while hidden, notice closed windows.
    private func tick() {
        let now = Date()
        autoTrackIfNeeded(now: now)
        let visible = autoHide.isVisible(at: now)
        panel.setVisible(visible)

        if !visible {
            if capture.state != .idle { Task { await capture.stop() } }
            return
        }
        startCaptureIfNeeded()
        if now.timeIntervalSince(lastSessionRedraw) > 5 {
            lastSessionRedraw = now
            sessions.keys.forEach(redraw)
            for id in stack.ids where imageCards[id] != nil { redrawImage(id) }
        }
        if Settings.showAllNewImages, now.timeIntervalSince(lastFolderScan) > 10 {
            lastFolderScan = now
            sessions.keys.forEach(scanFolder)
        }

        if front != nil, now.timeIntervalSince(lastWindowCheck) > 2 {
            lastWindowCheck = now
            Task { await checkStillThere() }
        }
    }

    /// Drops closed windows and updates the "not visible" note on the front card.
    private func checkStillThere() async {
        let list = await picker.refresh()
        guard picker.lastError == nil else { return }
        let alive = Set(list.map(\.id))
        for id in stack.ids where cards[id] != nil && !alive.contains(id) { drop(id) }

        guard let id = stack.front, let now = list.first(where: { $0.id == id }),
              var card = cards[id], !card.hidden else { return }
        card.info = now
        if !now.isOnScreen {
            card.note = Self.notVisible
        } else if card.note == Self.notVisible || card.note == "Window not visible" {
            card.note = nil
            wantsCapture = true
        }
        cards[id] = card
        render()
        startCaptureIfNeeded()
    }

    // MARK: agent sessions

    /// Starts showing an agent session as a card at the front of the stack.
    private func track(_ agent: AgentSession) {
        if let id = sessions.first(where: { $0.value.url == agent.url })?.key {
            showSession(id)
            return
        }
        let id = nextSessionID
        nextSessionID &+= 1
        let t = TrackedSession(url: agent.url, label: agent.label, imageID: id &- Self.imageIDOffset)
        t.state = SessionState()
        sessions[id] = t
        t.watcher.onChange = { [weak self] state in
            guard let self, let t = self.sessions[id] else { return }
            t.state = state
            self.redraw(id)
            self.sessionChanged(id)
            self.imagesChanged(id)
        }
        redraw(id)
        t.watcher.start()
        showSession(id)
    }

    private func untrack(_ id: UInt32) {
        stack.remove(id)
        stopSession(id)
        if let next = front, !next.hidden { wantsCapture = true }
        render()
        tick()
    }

    private func showSession(_ id: UInt32) {
        let wasFront = stack.front
        forget(stack.push(id))
        if wasFront != id, capture.state != .idle { Task { await capture.stop() } }
        wantsCapture = false
        render()
        tick()
    }

    /// A tracked agent did something: show the panel, and bring its card forward when the front
    /// card is a quiet session (window cards driven by events stay where they are).
    private func sessionChanged(_ id: UInt32) {
        guard let t = sessions[id], let when = t.state.lastTimestamp, Date().timeIntervalSince(when) < 30 else { return }
        autoHide.event(.step, at: Date())
        guard Settings.followAgent, stack.front != id else { tick(); return }
        let frontIsQuietSession = stack.front.flatMap { sessions[$0] }.map {
            Date().timeIntervalSince($0.state.lastTimestamp ?? .distantPast) > 15
        } ?? (stack.front == nil)
        if frontIsQuietSession { showSession(id) } else { tick() }
    }

    private func redraw(_ id: UInt32) {
        guard let t = sessions[id],
              let image = SessionCardRenderer.render(t.state, label: t.label, now: Date(),
                                                     hasImages: imageCards[t.imageID] != nil) else { return }
        t.image = image
        panel.setImage(image, for: id)
    }

    /// Lets go of cards that left the stack: window cards are forgotten. A session stops once
    /// neither its session card nor its image card is in the stack.
    private func forget(_ ids: [UInt32]) {
        for id in ids {
            cards[id] = nil
            if let t = sessions[id], !stack.ids.contains(t.imageID) { stopSession(id) }
            if let c = imageCards[id], !stack.ids.contains(c.sessionID) { stopSession(c.sessionID) }
        }
    }

    private func stopSession(_ id: UInt32) {
        guard let t = sessions.removeValue(forKey: id) else { return }
        t.watcher.stop()
        stack.remove(t.imageID)
        imageCards[t.imageID] = nil
    }

    // MARK: image cards

    /// The images to show for a session: the ones from its log, plus new files in its work folder
    /// when "Show All New Images" is on. Deleted files drop out.
    private func displayImages(_ t: TrackedSession) -> [AgentImage] {
        var log = t.state.images
        if Settings.showAllNewImages {
            for (path, date) in t.found { log.addFound(path, at: date) }
        }
        return log.images.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A session's image list may have changed: add its image card, bring it forward for a new
    /// image, and redraw it.
    private func imagesChanged(_ sessionID: UInt32) {
        guard let t = sessions[sessionID] else { return }
        let list = displayImages(t)
        guard !list.isEmpty else { return }
        let id = t.imageID
        let isFirst = imageCards[id] == nil
        let card = imageCards[id] ?? ImageCard(sessionID: sessionID)
        imageCards[id] = card
        if isFirst { redraw(sessionID) } // the session card gets its Actions | Images switch
        let isNew = list.last?.path != card.list.last?.path
        card.list = list
        let fresh = list.last?.time.map { Date().timeIntervalSince($0) < 60 } ?? false
        // A window card driven by events keeps the front; session and image cards give way.
        let frontGivesWay = stack.front.map { sessions[$0] != nil || imageCards[$0] != nil } ?? true
        let inStack = stack.ids.contains(id)
        if isNew && fresh && Settings.followAgent && frontGivesWay && stack.front != id {
            forget(stack.push(id))
            autoHide.event(.step, at: Date())
        } else if !inStack && (!card.shown || (isNew && fresh)) {
            forget(stack.insertBehindFront(id))
        }
        if stack.ids.contains(id) { card.shown = true }
        redrawImage(id)
        if stack.ids.contains(id) != inStack || stack.front == id { render() }
        tick()
    }

    private func redrawImage(_ id: UInt32) {
        guard let card = imageCards[id], let t = sessions[card.sessionID] else { return }
        card.list = displayImages(t)
        let current = card.browser.current(in: card.list.map(\.path), now: Date())
        let title = t.state.title ?? t.label
        guard let image = ImageCardRenderer.render(card.list, current: current, title: title, loader: loader,
                                                   now: Date(), fallbackAspect: card.lastAspect) else { return }
        card.image = image
        card.size = CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        card.lastAspect = (card.size.height - ImageCardRenderer.stripHeight) > 0
            ? card.size.width / (card.size.height - ImageCardRenderer.stripHeight) : nil
        panel.setImage(image, for: id)
    }

    /// Thumbnails arrive one by one; redraw once per run of the main loop, not once per file.
    private func queueImageRedraw() {
        guard !imageRedrawQueued else { return }
        imageRedrawQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.imageRedrawQueued = false
                for id in self.stack.ids where self.imageCards[id] != nil { self.redrawImage(id) }
            }
        }
    }

    private func frontClicked(_ id: UInt32, at point: CGPoint) {
        // The "Actions | Images" switch on a session card or its image card.
        if let t = sessions[id], imageCards[t.imageID] != nil {
            let p = CGPoint(x: point.x * SessionCardRenderer.size.width, y: point.y * SessionCardRenderer.size.height)
            if CardSwitch.side(at: p, cardWidth: SessionCardRenderer.size.width) == .images { switchCards() }
            return
        }
        guard let card = imageCards[id] else { return }
        let size = card.size
        let local = CGPoint(x: point.x * size.width, y: point.y * size.height)
        if let side = CardSwitch.side(at: local, cardWidth: size.width) {
            if side == .actions { switchCards() }
            return
        }
        let paths = card.list.map(\.path)
        guard let current = card.browser.current(in: paths, now: Date()) else { return }
        switch ImageCardRenderer.hit(CGPoint(x: point.x * size.width, y: point.y * size.height),
                                     size: size, count: paths.count, current: current) {
        case .thumb(let i):
            card.browser.pick(paths[i], at: Date())
            autoHide.pinned = true
            redrawImage(id)
        case .image:
            openInPreview(paths[current])
        case .none:
            break
        }
    }

    private func frontScrolled(_ id: UInt32, delta: CGFloat, precise: Bool) {
        guard let card = imageCards[id] else { return }
        // Trackpads send many small deltas: one image per 24 points. A wheel moves one per notch.
        card.scroll += precise ? delta : (delta > 0 ? 24 : -24)
        let steps = Int(card.scroll / 24)
        guard steps != 0 else { return }
        card.scroll -= CGFloat(steps) * 24
        card.browser.step(-steps, in: card.list.map(\.path), at: Date())
        autoHide.pinned = true
        redrawImage(id)
    }

    /// The session card and image card of the same agent, when the front card is one of them.
    private var frontPair: (session: UInt32, image: UInt32)? {
        guard let id = stack.front else { return nil }
        if let t = sessions[id], imageCards[t.imageID] != nil { return (id, t.imageID) }
        if let c = imageCards[id], sessions[c.sessionID] != nil { return (c.sessionID, id) }
        return nil
    }

    /// Flips the front card between an agent's actions (session card) and its images.
    @objc private func switchCards() {
        guard let pair = frontPair else { return }
        autoHide.pinned = true
        if stack.front == pair.session {
            forget(stack.push(pair.image))
            redrawImage(pair.image)
            render()
            tick()
        } else {
            showSession(pair.session)
        }
    }

    /// The image shown on the front card, if the front card is an image card.
    private var frontImagePath: String? {
        guard let id = stack.front, let card = imageCards[id],
              let i = card.browser.current(in: card.list.map(\.path), now: Date()) else { return nil }
        return card.list[i].path
    }

    private func openInPreview(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openFrontImage() {
        if let path = frontImagePath { openInPreview(path) }
    }

    @objc private func revealFrontImage() {
        if let path = frontImagePath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    @objc private func toggleShowAllImages() {
        Settings.showAllNewImages.toggle()
        lastFolderScan = .distantPast
        sessions.keys.forEach(imagesChanged)
        tick()
    }

    /// Looks for new images in a session's work folder, off the main thread.
    private func scanFolder(_ sessionID: UInt32) {
        guard let t = sessions[sessionID], !t.scanning, let cwd = t.state.images.cwd else { return }
        t.scanning = true
        let since = t.trackedAt.addingTimeInterval(-30 * 60)
        Task.detached(priority: .utility) {
            let found = Self.newImages(in: cwd, since: since)
            await MainActor.run { [weak self] in
                guard let self, let t = self.sessions[sessionID] else { return }
                t.scanning = false
                if found != t.found {
                    t.found = found
                    self.imagesChanged(sessionID)
                }
            }
        }
    }

    /// Image files under `folder` changed since `since`: the newest few, at most 6 folders deep.
    /// Skips the home folder itself, hidden folders, packages and build folders, and stops after
    /// 30,000 files so a huge folder cannot stall it.
    nonisolated private static func newImages(in folder: String, since: Date) -> [String: Date] {
        guard folder != NSHomeDirectory(), folder != "/" else { return [:] }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(
            at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [:] }
        let skip: Set<String> = ["node_modules", "build", ".build", "DerivedData", "Pods", "venv"]
        var hits: [(String, Date)] = []
        var visited = 0
        while let url = walk.nextObject() as? URL {
            visited += 1
            if visited > 30_000 { break }
            if walk.level > 6 || skip.contains(url.lastPathComponent) {
                walk.skipDescendants()
                continue
            }
            guard ImageLog.isImagePath(url.path),
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let date = v.contentModificationDate, date > since else { continue }
            hits.append((url.path, date))
        }
        return Dictionary(hits.sorted { $0.1 > $1.1 }.prefix(ImageLog.limit).map { ($0.0, $0.1) },
                          uniquingKeysWith: { a, _ in a })
    }

    /// Looks for new agent sessions every 10 seconds while auto-track is on.
    private func autoTrackIfNeeded(now: Date) {
        guard Settings.autoTrackAgents, now.timeIntervalSince(lastAgentScan) > 10 else { return }
        lastAgentScan = now
        Task {
            let fresh = await scanner.active(within: 60)
            activeAgents = fresh
            for agent in fresh where !sessions.values.contains(where: { $0.url == agent.url }) {
                track(agent)
            }
        }
    }

    private func fillAgentsMenu() {
        agentsMenu.removeAllItems()
        let now = Date()
        if activeAgents.isEmpty {
            let none = NSMenuItem(title: "No agent worked in the last 15 minutes", action: nil, keyEquivalent: "")
            none.isEnabled = false
            agentsMenu.addItem(none)
        }
        for agent in activeAgents {
            let minutes = Int(now.timeIntervalSince(agent.modified) / 60)
            let age = minutes < 1 ? "now" : "\(minutes)m ago"
            let item = NSMenuItem(title: "\(String(agent.displayName.prefix(70)))  ·  \(age)",
                                  action: #selector(toggleAgent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = agent.url
            item.state = sessions.values.contains { $0.url == agent.url } ? .on : .off
            agentsMenu.addItem(item)
        }
        agentsMenu.addItem(.separator())
        autoTrackItem = NSMenuItem(title: "Auto-Track Active Agents", action: #selector(toggleAutoTrack), keyEquivalent: "")
        autoTrackItem.target = self
        autoTrackItem.state = Settings.autoTrackAgents ? .on : .off
        agentsMenu.addItem(autoTrackItem)
        showAllImagesItem = NSMenuItem(title: "Show All New Images", action: #selector(toggleShowAllImages), keyEquivalent: "")
        showAllImagesItem.target = self
        showAllImagesItem.state = Settings.showAllNewImages ? .on : .off
        showAllImagesItem.toolTip = "Image cards also list every new image in the agent's work folder"
        agentsMenu.addItem(showAllImagesItem)
        let note = NSMenuItem(title: "Reads Claude Code and OpenBot session logs on this Mac only", action: nil, keyEquivalent: "")
        note.isEnabled = false
        agentsMenu.addItem(note)
    }

    @objc private func toggleAgent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if let id = sessions.first(where: { $0.value.url == url })?.key {
            untrack(id)
        } else if let agent = activeAgents.first(where: { $0.url == url }) {
            autoHide.pinned = true
            track(agent)
        }
    }

    @objc private func toggleAutoTrack() {
        Settings.autoTrackAgents.toggle()
        lastAgentScan = .distantPast
        tick()
    }

    // MARK: menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pip", accessibilityDescription: "OpenPiP")
        statusItem.menu = mainMenu
        mainMenu.delegate = self

        statusLine.isEnabled = false
        mainMenu.addItem(statusLine)
        openImageItem = item("Open Image in Preview", #selector(openFrontImage))
        revealImageItem = item("Show Image in Finder", #selector(revealFrontImage))
        switchItem = item("Show Images", #selector(switchCards))
        mainMenu.addItem(.separator())

        let mirrorItem = NSMenuItem(title: "Mirror Window", action: nil, keyEquivalent: "")
        mirrorItem.submenu = windowMenu
        windowMenu.delegate = self
        mainMenu.addItem(mirrorItem)

        followItem = item("Follow Agent", #selector(toggleFollow))
        cursorItem = item("Show Agent Cursor", #selector(toggleCursor))
        clearItem = item("Clear Windows", #selector(clearWindows))
        let agentsItem = NSMenuItem(title: "Agents", action: nil, keyEquivalent: "")
        agentsItem.submenu = agentsMenu
        agentsMenu.delegate = self
        mainMenu.addItem(agentsItem)
        let sizeItem = NSMenuItem(title: "Windows in Stack", action: nil, keyEquivalent: "")
        for n in 1...4 {
            let i = NSMenuItem(title: "\(n)", action: #selector(setStackSize(_:)), keyEquivalent: "")
            i.target = self
            i.tag = n
            stackSizeMenu.addItem(i)
        }
        sizeItem.submenu = stackSizeMenu
        mainMenu.addItem(sizeItem)
        mainMenu.addItem(.separator())
        alwaysShowItem = item("Always Show Panel", #selector(toggleAlwaysShow))
        clickThroughItem = item("Click-Through", #selector(toggleClickThrough))
        clickThroughItem.keyEquivalent = "p"
        clickThroughItem.keyEquivalentModifierMask = [.control, .option]
        mainMenu.addItem(opacityItem())
        pauseItem = item("Pause Mirror", #selector(togglePause))
        mainMenu.addItem(.separator())
        item("Screen Recording…", #selector(showWelcome))
        item("Reset Panel Position", #selector(resetPosition))
        mainMenu.addItem(.separator())
        item("Quit OpenPiP", #selector(quit)).keyEquivalent = "q"
    }

    @discardableResult
    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        mainMenu.addItem(i)
        return i
    }

    private func opacityItem() -> NSMenuItem {
        let label = NSTextField(labelWithString: "Opacity")
        label.font = .menuFont(ofSize: 0)
        let slider = NSSlider(value: Settings.opacity, minValue: 0.2, maxValue: 1, target: self,
                              action: #selector(opacityChanged(_:)))
        slider.isContinuous = true
        let stack = NSStackView(views: [label, slider])
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 20, bottom: 4, right: 16)
        stack.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
        let i = NSMenuItem()
        i.view = stack
        return i
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === windowMenu {
            picker.fill(windowMenu, target: self, action: #selector(pickWindow(_:)), current: stack.front)
            // Refresh in the background; the open menu updates in place.
            Task {
                await picker.refresh()
                picker.fill(windowMenu, target: self, action: #selector(pickWindow(_:)), current: stack.front)
            }
        } else if menu === agentsMenu {
            fillAgentsMenu()
            Task {
                activeAgents = await scanner.active()
                fillAgentsMenu()
            }
        } else if menu === mainMenu {
            followItem.state = Settings.followAgent ? .on : .off
            cursorItem.state = Settings.showCursor ? .on : .off
            alwaysShowItem.state = Settings.alwaysShow ? .on : .off
            clickThroughItem.state = panel.clickThrough ? .on : .off
            pauseItem.state = paused ? .on : .off
            clearItem.isEnabled = stack.front != nil
            let hasImage = frontImagePath != nil
            openImageItem.isHidden = !hasImage
            revealImageItem.isHidden = !hasImage
            switchItem.isHidden = frontPair == nil
            switchItem.title = frontPair.map { stack.front == $0.session ? "Show Images" : "Show Agent Actions" } ?? "Show Images"
            for i in stackSizeMenu.items { i.state = i.tag == stack.limit ? .on : .off }
        }
    }

    // MARK: actions

    @objc private func pickWindow(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value,
              let sc = picker.scWindow(id: id) else { return }
        // A manual pick wins over auto-follow until "Follow Agent" is turned back on.
        Settings.followAgent = false
        autoHide.pinned = true
        mirror(WindowPicker.info(sc))
        tick()
    }

    @objc private func toggleFollow() {
        Settings.followAgent.toggle()
        if Settings.followAgent { autoHide.pinned = false }
        tick()
    }

    @objc private func toggleCursor() {
        Settings.showCursor.toggle()
        if !Settings.showCursor, let id = stack.front { panel.setCursor(nil, for: id, click: false) }
    }

    @objc private func clearWindows() {
        let ids = stack.ids
        stack.removeAll()
        forget(ids)
        wantsCapture = false
        autoHide.pinned = false
        Task { await capture.stop() }
        render()
        tick()
    }

    @objc private func setStackSize(_ sender: NSMenuItem) {
        Settings.maxCards = sender.tag
        forget(stack.setLimit(sender.tag))
        render()
    }

    @objc private func toggleAlwaysShow() {
        Settings.alwaysShow.toggle()
        autoHide.alwaysShow = Settings.alwaysShow
        tick()
    }

    @objc private func toggleClickThrough() {
        panel.clickThrough.toggle()
        Settings.clickThrough = panel.clickThrough
        statusLine.title = panel.clickThrough ? "Click-through on (⌃⌥P to turn off)" : "Click-through off"
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        panel.opacity = sender.doubleValue
        Settings.opacity = sender.doubleValue
    }

    @objc private func togglePause() {
        paused.toggle()
        if paused {
            Task { await capture.stop() }
        } else if let front, !front.hidden {
            wantsCapture = true
        }
        render()
        tick()
    }

    @objc private func showWelcome() {
        if welcome == nil {
            welcome = WelcomeWindowController()
        }
        welcome?.present()
    }

    @objc private func resetPosition() {
        panel.resetPosition()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
