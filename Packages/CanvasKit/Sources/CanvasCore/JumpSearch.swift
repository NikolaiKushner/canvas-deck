import Foundation

/// A row of the ⌘K palette: a card to fly to, a command, or a past session.
public struct JumpItem: Identifiable, Equatable, Sendable {
    public enum Group: Int, Comparable, Sendable {
        /// Agents waiting for an answer come first.
        case waiting, card, command, recent
        public static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: String
    public var title: String
    public var subtitle: String
    /// Searched too, worth less than the title: a folder, an account, a status.
    public var keywords: [String]
    public var group: Group
    /// Order inside a group with no query; higher first (e.g. last active).
    public var rank: Double

    public init(id: String, title: String, subtitle: String = "", keywords: [String] = [], group: Group, rank: Double = 0) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.group = group
        self.rank = rank
    }
}

public enum JumpSearch {
    /// With no query: by group, then rank. With one: by how well it matches —
    /// a word that starts with it beats it inside a word, which beats its
    /// letters in order — with the title worth more than the rest and a small
    /// lift for waiting agents and cards over commands and old sessions.
    public static func rank(_ items: [JumpItem], query: String) -> [JumpItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            return items.sorted { a, b in a.group != b.group ? a.group < b.group : a.rank > b.rank }
        }
        let scored: [(JumpItem, Double)] = items.compactMap { item in
            let title = score(q, in: item.title).map { $0 * 1.0 }
            let rest = ([item.subtitle] + item.keywords).compactMap { score(q, in: $0) }.max().map { $0 * 0.7 }
            guard let best = [title, rest].compactMap({ $0 }).max() else { return nil }
            let lift: Double = switch item.group {
            case .waiting: 12
            case .card: 8
            case .command: 4
            case .recent: 0
            }
            return (item, best + lift)
        }
        return scored.sorted { a, b in a.1 != b.1 ? a.1 > b.1 : a.0.rank > b.0.rank }.map(\.0)
    }

    /// How well `query` (lowercased) matches `text`, nil for not at all.
    static func score(_ query: String, in text: String) -> Double? {
        let text = text.lowercased()
        guard !text.isEmpty else { return nil }
        if text == query { return 120 }
        if text.hasPrefix(query) { return 110 - Double(text.count - query.count) * 0.1 }
        // The start of a word: "web" in "acme_web".
        var index = text.startIndex
        while let range = text.range(of: query, range: index..<text.endIndex) {
            let start = range.lowerBound
            if start == text.startIndex || !text[text.index(before: start)].isLetter && !text[text.index(before: start)].isNumber {
                return 90 - Double(text.distance(from: text.startIndex, to: start)) * 0.2
            }
            index = text.index(after: start)
        }
        if let range = text.range(of: query) {
            return 60 - Double(text.distance(from: text.startIndex, to: range.lowerBound)) * 0.2
        }
        // Letters in order: "scc" in "se canvas cards".
        var gaps = 0
        var position = text.startIndex
        for character in query {
            guard let found = text[position...].firstIndex(of: character) else { return nil }
            gaps += text.distance(from: position, to: found)
            position = text.index(after: found)
        }
        return max(1, 30 - Double(gaps) * 0.5)
    }
}
