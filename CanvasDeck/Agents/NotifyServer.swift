import CanvasCore
import Foundation
import Usage

/// One line from `canvas-notify`: a hook (mapped to an agent event when it
/// moves the card's state) or a status line snapshot.
struct NotifyMessage {
    /// Nil for a status line snapshot from a session outside the canvas.
    let nodeID: UUID?
    let hook: String
    let event: AgentEvent?
    let sentAt: Date
    let sessionID: String?
    let cwd: String?
    /// First words of the prompt, from `UserPromptSubmit`.
    let prompt: String?
    /// `SessionStart`: startup, resume, clear or compact.
    let source: String?
    let statusline: StatuslinePayload?
    /// The session's account: its Claude Code configuration folder.
    let configDir: String?
}

/// Unix socket that `canvas-notify` writes to. Each connection carries one
/// JSON line. Accept and read happen off the main thread; parsed messages are
/// delivered on the main queue.
final class NotifyServer: @unchecked Sendable {
    static var defaultPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CanvasDeck/notify.sock").path
    }

    let path: String
    var onMessage: (@MainActor (NotifyMessage) -> Void)?

    private let queue = DispatchQueue(label: "app.canvasdeck.notify")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String = NotifyServer.defaultPath) {
        self.path = path
    }

    enum StartError: Error { case pathTooLong, socket(Int32), bind(Int32), listen(Int32) }

    func start() throws {
        guard listenFD < 0 else { return }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        // A socket file left by a previous run would make bind fail.
        unlink(path)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw StartError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socket(errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(fd); throw StartError.bind(errno) }
        // Only this user may write agent states into the canvas.
        chmod(path, 0o600)
        guard listen(fd, 32) == 0 else { close(fd); throw StartError.listen(errno) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        listenFD = fd
    }

    func stop() {
        source?.cancel()
        source = nil
        listenFD = -1
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            // BSD accept() hands down O_NONBLOCK; the read below wants to block (with a timeout).
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let data = Self.readAll(client)
            close(client)
            guard let message = Self.parse(data) else { continue }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onMessage?(message) }
            }
        }
    }

    private static func readAll(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 64 * 1024 {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    static func parse(_ data: Data) -> NotifyMessage? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = object["hook_event_name"] as? String else { return nil }
        let node = (object["canvas_node_id"] as? String).flatMap(UUID.init(uuidString:))
        guard node != nil || name == "StatusLine" else { return nil }
        let sentAt = (object["canvas_sent_at"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
        var statusline: StatuslinePayload?
        if name == "StatusLine", let raw = object["statusline"],
           let json = try? JSONSerialization.data(withJSONObject: raw) {
            statusline = StatuslinePayload.decode(json)
        }
        let message = (object["message"] as? String) ?? (object["error"] as? String)
        let event = AgentEvent.fromHook(
            event: name,
            notificationType: object["notification_type"] as? String,
            message: message,
            toolName: object["tool_name"] as? String
        )
        return NotifyMessage(
            nodeID: node,
            hook: name,
            event: event,
            sentAt: sentAt,
            sessionID: (object["session_id"] as? String) ?? statusline?.sessionID,
            cwd: object["cwd"] as? String,
            prompt: object["prompt"] as? String,
            source: object["source"] as? String,
            statusline: statusline,
            configDir: (object["config_dir"] as? String).map { ClaudeConfigPath.normalize($0) }
        )
    }
}
