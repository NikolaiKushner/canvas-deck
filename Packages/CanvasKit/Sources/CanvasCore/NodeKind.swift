import Foundation

/// What a canvas node is. External nodes remember the app by bundle id;
/// opening that app is a later step and is not part of the model.
public enum NodeKind: Equatable, Hashable, Sendable {
    case browser
    case terminal
    case code
    case files
    case media
    case external(bundleID: String)
    case usage
    /// The Linear board: my issues as sticky notes on cork.
    case board
}

extension NodeKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case bundleID
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .browser:
            try container.encode("browser", forKey: .type)
        case .terminal:
            try container.encode("terminal", forKey: .type)
        case .code:
            try container.encode("code", forKey: .type)
        case .files:
            try container.encode("files", forKey: .type)
        case .media:
            try container.encode("media", forKey: .type)
        case .external(let bundleID):
            try container.encode("external", forKey: .type)
            try container.encode(bundleID, forKey: .bundleID)
        case .usage:
            try container.encode("usage", forKey: .type)
        case .board:
            try container.encode("board", forKey: .type)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "browser":
            self = .browser
        case "terminal":
            self = .terminal
        case "code":
            self = .code
        case "files":
            self = .files
        case "media":
            self = .media
        case "external":
            self = .external(bundleID: try container.decode(String.self, forKey: .bundleID))
        case "usage":
            self = .usage
        case "board":
            self = .board
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown node kind"
            )
        }
    }
}
