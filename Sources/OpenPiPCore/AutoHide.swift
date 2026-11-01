import Foundation

/// Decides whether the panel should be on screen. Time is passed in, so tests use a fake clock.
///
/// - `start`/`step` show the panel. It hides after `idleDelay` with no event and no frame change.
/// - `end`/`error` show the panel, then hide it `endDelay` later. Frame changes do not extend this.
/// - `alwaysShow` (setting) and `pinned` (manual window pick) keep it visible.
public struct AutoHide {
    public var endDelay: TimeInterval
    public var idleDelay: TimeInterval
    public var alwaysShow = false
    public var pinned = false

    private var lastActivity: Date?
    private var endedAt: Date?

    public init(endDelay: TimeInterval = 5, idleDelay: TimeInterval = 10) {
        self.endDelay = endDelay
        self.idleDelay = idleDelay
    }

    public mutating func event(_ status: Event.Status, at now: Date) {
        lastActivity = now
        switch status {
        case .start, .step: endedAt = nil
        case .end, .error: endedAt = now
        }
    }

    public mutating func frameChanged(at now: Date) {
        guard endedAt == nil, lastActivity != nil else { return }
        lastActivity = now
    }

    public func isVisible(at now: Date) -> Bool {
        if alwaysShow || pinned { return true }
        if let endedAt { return now.timeIntervalSince(endedAt) < endDelay }
        if let lastActivity { return now.timeIntervalSince(lastActivity) < idleDelay }
        return false
    }
}
