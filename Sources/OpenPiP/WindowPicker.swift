import AppKit
import ScreenCaptureKit
import OpenPiPCore

/// Lists capturable windows and fills the "Mirror window" menu.
@MainActor
final class WindowPicker {
    private(set) var windows: [SCWindow] = []
    private(set) var lastError: Error?

    /// Fetches all normal windows, including ones that are minimized or on other Spaces.
    @discardableResult
    func refresh() async -> [WindowInfo] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let me = ProcessInfo.processInfo.processIdentifier
            windows = content.windows.filter { w in
                guard let owner = w.owningApplication, owner.processID != me else { return false }
                return w.windowLayer == 0 && w.frame.width >= 80 && w.frame.height >= 60
            }
            lastError = nil
        } catch {
            windows = []
            lastError = error
        }
        return infos
    }

    var infos: [WindowInfo] { windows.map(Self.info) }

    func scWindow(id: UInt32) -> SCWindow? {
        windows.first { $0.windowID == id }
    }

    static func info(_ w: SCWindow) -> WindowInfo {
        WindowInfo(id: w.windowID,
                   appName: w.owningApplication?.applicationName ?? "",
                   bundleID: w.owningApplication?.bundleIdentifier ?? "",
                   title: w.title,
                   pid: w.owningApplication?.processID ?? 0,
                   area: Double(w.frame.width * w.frame.height),
                   isOnScreen: w.isOnScreen,
                   frame: w.frame)
    }

    /// Rebuilds `menu` with one item per visible titled window, grouped by app.
    func fill(_ menu: NSMenu, target: AnyObject, action: Selector, current: UInt32?) {
        menu.removeAllItems()
        if lastError != nil {
            menu.addItem(disabledItem("Screen Recording not granted"))
            return
        }
        let visible = windows
            .filter { $0.isOnScreen && !($0.title ?? "").isEmpty }
            .sorted {
                let a = $0.owningApplication?.applicationName ?? "", b = $1.owningApplication?.applicationName ?? ""
                return a == b ? ($0.title ?? "") < ($1.title ?? "") : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        if visible.isEmpty {
            menu.addItem(disabledItem("No windows found"))
            return
        }
        var lastApp: String?
        for w in visible {
            let appName = w.owningApplication?.applicationName ?? "?"
            if appName != lastApp {
                if lastApp != nil { menu.addItem(.separator()) }
                let header = disabledItem(appName)
                header.image = Self.icon(pid: w.owningApplication?.processID)
                menu.addItem(header)
                lastApp = appName
            }
            let title = String((w.title ?? "").prefix(60))
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = NSNumber(value: w.windowID)
            item.indentationLevel = 1
            item.state = w.windowID == current ? .on : .off
            menu.addItem(item)
        }
    }

    /// Pixels per point of the display that holds most of `frame` (global points, top-left origin).
    static func displayScale(for frame: CGRect) -> CGFloat {
        guard let primary = NSScreen.screens.first else { return 2 }
        let flipped = CGRect(x: frame.minX, y: primary.frame.height - frame.maxY, width: frame.width, height: frame.height)
        let best = NSScreen.screens.max { a, b in
            a.frame.intersection(flipped).width * a.frame.intersection(flipped).height
                < b.frame.intersection(flipped).width * b.frame.intersection(flipped).height
        }
        return best?.backingScaleFactor ?? primary.backingScaleFactor
    }

    static func icon(pid: pid_t?) -> NSImage? {
        guard let pid, let image = NSRunningApplication(processIdentifier: pid)?.icon?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    /// Finds a running app by name or bundle id, for the caption icon.
    static func icon(app: String?) -> NSImage? {
        guard let app = app?.lowercased() else { return nil }
        let match = NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.lowercased() == app || $0.bundleIdentifier?.lowercased() == app
        }
        return icon(pid: match?.processIdentifier)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
