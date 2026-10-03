import Foundation

/// A Claude Code account is its configuration folder: `CLAUDE_CONFIG_DIR`, or
/// `~/.claude` when unset. Limits, sessions and transcripts belong to one.
public enum ClaudeConfigPath {
    public static func defaultDirectory(home: String = NSHomeDirectory()) -> String {
        normalize((home as NSString).appendingPathComponent(".claude"), home: home)
    }

    /// Expanded, standardized, no trailing slash: one spelling per folder.
    public static func normalize(_ path: String, home: String = NSHomeDirectory()) -> String {
        var expanded = path
        if expanded == "~" { expanded = home } else if expanded.hasPrefix("~/") { expanded = home + expanded.dropFirst() }
        var standard = (expanded as NSString).standardizingPath
        while standard.count > 1, standard.hasSuffix("/") { standard.removeLast() }
        return standard
    }

    /// The account of a Claude Code process, from inside it (a hook or the
    /// status line command): its `CLAUDE_CONFIG_DIR`, else the folder in front
    /// of `/projects/` in its transcript path, else `~/.claude`.
    public static func of(environment: [String: String], transcriptPath: String?, home: String = NSHomeDirectory()) -> String {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty { return normalize(dir, home: home) }
        if let transcriptPath, let range = transcriptPath.range(of: "/projects/", options: .backwards) {
            return normalize(String(transcriptPath[..<range.lowerBound]), home: home)
        }
        return defaultDirectory(home: home)
    }

    /// A short name for the folder: `~/.claude` → "default", `~/.claude-work`
    /// → "work", anything else → its last component.
    public static func shortName(_ directory: String, home: String = NSHomeDirectory()) -> String {
        if directory == defaultDirectory(home: home) { return "default" }
        let last = (directory as NSString).lastPathComponent
        for prefix in [".claude-", ".claude_", "claude-", "."] where last.hasPrefix(prefix) && last.count > prefix.count {
            return String(last.dropFirst(prefix.count))
        }
        return last
    }
}

/// Combines a new status line reading with what is known. Claude Code gives a
/// status line the limits from the session's last model reply, and an idle
/// session keeps repeating them, so arrival time says nothing about age. Within
/// one window (same reset time) usage only grows: a lower figure is an old one.
public enum LimitMerge {
    /// Reset times of one window may differ by rounding.
    public static let sameWindowTolerance: TimeInterval = 90

    public static func merge(
        current: [String: StatuslinePayload.Window],
        fresh: [String: StatuslinePayload.Window]
    ) -> [String: StatuslinePayload.Window] {
        var result = current
        for (key, new) in fresh {
            guard let old = current[key] else {
                result[key] = new
                continue
            }
            if let oldReset = old.resetsAt, let newReset = new.resetsAt {
                // From a window that already ended.
                if newReset < oldReset - sameWindowTolerance { continue }
                if abs(newReset - oldReset) <= sameWindowTolerance,
                   let oldUsed = old.usedPercentage, let newUsed = new.usedPercentage, newUsed < oldUsed {
                    continue
                }
            }
            result[key] = new
        }
        return result
    }
}
