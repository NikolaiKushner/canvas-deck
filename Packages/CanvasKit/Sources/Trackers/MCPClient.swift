import Foundation

/// A Model Context Protocol client over Streamable HTTP: JSON-RPC posted to
/// one endpoint, answers as JSON or as a server-sent event stream. Enough for
/// calling a server's tools; this app is a client like any agent.
public actor MCPClient {
    public enum Failure: Error, Equatable, LocalizedError {
        /// The token is missing, expired or revoked: sign in again.
        case unauthorized
        case http(Int)
        case rpc(Int, String)
        case tool(String)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .unauthorized: "Not signed in, or the sign-in has expired"
            case .http(let code): "The server answered \(code)"
            case .rpc(let code, let message): "Server error \(code): \(message)"
            case .tool(let message): message
            case .malformed(let what): "Unexpected answer: \(what)"
            }
        }
    }

    public static let protocolVersion = "2025-06-18"

    private let endpoint: URL
    private let session: URLSession
    private let token: @Sendable () async throws -> String
    private var sessionID: String?
    private var initialized = false
    private var nextID = 1

    /// `token` is asked before every request, so it can refresh as needed.
    public init(endpoint: URL, session: URLSession = .shared, token: @escaping @Sendable () async throws -> String) {
        self.endpoint = endpoint
        self.session = session
        self.token = token
    }

    /// The text a tool returned. A tool's own error ("isError") throws `.tool`.
    public func callTool(_ name: String, arguments: [String: any Sendable] = [:]) async throws -> String {
        try await ensureInitialized()
        let result = try await request("tools/call", params: ["name": name, "arguments": arguments])
        let content = result["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        if result["isError"] as? Bool == true { throw Failure.tool(text.isEmpty ? "The tool failed" : text) }
        return text
    }

    private var schemas: [String: Data]?

    /// A tool's input schema as JSON, from `tools/list` (read once).
    public func inputSchema(of tool: String) async throws -> Data? {
        if schemas == nil {
            try await ensureInitialized()
            let result = try await request("tools/list", params: [:])
            var found: [String: Data] = [:]
            for entry in result["tools"] as? [[String: Any]] ?? [] {
                guard let name = entry["name"] as? String, let schema = entry["inputSchema"],
                      let data = try? JSONSerialization.data(withJSONObject: schema) else { continue }
                found[name] = data
            }
            schemas = found
        }
        return schemas?[tool]
    }

    public func toolNames() async throws -> [String] {
        try await ensureInitialized()
        let result = try await request("tools/list", params: [:])
        return (result["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    /// Forget the server session, e.g. after signing in again.
    public func reset() {
        sessionID = nil
        initialized = false
        schemas = nil
    }

    private func ensureInitialized() async throws {
        guard !initialized else { return }
        _ = try await request("initialize", params: [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "canvas-station", "version": "0.0.1"],
        ])
        try await notify("notifications/initialized")
        initialized = true
    }

    private func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let (data, contentType) = try await post(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        guard let message = try Self.message(id: id, in: data, contentType: contentType) else {
            throw Failure.malformed("no answer to \(method)")
        }
        if let error = message["error"] as? [String: Any] {
            throw Failure.rpc(error["code"] as? Int ?? 0, error["message"] as? String ?? "")
        }
        return message["result"] as? [String: Any] ?? [:]
    }

    private func notify(_ method: String) async throws {
        _ = try await post(["jsonrpc": "2.0", "method": method])
    }

    private func post(_ message: [String: Any]) async throws -> (Data, String) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue("Bearer " + (try await token()), forHTTPHeaderField: "Authorization")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return (data, "") }
        if http.statusCode == 401 || http.statusCode == 403 { throw Failure.unauthorized }
        // The server ended the session: start a new one next time.
        if http.statusCode == 404, sessionID != nil {
            reset()
            throw Failure.http(404)
        }
        guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = id }
        return (data, http.value(forHTTPHeaderField: "Content-Type") ?? "")
    }

    /// The JSON-RPC message answering `id`, from a JSON body or an event stream.
    public static func message(id: Int, in data: Data, contentType: String) throws -> [String: Any]? {
        if contentType.contains("text/event-stream") {
            var found: [String: Any]?
            // Events are separated by blank lines; data lines of one event join with "\n".
            for event in String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
                let payload = event.split(separator: "\n")
                    .filter { $0.hasPrefix("data:") }
                    .map { $0.dropFirst(5).drop { $0 == " " } }
                    .joined(separator: "\n")
                guard !payload.isEmpty, let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
                if object["id"] as? Int == id { found = object }
            }
            return found
        }
        guard !data.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw Failure.malformed("not JSON") }
        if let single = object as? [String: Any] { return single }
        return (object as? [[String: Any]])?.first { $0["id"] as? Int == id }
    }
}
