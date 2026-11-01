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

    private var autoHide = AutoHide()
    private let denyList = DenyList(extra: Settings.extraDenyList)
    private var stack = CardStack(limit: Settings.maxCards)
    private var cards: [UInt32: Card] = [:]
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
            if !(alreadyThere && capture.state != .idle) {
                Task {
                    let list = await picker.refresh()
                    if let match = WindowMatcher.match(event, in: list) {
                        mirror(match)
                    } else if stack.front == nil {
                        caption = "No window found for \(event.app ?? event.window ?? "this agent")"
                        render()
                    }
                }
            }
        }
        render()
        tick()
    }

    // MARK: stack

    /// Puts `window` at the front of the stack and streams it. The old front card keeps its last frame.
    private func mirror(_ window: WindowInfo) {
        let switching = window.id != stack.front
        for id in stack.push(window.id) { cards[id] = nil }

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
            guard let c = cards[id] else { return nil }
            return CardModel(id: id, surface: c.hidden ? nil : c.surface, aspect: c.aspect, note: c.note)
        }
        panel.setCards(models)
        panel.setPlaceholder(models.isEmpty ? (caption ?? "Waiting for an agent") : nil)
    }

    private func startCaptureIfNeeded() {
        guard wantsCapture, !paused, autoHide.isVisible(at: Date()),
              capture.state == .idle, let id = stack.front else { return }
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
        let visible = autoHide.isVisible(at: now)
        panel.setVisible(visible)

        if !visible {
            if capture.state != .idle { Task { await capture.stop() } }
            return
        }
        startCaptureIfNeeded()

        if stack.front != nil, now.timeIntervalSince(lastWindowCheck) > 2 {
            lastWindowCheck = now
            Task { await checkStillThere() }
        }
    }

    /// Drops closed windows and updates the "not visible" note on the front card.
    private func checkStillThere() async {
        let list = await picker.refresh()
        guard picker.lastError == nil else { return }
        let alive = Set(list.map(\.id))
        for id in stack.ids where !alive.contains(id) { drop(id) }

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

    // MARK: menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pip", accessibilityDescription: "OpenPiP")
        statusItem.menu = mainMenu
        mainMenu.delegate = self

        statusLine.isEnabled = false
        mainMenu.addItem(statusLine)
        mainMenu.addItem(.separator())

        let mirrorItem = NSMenuItem(title: "Mirror Window", action: nil, keyEquivalent: "")
        mirrorItem.submenu = windowMenu
        windowMenu.delegate = self
        mainMenu.addItem(mirrorItem)

        followItem = item("Follow Agent", #selector(toggleFollow))
        clearItem = item("Clear Windows", #selector(clearWindows))
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
        } else if menu === mainMenu {
            followItem.state = Settings.followAgent ? .on : .off
            alwaysShowItem.state = Settings.alwaysShow ? .on : .off
            clickThroughItem.state = panel.clickThrough ? .on : .off
            pauseItem.state = paused ? .on : .off
            clearItem.isEnabled = stack.front != nil
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

    @objc private func clearWindows() {
        stack.removeAll()
        cards.removeAll()
        wantsCapture = false
        autoHide.pinned = false
        Task { await capture.stop() }
        render()
        tick()
    }

    @objc private func setStackSize(_ sender: NSMenuItem) {
        Settings.maxCards = sender.tag
        for id in stack.setLimit(sender.tag) { cards[id] = nil }
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
