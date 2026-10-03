import AppKit

/// Overview of every node and the visible rect. Click or drag to recenter the camera.
final class MinimapView: NSView {
    var nodes: [CGRect] = [] {
        didSet { if nodes != oldValue { needsDisplay = true } }
    }
    /// The agent state colour of each node, parallel to `nodes`; nil is grey.
    var colors: [NSColor?] = [] {
        didSet { if colors != oldValue { needsDisplay = true } }
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
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let map = mapping()
        let grey = isDarkAppearance ? NSColor(hex: 0x5A6170).withAlphaComponent(0.6) : NSColor(hex: 0xB8BDC7).withAlphaComponent(0.6)
        for (index, frame) in nodes.enumerated() {
            let color = colors.indices.contains(index) ? colors[index] : nil
            (color?.withAlphaComponent(0.7) ?? grey).setFill()
            NSBezierPath(roundedRect: viewRect(frame, map: map), xRadius: 3, yRadius: 3).fill()
        }
        var frame = viewRect(viewport, map: map)
        if !bounds.insetBy(dx: 2, dy: 2).intersects(frame) {
            // Out past the edge until the map refits: a stub on the edge
            // shows the direction.
            let x = min(max(frame.midX, 3), bounds.width - 3)
            let y = min(max(frame.midY, 3), bounds.height - 3)
            frame = CGRect(x: x - 5, y: y - 5, width: 10, height: 10)
        }
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5)
        CanvasPalette.accent.withAlphaComponent(0.06).setFill()
        outline.fill()
        CanvasPalette.accent.withAlphaComponent(0.8).setStroke()
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

/// Minimap and zoom in one panel, bottom right (App design → Navigator):
/// the map, then "−  100%  +  ⤢".
final class NavigatorView: NSView {
    let minimap = MinimapView(frame: .zero)
    var onZoomOut: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onFit: (() -> Void)?
    /// A click on the percentage: the zoom menu opens from it.
    var onZoomMenu: ((NSView) -> Void)?
    var scale: CGFloat = 1 {
        didSet {
            let text = ZoomMenu.percentText(scale)
            guard percent.title != text else { return }
            percent.title = text
            needsLayout = true
        }
    }

    static let size = CGSize(width: 200, height: 120 + rowHeight)
    static let rowHeight: CGFloat = 30
    private let row = NSView()
    private let rule = NSView()
    private let minus = NSButton()
    private let percent = NSButton()
    private let plus = NSButton()
    private let fit = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        addSubview(minimap)
        rule.wantsLayer = true
        addSubview(rule)
        for (button, title, help, size, weight, action) in [
            (minus, "−", "Zoom Out  ⌘−", CGFloat(14), NSFont.Weight.medium, #selector(zoomOut)),
            (percent, "100%", "Zoom", 12, .semibold, #selector(zoomMenu)),
            (plus, "+", "Zoom In  ⌘=", 14, .medium, #selector(zoomIn)),
            (fit, "⤢", "Fit All  ⇧1", 13, .medium, #selector(fitAll)),
        ] as [(NSButton, String, String, CGFloat, NSFont.Weight, Selector)] {
            button.isBordered = false
            button.font = .systemFont(ofSize: size, weight: weight)
            button.title = title
            button.toolTip = help
            button.target = self
            button.action = action
            button.contentTintColor = button === percent ? CanvasPalette.text : CanvasPalette.secondaryText
            addSubview(button)
        }
        percent.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        applyColors()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        let dark = isDarkAppearance
        withEffectiveAppearance {
            layer?.backgroundColor = CanvasPalette.card.cgColor
            layer?.borderColor = CanvasPalette.edge.cgColor
            rule.layer?.backgroundColor = CanvasPalette.line.cgColor
        }
        layer?.shadowOpacity = dark ? CanvasPalette.shadowOpacity.dark : CanvasPalette.shadowOpacity.light
        for button in [minus, plus, fit] { button.attributedTitle = tinted(button.title, button.font, CanvasPalette.secondaryText) }
        percent.attributedTitle = tinted(percent.title, percent.font, CanvasPalette.text)
    }

    private func tinted(_ title: String, _ font: NSFont?, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: font as Any, .foregroundColor: color])
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        let rowY = bounds.height - Self.rowHeight
        minimap.frame = CGRect(x: 0, y: 0, width: bounds.width, height: rowY)
        rule.frame = CGRect(x: 0, y: rowY, width: bounds.width, height: 1)
        minus.frame = CGRect(x: 6, y: rowY + 4, width: 24, height: 22)
        fit.frame = CGRect(x: bounds.width - 30, y: rowY + 4, width: 24, height: 22)
        plus.frame = CGRect(x: fit.frame.minX - 26, y: rowY + 4, width: 24, height: 22)
        percent.frame = CGRect(x: minus.frame.maxX + 4, y: rowY + 4, width: plus.frame.minX - minus.frame.maxX - 8, height: 22)
        percent.attributedTitle = tinted(percent.title, percent.font, CanvasPalette.text)
    }

    @objc private func zoomOut() { onZoomOut?() }
    @objc private func zoomIn() { onZoomIn?() }
    @objc private func fitAll() { onFit?() }
    @objc private func zoomMenu() { onZoomMenu?(percent) }
}
