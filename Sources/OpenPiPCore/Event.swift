import Foundation

/// One line from the event feed. See README "Event feed".
public struct Event: Equatable, Sendable {
    public enum Status: String, Sendable {
        case start, step, end, error
    }

    public static let maxLineBytes = 4096
    public static let maxTextLength = 120

    public var agent: String
    public var status: Status
    public var text: String
    public var app: String?
    public var window: String?
    public var pid: Int32?
    public var x: Double?
    public var y: Double?
    /// What `x`/`y` measure: "window" (default, points from the window's top-left), "screen"
    /// (global points, top-left origin) or "pixels" (window screenshot pixels). See `CursorMapper`.
    public var coords: String?
    /// Size of the image `x`/`y` were measured on. Optional; overrides `coords`.
    public var w: Double?
    public var h: Double?
    /// For "pixels": the screenshot was shrunk so its long edge is at most this (OCU uses 1280).
    public var maxEdge: Double?

    public init(agent: String, status: Status, text: String, app: String? = nil, window: String? = nil,
                pid: Int32? = nil, x: Double? = nil, y: Double? = nil, coords: String? = nil,
                w: Double? = nil, h: Double? = nil, maxEdge: Double? = nil) {
        self.agent = agent
        self.status = status
        self.text = Event.clean(text)
        self.app = app
        self.window = window
        self.pid = pid
        self.x = x
        self.y = y
        self.coords = coords
        self.w = w
        self.h = h
        self.maxEdge = maxEdge
    }

    /// Parses one JSON line. Returns nil for anything malformed; unknown fields are ignored.
    public static func parse(_ line: String) -> Event? {
        let data = Data(line.utf8)
        guard !data.isEmpty, data.count <= maxLineBytes,
              let raw = try? JSONDecoder().decode(Wire.self, from: data),
              raw.v == 1,
              let agent = raw.agent, !agent.isEmpty,
              let status = raw.status.flatMap(Status.init(rawValue:))
        else { return nil }
        return Event(agent: agent, status: status, text: raw.text ?? "",
                     app: raw.app.nonEmpty, window: raw.window.nonEmpty,
                     pid: raw.pid, x: raw.x, y: raw.y, coords: raw.coords.nonEmpty,
                     w: raw.w, h: raw.h, maxEdge: raw.maxEdge)
    }

    static func clean(_ text: String) -> String {
        let oneLine = text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(oneLine.prefix(maxTextLength))
    }

    private struct Wire: Decodable {
        var v: Int?
        var agent: String?
        var status: String?
        var text: String?
        var app: String?
        var window: String?
        var pid: Int32?
        var x: Double?
        var y: Double?
        var coords: String?
        var w: Double?
        var h: Double?
        var maxEdge: Double?
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let s = self?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }
}
