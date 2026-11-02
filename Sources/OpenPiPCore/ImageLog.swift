import Foundation

/// One image an agent made, opened or shared.
public struct AgentImage: Equatable, Sendable {
    /// How the image came up. A stronger kind wins when the same file comes up again.
    public enum Kind: Int, Comparable, Sendable {
        /// New in the work folder ("Show All New Images"), never named in the log.
        case found
        case wrote
        case looked
        /// Sent to the user (SendUserFile, OpenBot's attach_files_to_response).
        case shared

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public var path: String
    public var kind: Kind
    public var time: Date?
}

/// The images an agent session made, opened or shared, read from its session log. Oldest first,
/// at most `limit`. Relative paths are resolved against the log's work folder (`cwd`).
public struct ImageLog: Equatable, Sendable {
    public static let limit = 30
    public static let extensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "heic", "tif", "tiff"]

    public private(set) var images: [AgentImage] = []
    /// The work folder of the latest line.
    public private(set) var cwd: String?
    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    public static func isImagePath(_ s: String) -> Bool {
        !s.contains("\n") && extensions.contains((s as NSString).pathExtension.lowercased())
    }

    /// Cheap byte check for tool calls that may name an image. Used to skim old parts of a big log.
    public static func isImageRelated(_ line: String) -> Bool {
        guard line.contains(#""tool_use""#) else { return false }
        return extensions.contains { line.range(of: ".\($0)\"", options: .caseInsensitive) != nil }
    }

    @discardableResult
    public mutating func apply(_ line: String) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
        return apply(object: obj)
    }

    /// Applies one parsed log line. Returns true when the image list changed.
    @discardableResult
    mutating func apply(object obj: [String: Any]) -> Bool {
        if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
        guard obj["type"] as? String == "assistant",
              let items = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return false }
        let time = (obj["timestamp"] as? String).flatMap(Self.date)
        var changed = false
        for item in items where item["type"] as? String == "tool_use" {
            let name = item["name"] as? String ?? ""
            let input = item["input"] as? [String: Any] ?? [:]
            for (path, kind) in Self.mentions(name: name, input: input) {
                changed = note(resolve(path), kind: kind, time: time) || changed
            }
        }
        return changed
    }

    /// Adds a new file from the work folder, in time order. False when it is already listed.
    @discardableResult
    public mutating func addFound(_ path: String, at time: Date) -> Bool {
        guard !images.contains(where: { $0.path == path }) else { return false }
        let i = images.firstIndex { ($0.time ?? .distantPast) > time } ?? images.endIndex
        images.insert(AgentImage(path: path, kind: .found, time: time), at: i)
        trim()
        return true
    }

    /// Drops a file that no longer exists.
    @discardableResult
    public mutating func remove(_ path: String) -> Bool {
        guard let i = images.firstIndex(where: { $0.path == path }) else { return false }
        images.remove(at: i)
        return true
    }

    // MARK: helpers

    private mutating func note(_ path: String, kind: AgentImage.Kind, time: Date?) -> Bool {
        var entry = AgentImage(path: path, kind: kind, time: time ?? Date())
        if let i = images.firstIndex(where: { $0.path == path }) {
            entry.kind = max(kind, images[i].kind)
            if i == images.count - 1, images[i] == entry { return false }
            images.remove(at: i)
        }
        images.append(entry)
        trim()
        return true
    }

    private mutating func trim() {
        if images.count > Self.limit { images.removeFirst(images.count - Self.limit) }
    }

    private static func mentions(name: String, input: [String: Any]) -> [(String, AgentImage.Kind)] {
        switch name {
        case "Read":
            return filePath(input).map { [($0, .looked)] } ?? []
        case "Write", "Edit":
            return filePath(input).map { [($0, .wrote)] } ?? []
        case _ where name == "SendUserFile" || name.hasSuffix("attach_files_to_response"):
            // Only the file lists, not captions or other text.
            let lists = ["files", "paths", "file_paths"].compactMap { input[$0] }
            return lists.flatMap(strings).filter(isImagePath).map { ($0, .shared) }
        default:
            return []
        }
    }

    private static func filePath(_ input: [String: Any]) -> String? {
        (input["file_path"] as? String).flatMap { isImagePath($0) ? $0 : nil }
    }

    /// Strings in a value. A string that holds a JSON list is opened up.
    private static func strings(_ value: Any) -> [String] {
        switch value {
        case let list as [Any]:
            return list.flatMap(strings)
        case let s as String:
            if s.hasPrefix("["), let list = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [Any] {
                return list.flatMap(strings)
            }
            return [s]
        default:
            return []
        }
    }

    private func resolve(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        if path == "~" || path.hasPrefix("~/") { return home + path.dropFirst() }
        guard let cwd else { return path }
        // URL.standardized only folds "." and ".."; NSString.standardizingPath would also turn
        // /private/tmp into /tmp, so the same file would show up under two names.
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true))
            .absoluteURL.standardized.path
    }

    nonisolated(unsafe) private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

    private static func date(_ s: String) -> Date? { isoFrac.date(from: s) ?? iso.date(from: s) }
}
