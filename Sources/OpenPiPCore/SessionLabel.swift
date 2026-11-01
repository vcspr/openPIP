import Foundation

/// A readable name for a Claude Code project folder in ~/.claude/projects. Claude Code names the
/// folder after the working directory with "/" and "." turned into "-".
public struct SessionLabel: Equatable, Sendable {
    public let text: String
    /// Set for OpenBot agents, whose working directory is ~/OpenBot/Agents/agent-<uuid>.
    public let openBotAgentID: String?

    public init(projectDir: String, home: String, openBotNames: [String: String] = [:]) {
        let homeDir = Self.encode(home)
        if let r = projectDir.range(of: "-OpenBot-Agents-agent-") {
            let id = "agent-" + projectDir[r.upperBound...]
            openBotAgentID = id
            text = openBotNames[id].map { "OpenBot · \($0)" } ?? "OpenBot agent"
            return
        }
        openBotAgentID = nil
        if projectDir == homeDir {
            text = "Home"
        } else if projectDir.hasPrefix(homeDir + "-") {
            text = Self.words(String(projectDir.dropFirst(homeDir.count + 1)))
        } else {
            text = Self.words(projectDir)
        }
    }

    private static func encode(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
    }

    private static func words(_ s: String) -> String {
        s.split(separator: "-").joined(separator: " ")
    }
}
