// canvas-notify — tells Canvas Deck what happened in a terminal card.
//
// As a Claude Code hook it reads the hook's JSON from stdin. By hand:
//   canvas-notify --event Notification --type idle_prompt --message "…"
// As a Claude Code status line (`--statusline`) it prints the status line
// and sends the limits, cost and context figures to the canvas.
//
// It adds the card id from CANVAS_NODE_ID, writes one JSON line to the
// canvas socket and exits 0. Hooks print nothing: their stdout can become
// model context. Nothing here fails loudly: a failing hook or status line
// must not disturb the agent.

import Foundation
import Usage

// A canvas that went away mid-write must not kill us with SIGPIPE.
signal(SIGPIPE, SIG_IGN)

let environment = ProcessInfo.processInfo.environment
let nodeID = environment["CANVAS_NODE_ID"].flatMap { $0.isEmpty ? nil : $0 }
let socketPath = environment["CANVAS_NOTIFY_SOCKET"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/CanvasDeck/notify.sock")
let arguments = Array(CommandLine.arguments.dropFirst())

func readStdin() -> Data {
    isatty(STDIN_FILENO) == 0 ? FileHandle.standardInput.readDataToEndOfFile() : Data()
}

/// Hooks only make sense for a card; a status line snapshot is sent from any
/// Claude Code session (with `requiresNode: false`), card or not.
func send(_ fields: [String: Any], requiresNode: Bool = true) {
    if requiresNode, nodeID == nil { return }
    var fields = fields
    if let nodeID { fields["canvas_node_id"] = nodeID }
    fields["canvas_sent_at"] = Date().timeIntervalSince1970
    guard var line = try? JSONSerialization.data(withJSONObject: fields) else { return }
    line.append(0x0A)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return }
    _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
}

// MARK: Status line

if arguments.first == "--statusline" {
    let data = readStdin()
    let payload = StatuslinePayload.decode(data) ?? StatuslinePayload()
    FileHandle.standardOutput.write(Data((StatuslineText.render(payload) + "\n").utf8))
    if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        // Only the figures the canvas shows; transcript paths and the rest stay here.
        var statusline: [String: Any] = [:]
        for key in ["session_id", "model", "cost", "context_window", "rate_limits"] {
            if let value = object[key] { statusline[key] = value }
        }
        let account = ClaudeConfigPath.of(environment: environment, transcriptPath: object["transcript_path"] as? String)
        send(["hook_event_name": "StatusLine", "statusline": statusline, "config_dir": account], requiresNode: false)
        // The latest limits of each account, for a canvas that was not running at the time.
        if let limits = object["rate_limits"] as? [String: Any], !limits.isEmpty {
            let url = URL(filePath: (socketPath as NSString).deletingLastPathComponent).appending(path: "last-limits.json")
            let saved = (try? Data(contentsOf: url)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            var accounts = saved?["accounts"] as? [String: Any] ?? [:]
            accounts[account] = ["at": Date().timeIntervalSince1970, "rate_limits": limits]
            if let data = try? JSONSerialization.data(withJSONObject: ["accounts": accounts]) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
    exit(0)
}

// MARK: Hooks

guard nodeID != nil else { exit(0) }

/// Only what the canvas uses; the full hook payload carries transcript paths
/// and prompt metadata the app has no business receiving.
let forwarded = ["hook_event_name", "notification_type", "message", "tool_name", "session_id", "cwd", "error", "source"]

var fields: [String: Any] = [:]
if let index = arguments.firstIndex(of: "--event"), index + 1 < arguments.count {
    fields["hook_event_name"] = arguments[index + 1]
    for (flag, key) in [("--type", "notification_type"), ("--message", "message"), ("--tool", "tool_name"), ("--session", "session_id")] {
        if let i = arguments.firstIndex(of: flag), i + 1 < arguments.count { fields[key] = arguments[i + 1] }
    }
} else if let object = (try? JSONSerialization.jsonObject(with: readStdin())) as? [String: Any] {
    for key in forwarded {
        if let value = object[key] as? String { fields[key] = value }
    }
    // The first words name the session in the Sessions menu; the rest stays here.
    if let prompt = object["prompt"] as? String {
        fields["prompt"] = String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }
    // Which account the session runs under; the transcript path itself stays here.
    fields["config_dir"] = ClaudeConfigPath.of(environment: environment, transcriptPath: object["transcript_path"] as? String)
}
guard fields["hook_event_name"] != nil else { exit(0) }
send(fields)
exit(0)
