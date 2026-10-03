import Foundation
import Usage

/// Where Claude Code keeps its files. One place to ask, so no other code
/// spells out `~/.claude`: with `CLAUDE_CONFIG_DIR` everything moves into
/// that folder, including `.claude.json`.
///
/// Accounts are found, not configured: the app's own folder
/// (`CLAUDE_CONFIG_DIR` from its environment, else `~/.claude`) plus every
/// folder a Claude Code session or `/usage` has reported.
enum ClaudeConfig {
    static var defaultDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(filePath: (custom as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        return URL(filePath: NSHomeDirectory()).appending(path: ".claude", directoryHint: .isDirectory)
    }

    /// Every configuration folder the app knows of, the default first: the
    /// default and every account a Claude Code session or `/usage` reported.
    static var knownDirectories: [URL] {
        let known = Settings.knownClaudeAccounts.keys.sorted().map { URL(filePath: $0, directoryHint: .isDirectory) }
        var result = [defaultDirectory]
        for url in known where !result.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) {
            result.append(url)
        }
        return result
    }

    /// The account folder holding a session's transcript, if any known one does.
    static func account(ofSession id: String, cwd: String) -> URL? {
        knownDirectories.first { FileManager.default.fileExists(atPath: projectDirectory(for: cwd, in: $0).appending(path: "\(id).jsonl").path) }
    }

    /// Claude Code's global state with the list of projects: inside the
    /// folder when it was moved, else `~/.claude.json` next to `~/.claude`.
    static func stateFile(in directory: URL) -> URL {
        if directory.standardizedFileURL == URL(filePath: NSHomeDirectory()).appending(path: ".claude").standardizedFileURL {
            return URL(filePath: NSHomeDirectory()).appending(path: ".claude.json")
        }
        return directory.appending(path: ".claude.json")
    }

    static func settingsFile(in directory: URL) -> URL {
        directory.appending(path: "settings.json")
    }

    /// `projects/<path with every non-alphanumeric as "-">`.
    static func projectDirectory(for cwd: String, in directory: URL) -> URL {
        let encoded = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return directory.appending(path: "projects/\(encoded)", directoryHint: .isDirectory)
    }

    /// The session's transcript in whichever known folder has it.
    static func transcript(session id: String, cwd: String) -> URL {
        let candidates = knownDirectories.map { projectDirectory(for: cwd, in: $0).appending(path: "\(id).jsonl") }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
    }

    /// The environment for running Claude Code as `account`. The default
    /// folder must be left unset: `CLAUDE_CONFIG_DIR=~/.claude` spelled out is
    /// a separate keychain entry, signed out (Claude Code 2.1.284).
    static func environment(for account: String, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        if ClaudeConfigPath.normalize(account) == ClaudeConfigPath.defaultDirectory() {
            environment["CLAUDE_CONFIG_DIR"] = nil
        } else {
            environment["CLAUDE_CONFIG_DIR"] = account
        }
        return environment
    }
}
