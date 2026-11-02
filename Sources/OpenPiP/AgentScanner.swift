import Foundation
import OpenPiPCore

/// One agent session whose log changed recently.
struct AgentSession: Equatable {
    var url: URL
    var label: String
    var title: String?
    var modified: Date

    var id: String { url.path }
    var displayName: String { title.map { "\($0) — \(label)" } ?? label }
}

/// Finds agent sessions that are working now: Claude Code session logs in ~/.claude/projects,
/// which also covers OpenBot agents (they run Claude Code). Only file dates and the session title
/// are read here; a session's content is read only once it is tracked.
@MainActor
final class AgentScanner {
    /// OPENPIP_PROJECTS_DIR points the scanner at another folder (demos, tests).
    private let root = ProcessInfo.processInfo.environment["OPENPIP_PROJECTS_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private let home = NSHomeDirectory()
    private var openBotNames: [String: String] = [:]
    private var namesFetched = Date.distantPast

    /// Sessions whose log changed in the last `window` seconds, newest first.
    func active(within window: TimeInterval = 15 * 60) async -> [AgentSession] {
        await refreshOpenBotNames()
        let root = self.root, home = self.home, names = openBotNames
        return await Task.detached(priority: .utility) {
            Self.scan(root: root, home: home, names: names, window: window)
        }.value
    }

    nonisolated private static func scan(root: URL, home: String, names: [String: String],
                                         window: TimeInterval) -> [AgentSession] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-window)
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var found: [AgentSession] = []
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: .skipsHiddenFiles) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified > cutoff else { continue }
                let (title, cwd) = nameAndFolder(of: file)
                let label = SessionLabel(projectDir: dir.lastPathComponent, home: home, openBotNames: names, cwd: cwd)
                found.append(AgentSession(url: file, label: label.text, title: title, modified: modified))
            }
        }
        return found.sorted { $0.modified > $1.modified }
    }

    /// The session name (`custom-title`, else `ai-title`) and the latest work folder, from the last
    /// 512 KB of the log.
    nonisolated private static func nameAndFolder(of file: URL) -> (String?, String?) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return (nil, nil) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let from = size > 512 * 1024 ? size - 512 * 1024 : 0
        try? handle.seek(toOffset: from)
        guard let data = try? handle.readToEnd() else { return (nil, nil) }
        var buffer = LineBuffer(maxLineBytes: 1 << 20)
        var state = SessionState()
        var cwd: String?
        for line in buffer.append(data) + buffer.flush() {
            if line.contains(#""ai-title""#) || line.contains(#""custom-title""#) { state.apply(line) }
            if let c = workFolder(in: line) { cwd = c }
        }
        return (state.title, cwd)
    }

    nonisolated private static let cwdPattern = try! NSRegularExpression(pattern: #""cwd"\s*:\s*"((?:[^"\\]|\\.)*)""#)

    /// The `cwd` field of a log line, found without parsing the whole line.
    nonisolated private static func workFolder(in line: String) -> String? {
        guard line.contains(#""cwd""#),
              let m = cwdPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let r = Range(m.range(at: 1), in: line) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data("\"\(line[r])\"".utf8), options: .fragmentsAllowed)) as? String
    }

    /// Agent names from OpenBot's own CLI, refreshed at most every 5 minutes. Missing CLI is fine.
    private func refreshOpenBotNames() async {
        guard Date().timeIntervalSince(namesFetched) > 300 else { return }
        namesFetched = Date()
        let cli = "/Applications/OpenBot.app/Contents/Resources/cli/openbot-cli.mjs"
        guard FileManager.default.fileExists(atPath: cli) else { return }
        let names: [String: String] = await Task.detached(priority: .utility) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["node", cli, "list", "--json"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
            task.environment = env
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil else { return [:] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let agents = obj["agents"] as? [[String: Any]] else { return [:] }
            var out: [String: String] = [:]
            for a in agents {
                if let id = a["id"] as? String, let name = a["name"] as? String { out[id] = name }
            }
            return out
        }.value
        if !names.isEmpty { openBotNames = names }
    }
}
