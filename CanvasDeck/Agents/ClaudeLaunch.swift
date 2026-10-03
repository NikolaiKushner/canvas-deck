import Foundation
import Usage

/// Builds the command a card runs to start Claude Code. Everything the canvas
/// needs travels in flags — `~/.claude/settings.json` is never read or written:
/// `--settings` adds our hooks and our status line on top of the user's
/// settings, `--session-id` fixes the id so the card knows which session it hosts.
enum ClaudeLaunch {
    /// Hook events that move the card's state. See `AgentEvent.fromHook`.
    static let hookEvents = [
        "SessionStart", "UserPromptSubmit", "PermissionRequest", "PermissionDenied",
        "PostToolUse", "PostToolUseFailure", "Notification", "Stop", "StopFailure", "SessionEnd",
    ]

    enum Start {
        case new(sessionID: UUID)
        case resume(sessionID: String)
    }

    static func settingsJSON(notifyPath: String) -> String {
        let command = shellQuote(notifyPath)
        let handler: [String: Any] = ["type": "command", "command": command, "timeout": 5]
        var hooks: [String: Any] = [:]
        for event in hookEvents {
            hooks[event] = [["hooks": [handler]]]
        }
        let settings: [String: Any] = [
            "hooks": hooks,
            // Native, and it feeds the usage panel. Refreshes while idle so the
            // reset countdowns and the panel stay current.
            "statusLine": ["type": "command", "command": "\(command) --statusline", "padding": 0, "refreshInterval": 60],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The `claude` command line, ready for a shell.
    /// `prompt`: the first message, given as Claude Code's positional argument.
    static func command(_ start: Start, name: String?, notifyPath: String, configDirectory: URL? = nil, prompt: String? = nil) -> String {
        var parts = ["claude"]
        // The default folder stays unset: spelled out it is another, signed-out keychain entry.
        if let configDirectory, ClaudeConfigPath.normalize(configDirectory.path) != ClaudeConfigPath.defaultDirectory() {
            parts.insert("CLAUDE_CONFIG_DIR=\(shellQuote(configDirectory.path))", at: 0)
        }
        switch start {
        case .new(let id): parts += ["--session-id", id.uuidString.lowercased()]
        case .resume(let id): parts += ["--resume", shellQuote(id)]
        }
        if let name, !name.isEmpty { parts += ["--name", shellQuote(name)] }
        parts += ["--settings", shellQuote(settingsJSON(notifyPath: notifyPath))]
        if let prompt, !prompt.isEmpty { parts += ["--", shellQuote(prompt)] }
        return parts.joined(separator: " ")
    }

    /// Script for an interactive `$SHELL -c`: interactive so the user's rc
    /// files put `claude` on PATH, then the card's usual shell once Claude Code exits.
    static func shellScript(shell: String, start: Start, name: String?, notifyPath: String, configDirectory: URL? = nil, prompt: String? = nil) -> String {
        "\(command(start, name: name, notifyPath: notifyPath, configDirectory: configDirectory, prompt: prompt)); \(ShellIntegration.relaunchCommand(shell: shell))"
    }

    /// Claude Code's own session picker for this folder, with our hooks: for
    /// sessions the canvas did not start.
    static func pickerScript(shell: String, notifyPath: String) -> String {
        "claude --resume --settings \(shellQuote(settingsJSON(notifyPath: notifyPath))); \(ShellIntegration.relaunchCommand(shell: shell))"
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
