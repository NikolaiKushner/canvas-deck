import CoreGraphics
import Foundation

/// Looks at `center` in canvas points. `scale` is screen points per canvas point.
/// Both the viewport and the canvas use a top-left origin with y growing downward,
/// matching the flipped document view.
public struct Camera: Equatable, Sendable {
    /// 16% … 256%: 0x10 … 0x100, as in the zoom pill.
    public static let minScale: CGFloat = 0.16
    public static let maxScale: CGFloat = 2.56
    /// Fit All and Zoom to Card stop here: a small card is not blown up to 256%.
    public static let fitMaxScale: CGFloat = 1.5
    /// A zoom that lands inside this distance of 1 sticks to 1.
    public static let snapEnterBand: CGFloat = 0.02
    /// Once scale is exactly 1, it stays there until the gesture leaves this wider band.
    public static let snapExitBand: CGFloat = 0.04

    public var center: CGPoint
    public var scale: CGFloat

    public init(center: CGPoint, scale: CGFloat) {
        self.center = center
        self.scale = Self.clamp(scale)
    }

    public static func clamp(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minScale), maxScale)
    }

    public static func snappedScale(from old: CGFloat, raw: CGFloat) -> CGFloat {
        if old == 1 {
            return abs(raw - 1) < snapExitBand ? 1 : raw
        }
        return abs(raw - 1) <= snapEnterBand ? 1 : raw
    }

    /// Canvas point at the top-left of the viewport.
    public func origin(viewport: CGSize) -> CGPoint {
        CGPoint(
            x: center.x - viewport.width / (2 * scale),
            y: center.y - viewport.height / (2 * scale)
        )
    }

    public func visibleCanvasRect(viewport: CGSize) -> CGRect {
        CGRect(
            origin: origin(viewport: viewport),
            size: CGSize(width: viewport.width / scale, height: viewport.height / scale)
        )
    }

    public func canvasPoint(fromScreen point: CGPoint, viewport: CGSize) -> CGPoint {
        let origin = origin(viewport: viewport)
        return CGPoint(x: origin.x + point.x / scale, y: origin.y + point.y / scale)
    }

    public func screenPoint(fromCanvas point: CGPoint, viewport: CGSize) -> CGPoint {
        let origin = origin(viewport: viewport)
        return CGPoint(x: (point.x - origin.x) * scale, y: (point.y - origin.y) * scale)
    }

    /// Zooms around a viewport point, keeping the canvas point under it fixed.
    /// Scale is clamped to `minScale...maxScale` and sticks to 1 when it passes nearby.
    public func zoomed(by factor: CGFloat, around screenPoint: CGPoint, viewport: CGSize) -> Camera {
        guard factor.isFinite, factor > 0, viewport.width > 0, viewport.height > 0 else { return self }
        let anchor = canvasPoint(fromScreen: screenPoint, viewport: viewport)
        let raw = Self.clamp(scale * factor)
        let next = Self.snappedScale(from: scale, raw: raw)
        return Camera(center: .zero, scale: next).placing(anchor: anchor, at: screenPoint, viewport: viewport)
    }

    /// Moves the view by screen points. Positive x reveals canvas to the left
    /// (content travels right), matching the scroll-wheel deltas used by the shell.
    public func panned(byScreen delta: CGPoint) -> Camera {
        guard delta.x.isFinite, delta.y.isFinite else { return self }
        return Camera(
            center: CGPoint(x: center.x - delta.x / scale, y: center.y - delta.y / scale),
            scale: scale
        )
    }

    /// Frames `content` in the viewport. `padding` is the fraction of the viewport the content may fill.
    public func fitted(to content: CGRect, viewport: CGSize, padding: CGFloat = 0.92) -> Camera {
        guard content.width > 0, content.height > 0, viewport.width > 0, viewport.height > 0, padding > 0 else {
            return self
        }
        let fitted = min(viewport.width / content.width, viewport.height / content.height) * padding
        return Camera(center: CGPoint(x: content.midX, y: content.midY), scale: min(fitted, Self.fitMaxScale))
    }

    private func placing(anchor: CGPoint, at screenPoint: CGPoint, viewport: CGSize) -> Camera {
        let origin = CGPoint(
            x: anchor.x - screenPoint.x / scale,
            y: anchor.y - screenPoint.y / scale
        )
        return Camera(
            center: CGPoint(
                x: origin.x + viewport.width / (2 * scale),
                y: origin.y + viewport.height / (2 * scale)
            ),
            scale: scale
        )
    }
}

extension Camera: Codable {
    private enum CodingKeys: String, CodingKey {
        case center
        case scale
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(center, forKey: .center)
        try container.encode(scale, forKey: .scale)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let center = try container.decode(CGPoint.self, forKey: .center)
        let scale = try container.decode(CGFloat.self, forKey: .scale)
        self.init(center: center, scale: scale)
    }
}
