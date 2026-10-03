import Foundation
import Network

/// The redirect of a native app's OAuth sign-in: a one-shot HTTP listener on
/// 127.0.0.1 and a random port. It takes the first request to /callback,
/// answers with a short page and stops.
final class LoopbackRedirect: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.canvasdeck.oauth-redirect")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var finished = false
    /// A callback that came before anyone waited for it.
    private var pending: Result<[String: String], Error>?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening and returns the redirect address.
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<URL, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    ready.resume(returning: URL(string: "http://127.0.0.1:\(self.listener.port?.rawValue ?? 0)/callback")!)
                case .failed(let error):
                    resumed = true
                    ready.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    /// The query of the callback, e.g. `code` and `state`.
    func callback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let pending = self.pending { return continuation.resume(with: pending) }
                self.continuation = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(OAuthTimeout()))
                }
            }
        }
    }

    func stop() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    struct OAuthTimeout: Error, LocalizedError {
        var errorDescription: String? { "Sign-in timed out" }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            guard target.hasPrefix("/callback") else {
                self.respond(connection, status: "404 Not Found", body: "")
                return
            }
            let items = URLComponents(string: "http://127.0.0.1" + target)?.queryItems ?? []
            var query: [String: String] = [:]
            for item in items { query[item.name] = item.value ?? "" }
            let ok = query["code"] != nil
            let message = ok ? "Signed in to Linear. You can close this tab and return to Canvas Deck." : "Sign-in was not completed. You can close this tab."
            self.respond(connection, status: "200 OK", body: """
            <!doctype html><meta charset="utf-8"><title>Canvas Deck</title>
            <body style="font: 15px -apple-system; display: grid; place-items: center; height: 80vh; color: #1f2328"><p>\(message)</p></body>
            """)
            self.finish(.success(query))
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard !finished else { return }
        finished = true
        listener.cancel()
        if let continuation {
            continuation.resume(with: result)
            self.continuation = nil
        } else {
            pending = result
        }
    }
}
