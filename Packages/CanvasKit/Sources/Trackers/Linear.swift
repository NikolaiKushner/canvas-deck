import Foundation

/// A Linear issue, as the Linear MCP server's `list_issues` gives it.
/// Fields the canvas does not use are left out; missing ones are nil.
public struct Issue: Codable, Equatable, Identifiable, Sendable {
    /// "ABC-961".
    public var id: String
    public var uuid: String?
    public var title: String
    public var description: String?
    public var url: URL?
    public var gitBranchName: String?
    /// "Ready for QA".
    public var status: String?
    /// backlog | unstarted | started | completed | canceled | triage.
    public var statusType: String?
    public var priority: Priority?
    public var labels: [String]?
    public var team: String?
    public var teamId: String?
    public var cycleId: String?
    public var updatedAt: Date?

    public struct Priority: Codable, Equatable, Sendable {
        /// 0 none, 1 urgent … 4 low.
        public var value: Int
        public var name: String
    }

    public var isOpen: Bool { statusType.map { !["completed", "canceled"].contains($0) } ?? true }

    public init(id: String, title: String, status: String? = nil, statusType: String? = nil, teamId: String? = nil, cycleId: String? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.statusType = statusType
        self.teamId = teamId
        self.cycleId = cycleId
        self.updatedAt = updatedAt
    }
}

/// A workflow state of a team, with Linear's colour for it.
public struct IssueStatus: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var type: String?
    /// "#f2c94c".
    public var color: String?
}

public struct Cycle: Codable, Equatable, Sendable {
    public var id: String
    public var number: Int?
    /// The MCP server calls it `title` ("Sprint 42"); Linear's API, `name`.
    public var name: String?
    public var startsAt: Date?
    public var endsAt: Date?

    enum CodingKeys: String, CodingKey { case id, number, name, title, startsAt, endsAt }

    public init(id: String, number: Int? = nil, name: String? = nil, startsAt: Date? = nil, endsAt: Date? = nil) {
        self.id = id
        self.number = number
        self.name = name
        self.startsAt = startsAt
        self.endsAt = endsAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        number = try container.decodeIfPresent(Int.self, forKey: .number)
        name = try container.decodeIfPresent(String.self, forKey: .title) ?? container.decodeIfPresent(String.self, forKey: .name)
        startsAt = try container.decodeIfPresent(Date.self, forKey: .startsAt)
        endsAt = try container.decodeIfPresent(Date.self, forKey: .endsAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(number, forKey: .number)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(startsAt, forKey: .startsAt)
        try container.encodeIfPresent(endsAt, forKey: .endsAt)
    }

    /// "Cycle 42" when it has no name.
    public var title: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? number.map { "Cycle \($0)" } ?? "Current cycle" }
}

/// An item of the Linear inbox: a comment, a mention, a status change.
public struct LinearNotification: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// "issueNewComment", "issueCommentMention", "pullRequestApproved", …
    public var type: String?
    public var title: String?
    public var subtitle: String?
    public var url: URL?
    public var createdAt: Date?
    public var readAt: Date?
}

public struct LinearUser: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var email: String?
    public var displayName: String?
}

/// Linear through its MCP server: the same tools an agent calls, used as a
/// program would. Tool output is JSON text; decoding is lenient so a new
/// field never breaks it and a missing one is just nil.
public struct LinearMCP: Sendable {
    public static let server = URL(string: "https://mcp.linear.app")!
    public static let endpoint = URL(string: "https://mcp.linear.app/mcp")!

    private let client: MCPClient

    public init(client: MCPClient) {
        self.client = client
    }

    public func me() async throws -> LinearUser {
        try Self.decode(LinearUser.self, from: try await client.callTool("get_user", arguments: ["query": "me"]))
    }

