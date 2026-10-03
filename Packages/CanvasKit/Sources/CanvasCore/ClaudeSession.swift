import Foundation

/// A Claude Code session the canvas started or resumed. Kept in `sessions.json`
/// so closed sessions can be reopened from the Sessions menu.
public struct ClaudeSession: Codable, Equatable, Identifiable, Sendable {
    /// Claude Code's session id (what `--resume` takes).
    public var id: String
    /// The card hosting it while it is open.
    public var nodeID: UUID?
    public var cwd: String
    public var issueID: String?
    /// Set with `--name`; wins over everything else in the title.
    public var name: String?
    public var firstPrompt: String?
    public var openedAt: Date
    public var lastActiveAt: Date
    public var closedAt: Date?

    public init(id: String, nodeID: UUID?, cwd: String, issueID: String? = nil, name: String? = nil, firstPrompt: String? = nil, openedAt: Date, closedAt: Date? = nil) {
        self.id = id
        self.nodeID = nodeID
        self.cwd = cwd
        self.issueID = issueID
        self.name = name
        self.firstPrompt = firstPrompt
        self.openedAt = openedAt
        self.lastActiveAt = openedAt
        self.closedAt = closedAt
    }

    public var isOpen: Bool { closedAt == nil && nodeID != nil }

    /// Ticket number, else the given name, else the first words of the first
    /// prompt, else the folder.
    public var title: String {
        if let issueID, !issueID.isEmpty { return issueID }
        if let name, !name.isEmpty { return name }
        if let prompt = firstPrompt.map({ Self.shorten($0) }), !prompt.isEmpty { return prompt }
        let folder = (cwd as NSString).lastPathComponent
        return folder.isEmpty ? "Claude Code" : folder
    }

    /// First line, whitespace collapsed, cut at a word boundary near `limit`.
    public static func shorten(_ text: String, limit: Int = 48) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let words = firstLine.split(whereSeparator: \.isWhitespace)
        var result = ""
        for word in words {
            let candidate = result.isEmpty ? String(word) : result + " " + word
            if candidate.count > limit {
                if result.isEmpty { return String(candidate.prefix(limit - 1)) + "…" }
                return result + "…"
            }
            result = candidate
        }
        return result
    }
}

/// The session index with its rules: one open session per card, newest first,
/// bounded in size.
public struct ClaudeSessionIndex: Codable, Equatable, Sendable {
    public static let limit = 200
    public var sessions: [ClaudeSession] = []

    public init(sessions: [ClaudeSession] = []) {
        self.sessions = sessions
    }

    public func session(id: String) -> ClaudeSession? { sessions.first { $0.id == id } }
    public func openSession(node: UUID) -> ClaudeSession? { sessions.first { $0.nodeID == node && $0.closedAt == nil } }

    public var open: [ClaudeSession] { sessions.filter(\.isOpen) }
    public var recent: [ClaudeSession] {
        sessions.filter { !$0.isOpen }.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    /// A card now runs `id`. Any other session open in that card ends (e.g.
    /// `/clear` starts a new id); a known id is reopened rather than duplicated.
    public mutating func attach(id: String, node: UUID, cwd: String, name: String? = nil, issueID: String? = nil, at date: Date) {
        for index in sessions.indices where sessions[index].nodeID == node && sessions[index].id != id && sessions[index].closedAt == nil {
            sessions[index].closedAt = date
            sessions[index].nodeID = nil
        }
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].nodeID = node
            sessions[index].closedAt = nil
            sessions[index].lastActiveAt = date
            if let name { sessions[index].name = name }
            if let issueID { sessions[index].issueID = issueID }
        } else {
            sessions.insert(ClaudeSession(id: id, nodeID: node, cwd: cwd, issueID: issueID, name: name, openedAt: date), at: 0)
            if sessions.count > Self.limit { sessions.removeLast(sessions.count - Self.limit) }
        }
    }

    public mutating func notePrompt(_ prompt: String, id: String, at date: Date) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[index].firstPrompt == nil { sessions[index].firstPrompt = prompt }
        sessions[index].lastActiveAt = date
    }

    public mutating func touch(id: String, at date: Date) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].lastActiveAt = max(sessions[index].lastActiveAt, date)
    }

    /// Claude Code exited, or the card closed.
    public mutating func close(id: String, at date: Date) {
        guard let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].closedAt == nil else { return }
        sessions[index].closedAt = date
        sessions[index].nodeID = nil
    }

    public mutating func closeAll(node: UUID, at date: Date) {
        for index in sessions.indices where sessions[index].nodeID == node && sessions[index].closedAt == nil {
            sessions[index].closedAt = date
            sessions[index].nodeID = nil
        }
    }

    /// On launch no card from a previous run is live yet.
    public mutating func closeAllOpen(at date: Date) {
        for index in sessions.indices where sessions[index].closedAt == nil {
            sessions[index].closedAt = date
            sessions[index].nodeID = nil
        }
    }
}
