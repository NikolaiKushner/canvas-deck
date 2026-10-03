import Foundation

/// `canvas.json`: reading it back and deciding what to do with a file this
/// build cannot use.
public enum LayoutFile {
    public enum Outcome: Equatable {
        case layout(Layout)
        /// Written by a newer build: keep it aside, start empty.
        case newer(version: Int)
        /// Not a layout: keep it aside, start empty.
        case unreadable
    }

    public static func decode(_ data: Data) -> Outcome {
        struct Header: Decodable { let version: Int? }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { return .unreadable }
        if let version = header.version, version > Layout.currentVersion { return .newer(version: version) }
        guard let layout = try? JSONDecoder().decode(Layout.self, from: data) else { return .unreadable }
        return .layout(layout.restorable())
    }

    public static func encode(_ layout: Layout) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(layout)
    }
}

extension Layout {
    /// What comes back after a restart. Installed-app cards are dropped: their
    /// windows belong to another process and cannot be bound again (the hybrid
    /// is parked under Debug).
    public func restorable() -> Layout {
        var copy = self
        copy.nodes.removeAll { if case .external = $0.kind { true } else { false } }
        return copy
    }
}
