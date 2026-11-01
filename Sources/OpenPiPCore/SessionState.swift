import Foundation

public struct SessionTask: Equatable, Sendable {
    public enum Status: String, Sendable {
        case pending, inProgress = "in_progress", completed
    }

    public var title: String
    public var status: Status
    /// The id the agent uses in TaskUpdate, once the TaskCreate result told us.
    var externalID: String?
    /// The tool_use id of the TaskCreate call, until its result arrives.
    var createID: String?
}

/// One shell command the agent ran, with the end of its output.
public struct TerminalEntry: Equatable, Sendable {
    public static let maxLines = 8

    public var id: String
    public var command: String
    public var output: [String] = []
    public var running = true
    public var failed = false
}

/// What an agent session is doing, rebuilt line by line from a Claude Code session log
/// (`~/.claude/projects/<dir>/<session>.jsonl`). OpenBot agents write the same format.
///
/// Reads: the `ai-title` line (session name); TaskCreate / TaskUpdate, TodoWrite and the desktop
/// app's update_plan (task list); Bash calls and their results (terminal); the latest tool call or
/// message (one-line status). Everything else is ignored.
public struct SessionState: Equatable, Sendable {
    public static let maxTerminalEntries = 5

    public private(set) var title: String?
    public private(set) var tasks: [SessionTask] = []
    public private(set) var terminal: [TerminalEntry] = []
    public private(set) var lastAction: String?
    public private(set) var lastTimestamp: Date?

    public init() {}

    public var progress: (done: Int, total: Int) {
        (tasks.filter { $0.status == .completed }.count, tasks.count)
    }

    /// Cheap byte check for lines that can change the task list or title. Used to skim the old part
    /// of a big log without parsing every line.
    public static func isTaskRelated(_ line: String) -> Bool {
        taskMarkers.contains { line.contains($0) }
    }

    private static let taskMarkers = [
        #""TaskCreate""#, #""TaskUpdate""#, #""TodoWrite""#, "update_plan", #""ai-title""#,
        #""toolUseResult":{"task""#,
    ]

    /// Applies one log line. Returns true when anything visible changed.
    @discardableResult
    public mutating func apply(_ line: String) -> Bool {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return false }
        let before = self
        switch type {
        case "ai-title":
            if let t = (obj["aiTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                title = t
            }
        case "assistant":
            readTimestamp(obj)
            for item in Self.contentItems(obj) {
                switch item["type"] as? String {
                case "tool_use":
                    toolUse(id: item["id"] as? String ?? "", name: item["name"] as? String ?? "",
                            input: item["input"] as? [String: Any] ?? [:])
                case "text":
                    if let first = Self.firstLine(item["text"] as? String) { lastAction = first }
                default:
                    break
                }
            }
        case "user":
            readTimestamp(obj)
            for item in Self.contentItems(obj) where item["type"] as? String == "tool_result" {
                toolResult(id: item["tool_use_id"] as? String ?? "", content: item["content"],
                           isError: item["is_error"] as? Bool ?? false, extra: obj["toolUseResult"])
            }
        default:
            return false
        }
        return self != before
    }

    // MARK: tool calls

