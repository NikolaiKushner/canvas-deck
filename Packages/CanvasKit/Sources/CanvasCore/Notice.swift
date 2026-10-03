import Foundation

/// One message in the canvas notice centre: a toast in the top-right corner
/// and, while the window is in the background, a macOS notification. Every
/// kind of card posts through the same queue.
public struct Notice: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case info, waiting, done, error
    }

    public enum Action: String, Sendable {
        /// Answer a permission prompt: "1" is Yes in every variant of
        /// Claude Code's dialog (2.1.284, checked in a pty).
        case allow
        /// Esc cancels the prompt; the number of "No" differs between variants.
        case deny
        /// Fly to the card and give it the keyboard.
        case open
    }

    public var id: UUID
    public var sourceNodeID: UUID?
    public var kind: Kind
    public var title: String
    public var text: String
    public var actions: [Action]
    /// Stays until its source resolves it (an agent waiting for an answer).
    public var sticky: Bool
    public var postedAt: Date
    /// A page to open instead of flying to the card (a Linear comment).
    public var link: String?
    /// When a non-sticky notice goes by itself; nil while it is sticky or hovered.
    public var expiresAt: Date?

    public init(id: UUID = UUID(), sourceNodeID: UUID?, kind: Kind, title: String, text: String,
                actions: [Action] = [.open], sticky: Bool = false, postedAt: Date, link: String? = nil) {
        self.id = id
        self.sourceNodeID = sourceNodeID
        self.kind = kind
        self.title = title
        self.text = text
        self.actions = actions
        self.sticky = sticky
        self.postedAt = postedAt
        self.link = link
        self.expiresAt = sticky ? nil : postedAt.addingTimeInterval(Self.lifetime(kind))
    }

    /// Info and done go after 8 s, errors after 20 s; waiting stays.
    public static func lifetime(_ kind: Kind) -> TimeInterval {
        switch kind {
        case .info, .done: 8
        case .error: 20
        case .waiting: .infinity
        }
    }

    /// What an agent's state change means for the notice centre.
    public enum Change: Equatable, Sendable {
        case post(Notice)
        /// The card needs nothing any more: its notices go.
        case resolve(UUID)
        case none
    }

    /// `title` names the card: its session title or folder.
    public static func change(from old: AgentStatus, to new: AgentStatus, node: UUID, title: String, at date: Date) -> Change {
        switch new.state {
        case .waiting:
            switch new.reason {
            case .permission where new.hooked:
                let text = new.detail.map { "Wants permission: \($0)" } ?? "Needs permission"
                return .post(Notice(sourceNodeID: node, kind: .waiting, title: title, text: text, actions: [.allow, .deny, .open], sticky: true, postedAt: date))
            case .question where new.hooked:
                return .post(Notice(sourceNodeID: node, kind: .waiting, title: title, text: new.detail ?? "Asking a question", actions: [.open], sticky: true, postedAt: date))
            case .input where !new.hooked:
                // A bell or an OSC notification from a plain terminal.
                return .post(Notice(sourceNodeID: node, kind: .info, title: title, text: new.detail ?? "Bell", postedAt: date))
            default:
                // Claude Code's "waiting for your input" after a reply: the
                // "done" notice has already said it.
                return .none
            }
        case .done:
            guard old.state != .done else { return .none }
            return .post(Notice(sourceNodeID: node, kind: .done, title: title, text: "Finished", postedAt: date))
        case .error:
            return .post(Notice(sourceNodeID: node, kind: .error, title: title, text: new.detail ?? "Stopped with an error", postedAt: date))
        case .working, .idle:
            return old.state == new.state ? .none : .resolve(node)
        }
    }
}

/// The notices in order of arrival, one per card at most.
public struct NoticeQueue: Equatable, Sendable {
    public static let visibleLimit = 5
    public private(set) var notices: [Notice] = []

    public init() {}

    /// A card's new notice replaces its old one.
    @discardableResult
    public mutating func post(_ notice: Notice) -> [Notice] {
        let replaced = notices.filter { notice.sourceNodeID != nil && $0.sourceNodeID == notice.sourceNodeID }
        notices.removeAll { notice.sourceNodeID != nil && $0.sourceNodeID == notice.sourceNodeID }
        notices.append(notice)
        return replaced
    }

    @discardableResult
    public mutating func resolve(source: UUID) -> [Notice] {
        let gone = notices.filter { $0.sourceNodeID == source }
        notices.removeAll { $0.sourceNodeID == source }
        return gone
    }

    @discardableResult
    public mutating func dismiss(_ id: UUID) -> Notice? {
        guard let index = notices.firstIndex(where: { $0.id == id }) else { return nil }
        return notices.remove(at: index)
    }

    /// Removes the notices whose time is up.
    @discardableResult
    public mutating func expire(at now: Date) -> [Notice] {
        let gone = notices.filter { ($0.expiresAt ?? .distantFuture) <= now }
        notices.removeAll { ($0.expiresAt ?? .distantFuture) <= now }
        return gone
    }

    /// Hovering holds a notice; leaving gives it a few more seconds.
    public mutating func hold(_ id: UUID, _ holding: Bool, at now: Date) {
        guard let index = notices.firstIndex(where: { $0.id == id }), !notices[index].sticky else { return }
        notices[index].expiresAt = holding ? nil : now.addingTimeInterval(4)
    }

    /// The oldest first; what does not fit is counted.
    public var visible: (shown: [Notice], more: Int) {
        (Array(notices.prefix(Self.visibleLimit)), max(0, notices.count - Self.visibleLimit))
    }
}
