import CoreGraphics
import Foundation

public struct BrowserState: Equatable, Sendable, Codable {
    public var url: String
    public init(url: String = "") { self.url = url }
}

public struct TerminalState: Equatable, Sendable, Codable {
    public var workingDirectory: String
    /// The Claude Code session this card hosts, so a restart can resume it.
    public var claudeSessionID: String?
    public init(workingDirectory: String = "", claudeSessionID: String? = nil) {
        self.workingDirectory = workingDirectory
        self.claudeSessionID = claudeSessionID
    }
}

/// The Usage card: Claude Code limits and session costs. No state of its own.
public struct UsageState: Equatable, Sendable, Codable {
    public init() {}
}

public struct CodeState: Equatable, Sendable, Codable {
    public var path: String
    public init(path: String = "") { self.path = path }
}

public struct FilesState: Equatable, Sendable, Codable {
    public var path: String
    public init(path: String = "") { self.path = path }
}

public struct MediaState: Equatable, Sendable, Codable {
    public var path: String
    public init(path: String = "") { self.path = path }
}

public struct ExternalState: Equatable, Sendable, Codable {
    public var bundleID: String
    public init(bundleID: String) { self.bundleID = bundleID }
}

/// The Linear board: where each note sits on the cork and which issues show.
public struct BoardState: Equatable, Sendable, Codable {
    public enum Filter: String, Sendable, Codable, CaseIterable {
        case currentSprint, allMine
    }

    /// Issue number ("ABC-961") → top-left of its note on the board.
    public var positions: [String: CGPoint]
    public var filter: Filter

    public init(positions: [String: CGPoint] = [:], filter: Filter = .allMine) {
        self.positions = positions
        self.filter = filter
    }
}

/// Per-kind payload stored with a node. Must match `Node.kind`.
public enum NodeState: Equatable, Sendable {
    case browser(BrowserState)
    case terminal(TerminalState)
    case code(CodeState)
    case files(FilesState)
    case media(MediaState)
    case external(ExternalState)
    case usage(UsageState)
    case board(BoardState)

    public var kind: NodeKind {
        switch self {
        case .browser: .browser
        case .terminal: .terminal
        case .code: .code
        case .files: .files
        case .media: .media
        case .external(let state): .external(bundleID: state.bundleID)
        case .usage: .usage
        case .board: .board
        }
    }

    func matches(_ kind: NodeKind) -> Bool { self.kind == kind }
}

extension NodeState: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case url
        case workingDirectory
        case claudeSessionID
        case path
        case bundleID
        case positions
        case filter
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .browser(let state):
            try container.encode("browser", forKey: .type)
            try container.encode(state.url, forKey: .url)
        case .terminal(let state):
            try container.encode("terminal", forKey: .type)
            try container.encode(state.workingDirectory, forKey: .workingDirectory)
            try container.encodeIfPresent(state.claudeSessionID, forKey: .claudeSessionID)
        case .code(let state):
            try container.encode("code", forKey: .type)
            try container.encode(state.path, forKey: .path)
        case .files(let state):
            try container.encode("files", forKey: .type)
            try container.encode(state.path, forKey: .path)
        case .media(let state):
            try container.encode("media", forKey: .type)
            try container.encode(state.path, forKey: .path)
        case .external(let state):
            try container.encode("external", forKey: .type)
            try container.encode(state.bundleID, forKey: .bundleID)
        case .usage:
            try container.encode("usage", forKey: .type)
        case .board(let state):
            try container.encode("board", forKey: .type)
            try container.encode(state.positions.mapValues { [$0.x, $0.y] }, forKey: .positions)
            try container.encode(state.filter, forKey: .filter)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "browser":
            self = .browser(BrowserState(url: try container.decodeIfPresent(String.self, forKey: .url) ?? ""))
        case "terminal":
            self = .terminal(TerminalState(
                workingDirectory: try container.decodeIfPresent(String.self, forKey: .workingDirectory) ?? "",
                claudeSessionID: try container.decodeIfPresent(String.self, forKey: .claudeSessionID)
            ))
        case "code":
            self = .code(CodeState(path: try container.decodeIfPresent(String.self, forKey: .path) ?? ""))
        case "files":
            self = .files(FilesState(path: try container.decodeIfPresent(String.self, forKey: .path) ?? ""))
        case "media":
            self = .media(MediaState(path: try container.decodeIfPresent(String.self, forKey: .path) ?? ""))
        case "external":
            self = .external(ExternalState(bundleID: try container.decode(String.self, forKey: .bundleID)))
        case "usage":
            self = .usage(UsageState())
        case "board":
            let raw = try container.decodeIfPresent([String: [Double]].self, forKey: .positions) ?? [:]
            let positions = raw.compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
            self = .board(BoardState(positions: positions, filter: (try? container.decodeIfPresent(BoardState.Filter.self, forKey: .filter)) ?? .allMine))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown node state"
            )
        }
    }
}

/// A window on the canvas. `frame` is in canvas points, y growing downward.
public struct Node: Identifiable, Equatable, Sendable, Codable {
    public var id: UUID
    public var title: String
    public var frame: CGRect
    public var kind: NodeKind
    public var state: NodeState

    public init(id: UUID, title: String, frame: CGRect, kind: NodeKind, state: NodeState) {
        precondition(state.matches(kind), "Node state does not match kind")
        self.id = id
        self.title = title
        self.frame = frame
        self.kind = kind
        self.state = state
    }

    public static func defaultTitle(for kind: NodeKind) -> String {
        switch kind {
        case .browser: "Browser"
        case .terminal: "Terminal"
        case .code: "Editor"
        case .files: "Files"
        case .media: "Media"
        case .external: "App"
        case .usage: "Usage"
        case .board: "Linear"
        }
    }

    public static func defaultSize(for kind: NodeKind) -> CGSize {
        switch kind {
        // The page area is a laptop screen, 1440 × 900 (a MacBook Air's
        // default), under the card's title bar and the address bar.
        case .browser: CGSize(width: 1440, height: 900 + 36 + 36)
        case .external: CGSize(width: 960, height: 640)
        case .terminal: CGSize(width: 720, height: 460)
        case .code: CGSize(width: 800, height: 560)
        case .files: CGSize(width: 680, height: 480)
        case .media: CGSize(width: 640, height: 480)
        case .usage: CGSize(width: 520, height: 440)
        case .board: CGSize(width: 1280, height: 820)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, frame, kind, state
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let title = try container.decode(String.self, forKey: .title)
        let frame = try container.decode(CGRect.self, forKey: .frame)
        let kind = try container.decode(NodeKind.self, forKey: .kind)
        let state = try container.decode(NodeState.self, forKey: .state)
        guard state.matches(kind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .state,
                in: container,
                debugDescription: "Node state does not match kind"
            )
        }
        self.id = id
        self.title = title
        self.frame = frame
        self.kind = kind
        self.state = state
    }
}
