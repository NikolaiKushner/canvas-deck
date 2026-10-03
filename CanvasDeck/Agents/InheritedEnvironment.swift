import Foundation

/// Canvas Deck started from inside a Claude Code session (its terminal, a
/// tool call) inherits that session's variables: `CLAUDECODE`, dozens of
/// `CLAUDE_CODE_*` including `CLAUDE_CODE_CHILD_SESSION` and tokens, and
/// `ANTHROPIC_BASE_URL`. Every card would pass them on, and Claude Code in a
/// card would take itself for a child of that session — for one, it then
/// saves no transcript, so the session cannot be resumed. They are removed
/// from the app's own environment at launch, before anything is started.
/// The user's own settings (`CLAUDE_CONFIG_DIR`, their rc files) stay.
enum InheritedEnvironment {
    static func scrub() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CLAUDECODE"] != nil || environment["CLAUDE_CODE_ENTRYPOINT"] != nil else { return }
        for key in environment.keys where shouldRemove(key) {
            unsetenv(key)
        }
    }

    static func shouldRemove(_ key: String) -> Bool {
        if key == "CLAUDE_CONFIG_DIR" { return false }
        if ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"].contains(key) { return true }
        return ["CLAUDE_CODE_", "CLAUDE_AGENT_SDK_", "CLAUDE_PREVIEW_"].contains { key.hasPrefix($0) }
    }
}
