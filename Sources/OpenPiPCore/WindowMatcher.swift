import Foundation
import CoreGraphics

/// A capturable window, copied out of ScreenCaptureKit so matching stays testable.
public struct WindowInfo: Equatable, Sendable {
    public var id: UInt32
    public var appName: String
    public var bundleID: String
    public var title: String?
    public var pid: Int32
    public var area: Double
    public var isOnScreen: Bool
    /// Global screen points, top-left origin.
    public var frame: CGRect

    public init(id: UInt32, appName: String, bundleID: String, title: String?, pid: Int32,
                area: Double, isOnScreen: Bool, frame: CGRect = .zero) {
        self.id = id
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.pid = pid
        self.area = area
        self.isOnScreen = isOnScreen
        self.frame = frame
    }
}

/// Picks the window an event points at: pid first, then app name or bundle id, then title substring.
public enum WindowMatcher {
    public static func match(_ event: Event, in windows: [WindowInfo]) -> WindowInfo? {
        var pool: [WindowInfo]
        if let pid = event.pid, case let byPid = windows.filter({ $0.pid == pid }), !byPid.isEmpty {
            pool = byPid
        } else if let app = event.app?.lowercased() {
            pool = windows.filter { $0.appName.lowercased() == app || $0.bundleID.lowercased() == app }
        } else if event.window != nil {
            pool = windows
        } else {
            return nil
        }

        if let needle = event.window?.lowercased() {
            let titled = pool.filter { $0.title?.lowercased().contains(needle) == true }
            if !titled.isEmpty { pool = titled } else if event.app == nil && event.pid == nil { return nil }
        }

        return pool.max { a, b in
            if a.isOnScreen != b.isOnScreen { return !a.isOnScreen }
            return a.area < b.area
        }
    }

    /// True when every hint in the event fits this exact window. Unlike `match`, a title hint
    /// that does not fit is a "no", so a new window of the same app is not mistaken for this one.
    public static func isSameWindow(_ event: Event, _ window: WindowInfo) -> Bool {
        guard event.pid != nil || event.app != nil || event.window != nil else { return false }
        if let pid = event.pid, pid != window.pid { return false }
        if let app = event.app?.lowercased(),
           window.appName.lowercased() != app, window.bundleID.lowercased() != app { return false }
        if let needle = event.window?.lowercased(),
           window.title?.lowercased().contains(needle) != true { return false }
        return true
    }
}
