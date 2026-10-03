import Foundation

/// What Claude Code is asked to do with an issue, as its first prompt.
public enum AgentTask: Equatable, Sendable {
    case implement
    case investigate
    case writeTests
    /// The user's own words; the issue follows them.
    case custom(String)

    public static let builtIn: [AgentTask] = [.implement, .investigate, .writeTests]

    public var title: String {
        switch self {
        case .implement: "Implement"
        case .investigate: "Find the cause of the bug"
        case .writeTests: "Write tests"
        case .custom: "Own task"
        }
    }

    /// The fields of an issue the prompt uses.
    public struct Issue: Equatable, Sendable {
        public var id: String
        public var title: String
        public var description: String?
        public var url: String?
        public var branch: String?

        public init(id: String, title: String, description: String? = nil, url: String? = nil, branch: String? = nil) {
            self.id = id
            self.title = title
            self.description = description
            self.url = url
            self.branch = branch
        }
    }

    /// Long descriptions are cut: the link has the rest.
    public static let descriptionLimit = 6000

    public func prompt(for issue: Issue) -> String {
        let ask: String = switch self {
        case .implement:
            "Implement Linear issue \(issue.id). Read the code involved first, make the change, and run the relevant tests. Tell me what you changed."
        case .investigate:
            "Find the cause of the bug in Linear issue \(issue.id). Reproduce it or trace it through the code, explain the cause, and propose a fix before changing anything."
        case .writeTests:
            "Write tests for Linear issue \(issue.id): cover the behaviour it describes, including edge cases, and run them."
        case .custom(let text):
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var lines = [ask, "", "\(issue.id): \(issue.title)"]
        if let url = issue.url { lines.append(url) }
        if let branch = issue.branch { lines.append("Branch name for this issue: \(branch)") }
        if var description = issue.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            if description.count > Self.descriptionLimit {
                description = String(description.prefix(Self.descriptionLimit)) + "\n… (cut; the full issue is at the link above)"
            }
            lines += ["", "Description:", description]
        }
        return lines.joined(separator: "\n")
    }
}
