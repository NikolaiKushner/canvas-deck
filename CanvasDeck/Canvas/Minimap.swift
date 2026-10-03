import AppKit

/// Overview of every node and the visible rect. Click or drag to recenter the camera.
final class MinimapView: NSView {
    var nodes: [CGRect] = [] {
        didSet { if nodes != oldValue { needsDisplay = true } }
    }
    var viewport: CGRect = .zero {
        didSet { if viewport != oldValue { needsDisplay = true } }
    }

    /// Set while the map itself is dragged: refitting under the pointer made
    /// the drag chase its own position. Otherwise the map refits on every step.
    private var dragWorld: CGRect?
    var onCenter: ((CGPoint) -> Void)?

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Layer-backed flipped views otherwise draw y-up, so the dots land
        // opposite the windows on screen.
        layer?.isGeometryFlipped = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let map = mapping()
        let nodeColor = NSColor.controlAccentColor.withAlphaComponent(0.35)
        nodeColor.setFill()
        for frame in nodes {
            NSBezierPath(roundedRect: viewRect(frame, map: map), xRadius: 2, yRadius: 2).fill()
        }
        NSColor.controlAccentColor.setStroke()
        var frame = viewRect(viewport, map: map)
        if !bounds.insetBy(dx: 2, dy: 2).intersects(frame) {
            // Out past the edge until the map refits: a stub on the edge
            // shows the direction.
            let x = min(max(frame.midX, 3), bounds.width - 3)
            let y = min(max(frame.midY, 3), bounds.height - 3)
            frame = CGRect(x: x - 5, y: y - 5, width: 10, height: 10)
        }
        let outline = NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1.5
        outline.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        dragWorld = targetWorld()
        recenter(event)
    }
    override func mouseDragged(with event: NSEvent) { recenter(event) }
    override func mouseUp(with event: NSEvent) {
        dragWorld = nil
        needsDisplay = true
    }

    private func recenter(_ event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let map = mapping()
        guard map.scale > 0 else { return }
        let canvas = CGPoint(
            x: map.world.minX + (local.x - map.offset.x) / map.scale,
            y: map.world.minY + (local.y - map.offset.y) / map.scale
        )
        onCenter?(canvas)
    }

    private struct Map {
        var world: CGRect
        var scale: CGFloat
        var offset: CGPoint
    }

    /// Every card and the view, with a margin.
    private func targetWorld() -> CGRect {
        var world = viewport.isEmpty ? CGRect(x: -400, y: -300, width: 800, height: 600) : viewport
        for frame in nodes {
            world = world.union(frame)
        }
        return world.insetBy(dx: -max(world.width, 1) * 0.08, dy: -max(world.height, 1) * 0.08)
    }

    private func mapping() -> Map {
        let world = dragWorld ?? targetWorld()
        let scale = min(bounds.width / max(world.width, 1), bounds.height / max(world.height, 1))
        let used = CGSize(width: world.width * scale, height: world.height * scale)
        let offset = CGPoint(x: (bounds.width - used.width) / 2, y: (bounds.height - used.height) / 2)
        return Map(world: world, scale: scale, offset: offset)
    }

    private func viewRect(_ canvas: CGRect, map: Map) -> CGRect {
        CGRect(
            x: map.offset.x + (canvas.minX - map.world.minX) * map.scale,
            y: map.offset.y + (canvas.minY - map.world.minY) * map.scale,
            width: canvas.width * map.scale,
            height: canvas.height * map.scale
        )
    }
}