    private mutating func toolUse(id: String, name: String, input: [String: Any]) {
        switch name {
        case "TaskCreate":
            if let subject = Self.string(input["subject"]) {
                tasks.append(SessionTask(title: subject, status: .pending, externalID: nil, createID: id))
            }
        case "TaskUpdate":
            guard let taskID = Self.string(input["taskId"]),
                  let i = tasks.firstIndex(where: { $0.externalID == taskID }) else { return }
            if let subject = Self.string(input["subject"]) { tasks[i].title = subject }
            if let raw = input["status"] as? String {
                if raw == "deleted" { tasks.remove(at: i) } else if let s = SessionTask.Status(rawValue: raw) { tasks[i].status = s }
            }
        case "TodoWrite":
            if let todos = input["todos"] as? [[String: Any]] { tasks = Self.taskList(todos) }
        case _ where name.hasSuffix("update_plan"):
            plan(input)
        case "Bash":
            let command = (input["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            terminal.append(TerminalEntry(id: id, command: command))
            if terminal.count > Self.maxTerminalEntries { terminal.removeFirst(terminal.count - Self.maxTerminalEntries) }
            lastAction = "$ " + (Self.firstLine(command) ?? "")
        default:
            lastAction = Self.describe(name: name, input: input)
        }
    }

    /// The desktop app's plan tool: a full `items` list, or `advance` / `done` / `start` steps.
    private mutating func plan(_ input: [String: Any]) {
        if let items = input["items"] as? [[String: Any]] {
            tasks = Self.taskList(items)
            return
        }
        if input["advance"] as? Bool == true {
            if let i = tasks.firstIndex(where: { $0.status == .inProgress }) { tasks[i].status = .completed }
            if let j = tasks.firstIndex(where: { $0.status == .pending }) { tasks[j].status = .inProgress }
        }
        for n in input["done"] as? [Int] ?? [] where tasks.indices.contains(n - 1) { tasks[n - 1].status = .completed }
        if let n = input["start"] as? Int, tasks.indices.contains(n - 1) { tasks[n - 1].status = .inProgress }
    }

    private mutating func toolResult(id: String, content: Any?, isError: Bool, extra: Any?) {
        if let i = tasks.firstIndex(where: { $0.createID == id }) {
            if let task = (extra as? [String: Any])?["task"] as? [String: Any], let tid = Self.string(task["id"]) {
                tasks[i].externalID = tid
            }
            tasks[i].createID = nil
            return
        }
        guard let i = terminal.firstIndex(where: { $0.id == id }) else { return }
        var text: String
        if let r = extra as? [String: Any], let out = r["stdout"] as? String {
            text = out
            if let err = r["stderr"] as? String, !err.isEmpty { text += "\n" + err }
        } else {
            text = Self.plainText(content)
        }
        terminal[i].output = Self.tail(text)
        terminal[i].running = false
        terminal[i].failed = isError
    }

    // MARK: helpers

    private mutating func readTimestamp(_ obj: [String: Any]) {
        guard let s = obj["timestamp"] as? String else { return }
        if let d = Self.isoFrac.date(from: s) ?? Self.iso.date(from: s) { lastTimestamp = d }
    }

    nonisolated(unsafe) private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

    private static func contentItems(_ obj: [String: Any]) -> [[String: Any]] {
        ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
    }

    private static func taskList(_ items: [[String: Any]]) -> [SessionTask] {
        items.compactMap { item in
            guard let title = string(item["content"]) ?? string(item["subject"]) else { return nil }
            let status = SessionTask.Status(rawValue: item["status"] as? String ?? "") ?? .pending
            return SessionTask(title: title, status: status)
        }
    }

    private static func describe(name: String, input: [String: Any]) -> String {
        let short = name.components(separatedBy: "__").last ?? name
        if let path = input["file_path"] as? String ?? input["notebook_path"] as? String {
            return "\(short) · \((path as NSString).lastPathComponent)"
        }
        if let app = input["app"] as? String { return "\(short) · \(app)" }
        if let pattern = input["pattern"] as? String { return "\(short) · \(String(pattern.prefix(60)))" }
        return short
    }

    /// Text, numbers and the string forms of numbers all count as ids and names.
    private static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    private static func firstLine(_ text: String?) -> String? {
        guard let line = text?.split(whereSeparator: \.isNewline).first?
            .trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }
        return String(line.prefix(120))
    }

    private static func plainText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let items = content as? [[String: Any]] {
            return items.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    nonisolated(unsafe) private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")

    private static func tail(_ text: String) -> [String] {
        let clean = ansi.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        // Blank lines and Claude Code's own "Shell cwd was reset" notices only take up room.
        let lines = clean.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("Shell cwd was reset") }
            .map { String($0.prefix(200)) }
        return Array(lines.suffix(TerminalEntry.maxLines))
    }
}