    /// Open issues assigned to me; only those changed since `updatedAfter` when given.
    public func myIssues(updatedAfter: Date? = nil) async throws -> [Issue] {
        var issues: [Issue] = []
        var cursor: String?
        repeat {
            var arguments: [String: any Sendable] = ["assignee": "me", "limit": 100, "orderBy": "updatedAt"]
            if let updatedAfter { arguments["updatedAt"] = ISO8601DateFormatter().string(from: updatedAfter) }
            if let cursor { arguments["cursor"] = cursor }
            let page = try Self.decode(Page.self, from: try await client.callTool("list_issues", arguments: arguments))
            issues += page.issues
            cursor = page.hasNextPage == true ? page.cursor : nil
        } while cursor != nil && issues.count < 1000
        return issues
    }

    public func currentCycle(team: String) async throws -> Cycle? {
        let text = try await client.callTool("list_cycles", arguments: ["teamId": team, "type": "current"])
        return try Self.decodeList(Cycle.self, key: "cycles", from: text).first
    }

    public func statuses(team: String) async throws -> [IssueStatus] {
        let text = try await client.callTool("list_issue_statuses", arguments: ["team": team])
        return try Self.decodeList(IssueStatus.self, key: "statuses", from: text)
    }

    /// One issue in full (the list cuts descriptions short).
    public func issue(_ id: String) async throws -> Issue {
        let text = try await client.callTool("get_issue", arguments: ["id": id])
        if let issue = try? Self.decode(Issue.self, from: text) { return issue }
        // Some answers wrap it: {"issue": {...}}.
        struct Wrapped: Decodable { var issue: Issue }
        return try Self.decode(Wrapped.self, from: text).issue
    }

    /// The inbox, newest first.
    public func notifications(unreadOnly: Bool = true, limit: Int = 20) async throws -> [LinearNotification] {
        let text = try await client.callTool("get_notifications", arguments: ["unreadOnly": unreadOnly, "limit": limit])
        return try Self.decodeList(LinearNotification.self, key: "notifications", from: text)
    }

    /// Moves an issue to a workflow state (its name or id).
    public func setState(_ issue: String, to state: String) async throws {
        _ = try await client.callTool("save_issue", arguments: ["id": issue, "state": state])
    }

    /// Puts an issue in a cycle, or takes it out with nil: whatever the
    /// tool's schema says "none" is (null, else an empty string).
    public func setCycle(_ issue: String, to cycle: String?) async throws {
        if let cycle {
            _ = try await client.callTool("save_issue", arguments: ["id": issue, "cycle": cycle])
            return
        }
        let schema = try await client.inputSchema(of: "save_issue")
        let acceptsNull = schema.map { Self.acceptsNull(property: "cycle", in: $0) } ?? true
        let none: any Sendable = acceptsNull ? NSNull() : ""
        _ = try await client.callTool("save_issue", arguments: ["id": issue, "cycle": none])
    }

    /// Whether a JSON schema lets `property` be null.
    public static func acceptsNull(property: String, in schema: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: schema)) as? [String: Any],
              let properties = object["properties"] as? [String: Any],
              let field = properties[property] as? [String: Any] else { return false }
        if let type = field["type"] as? String { return type == "null" }
        if let types = field["type"] as? [String] { return types.contains("null") }
        for key in ["anyOf", "oneOf"] {
            if let options = field[key] as? [[String: Any]], options.contains(where: { $0["type"] as? String == "null" }) { return true }
        }
        return false
    }

    struct Page: Decodable {
        var issues: [Issue]
        var hasNextPage: Bool?
        var cursor: String?
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "date \(text)"))
        }
        return decoder
    }()

    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        do { return try decoder.decode(T.self, from: Data(text.utf8)) } catch {
            throw MCPClient.Failure.malformed("\(T.self): \(text.prefix(120))")
        }
    }

    /// A bare array, or an object holding one under `key` (or its only array).
    public static func decodeList<T: Decodable>(_ type: T.Type, key: String, from text: String) throws -> [T] {
        let data = Data(text.utf8)
        if let list = try? decoder.decode([T].self, from: data) { return list }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MCPClient.Failure.malformed("\(T.self) list: \(text.prefix(120))")
        }
        let array = object[key] ?? object.values.first { $0 is [Any] }
        guard let array, let json = try? JSONSerialization.data(withJSONObject: array) else { return [] }
        return (try? decoder.decode([T].self, from: json)) ?? []
    }
}
