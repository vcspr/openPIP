import Foundation

/// A short, readable name for where an agent works. With the log's work folder (`cwd`) it is that
/// folder's own name; otherwise it is read from the Claude Code project folder in ~/.claude/projects,
/// which is the working directory with "/" and "." turned into "-".
public struct SessionLabel: Equatable, Sendable {
    public let text: String
    /// Set for OpenBot agents, whose working directory is ~/OpenBot/Agents/agent-<uuid>.
    public let openBotAgentID: String?

    public init(projectDir: String, home: String, openBotNames: [String: String] = [:], cwd: String? = nil) {
        let homeDir = Self.encode(home)
        if let r = projectDir.range(of: "-OpenBot-Agents-agent-") {
            let id = "agent-" + projectDir[r.upperBound...]
            openBotAgentID = id
            text = openBotNames[id].map { "OpenBot · \($0)" } ?? "OpenBot agent"
            return
        }
        openBotAgentID = nil
        if let cwd, !cwd.isEmpty {
            text = Self.folderName(cwd, home: home)
            return
        }
        if projectDir == homeDir {
            text = "Home"
        } else if projectDir.hasPrefix(homeDir + "-") {
            text = Self.words(String(projectDir.dropFirst(homeDir.count + 1)))
        } else {
            text = Self.words(projectDir)
        }
    }

    private static func folderName(_ cwd: String, home: String) -> String {
        let path = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        if path == home { return "Home" }
        if path.contains("omb-claude-background") { return "OpenMausBot agent" }
        // Claude worktrees live in <repo>/.claude/worktrees/<name>: name the repo.
        if let r = path.range(of: "/.claude/worktrees/") {
            return (String(path[..<r.lowerBound]) as NSString).lastPathComponent
        }
        return (path as NSString).lastPathComponent
    }

    private static func encode(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
    }

    private static func words(_ s: String) -> String {
        s.split(separator: "-").joined(separator: " ")
    }
}
