import CoreGraphics
import Foundation

/// The document written to `canvas.json` in a later step: camera plus nodes.
public struct Layout: Equatable, Sendable, Codable {
    public static let currentVersion = 1

    public var version: Int
    public var camera: Camera
    public var nodes: [Node]

    public init(
        version: Int = Layout.currentVersion,
        camera: Camera = Camera(center: .zero, scale: 1),
        nodes: [Node] = []
    ) {
        self.version = version
        self.camera = camera
        self.nodes = nodes
    }

    public func node(id: UUID) -> Node? {
        nodes.first { $0.id == id }
    }

    public var contentBounds: CGRect? {
        guard let first = nodes.first else { return nil }
        return nodes.dropFirst().reduce(first.frame) { $0.union($1.frame) }
    }

    /// Top-left goes at `point` when that spot is free. Otherwise the frame steps
    /// right, then down, leaving `gap` points between nodes.
    public func freeFrame(near point: CGPoint, size: CGSize, gap: CGFloat = 24) -> CGRect {
        guard size.width > 0, size.height > 0 else {
            return CGRect(origin: point, size: size)
        }
        let stepX = size.width + gap
        let stepY = size.height + gap
        for row in 0..<8 {
            for column in 0..<6 {
                let origin = CGPoint(
                    x: point.x + CGFloat(column) * stepX,
                    y: point.y + CGFloat(row) * stepY
                )
                let candidate = CGRect(origin: origin, size: size)
                if !overlaps(candidate, gap: gap) { return candidate }
            }
        }
        let maxX = nodes.map(\.frame.maxX).max() ?? point.x
        return CGRect(x: maxX + gap, y: point.y, width: size.width, height: size.height)
    }

    private func overlaps(_ candidate: CGRect, gap: CGFloat) -> Bool {
        let expanded = candidate.insetBy(dx: -gap, dy: -gap)
        return nodes.contains { $0.frame.intersects(expanded) }
    }
}
