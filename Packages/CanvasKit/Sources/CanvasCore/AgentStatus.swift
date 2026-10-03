import Foundation

/// What an agent in a terminal card is doing.
public enum AgentState: String, Codable, Sendable {
    /// Nothing to report: a plain shell, or a Claude Code session waiting for its first prompt.
    case idle
    case working
    case waiting
    /// Finished its turn.
    case done
    case error
}

/// Why an agent is waiting. The overview plaque, notices and quick replies
/// treat these differently: a permission is usually one keystroke.
public enum WaitReason: String, Codable, Sendable {
    case permission
    case question
    /// Idle prompt, a bell, a terminal notification: something wants a look.
    case input
}

/// Something that happened in or around a terminal card.
public enum AgentEvent: Equatable, Sendable {
    // Claude Code hooks, delivered by `canvas-notify`.
    case sessionStarted
    case promptSubmitted
    case toolFinished
    case permissionRequested(tool: String?)
    case needsAttention(WaitReason, message: String?)
    case stopped
    case failed(message: String?)
    case sessionEnded
    // The terminal itself.
    case bell
    case terminalNotification(title: String, body: String)
    case userInput

    /// Maps a Claude Code hook payload to an event. Unknown events and
    /// notification types that need no attention return nil.
    public static func fromHook(
        event: String,
        notificationType: String? = nil,
        message: String? = nil,
        toolName: String? = nil
    ) -> AgentEvent? {
        switch event {
        case "SessionStart": return .sessionStarted
        case "UserPromptSubmit": return .promptSubmitted
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied": return .toolFinished
        case "PermissionRequest": return .permissionRequested(tool: toolName)
        case "Stop": return .stopped
        case "StopFailure": return .failed(message: message)
        case "SessionEnd": return .sessionEnded
        case "Notification":
            switch notificationType {
            case "permission_prompt": return .needsAttention(.permission, message: message)
            case "idle_prompt": return .needsAttention(.input, message: message)
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                return .needsAttention(.question, message: message)
            case "elicitation_complete", "elicitation_response": return .toolFinished
            case nil:
                // Older Claude Code without `notification_type`.
                let text = message?.lowercased() ?? ""
                return .needsAttention(text.contains("permission") ? .permission : .input, message: message)
            default:
                return nil
            }
        default:
            return nil
        }
    }
}

public struct AgentStatus: Equatable, Codable, Sendable {
    public var state: AgentState
    public var reason: WaitReason?
    /// Tool name for a permission, otherwise the agent's own message.
    public var detail: String?
    /// A Claude Code session with our hooks is live in this card. Hooks are
    /// exact, so while this is set bells and terminal notifications are ignored.
    public var hooked: Bool
    public var updatedAt: Date

    public init(state: AgentState, reason: WaitReason? = nil, detail: String? = nil, hooked: Bool = false, updatedAt: Date) {
        self.state = state
        self.reason = reason
        self.detail = detail
        self.hooked = hooked
        self.updatedAt = updatedAt
    }

    public static let initial = AgentStatus(state: .idle, updatedAt: .distantPast)

    /// The status after `event` at `date`. Hooks run as separate processes, so
    /// their events can arrive out of order; one older than the current status
    /// is dropped.
    public func applying(_ event: AgentEvent, at date: Date) -> AgentStatus {
        guard date >= updatedAt else { return self }
        var next = self
        next.updatedAt = date
        switch event {
        case .sessionStarted:
            next.set(.idle, hooked: true)
        case .promptSubmitted, .toolFinished:
            next.set(.working, hooked: true)
        case .permissionRequested(let tool):
            let known = reason == .permission ? detail : nil
            next.set(.waiting, reason: .permission, detail: tool ?? known, hooked: true)
        case .needsAttention(let why, let message):
            if why == .permission {
                let known = state == .waiting && reason == .permission ? detail : nil
                next.set(.waiting, reason: .permission, detail: known ?? Self.toolName(in: message), hooked: true)
            } else {
                next.set(.waiting, reason: why, detail: message, hooked: true)
            }
        case .stopped:
            next.set(.done, hooked: true)
        case .failed(let message):
            next.set(.error, detail: message, hooked: true)
        case .sessionEnded:
            next.set(.idle, hooked: false)
        case .bell:
            guard !hooked else { return self }
            next.set(.waiting, reason: .input, hooked: false)
        case .terminalNotification(let title, let body):
            guard !hooked else { return self }
            next.set(.waiting, reason: .input, detail: body.isEmpty ? title : body, hooked: false)
        case .userInput:
            if hooked, state == .waiting, reason == .permission {
                // Approving is a keystroke, and no hook fires until the tool
                // finishes. A denial is corrected by the next hook.
                next.set(.working, hooked: true)
            } else if !hooked, state == .waiting {
                next.set(.idle, hooked: false)
            } else {
                return self
            }
        }
        return next
    }

    private mutating func set(_ state: AgentState, reason: WaitReason? = nil, detail: String? = nil, hooked: Bool) {
        self.state = state
        self.reason = reason
        self.detail = detail
        self.hooked = hooked
    }

    /// "Claude needs your permission to use Bash" → "Bash".
    static func toolName(in message: String?) -> String? {
        guard let message, let range = message.range(of: "permission to use ") else { return nil }
        let tool = message[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return tool.isEmpty ? nil : tool
    }

    /// Short text for the card's title bar; nil when there is nothing to show.
    public var label: String? {
        switch state {
        case .idle: nil
        case .working: "Working"
        case .waiting:
            switch reason {
            case .permission: detail.map { "Permission: \($0)" } ?? "Needs permission"
            case .question: "Asking a question"
            case .input, nil: "Waiting"
            }
        case .done: "Done"
        case .error: "Error"
        }
    }
}
