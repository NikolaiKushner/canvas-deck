import AppKit
import CanvasCore

/// Card content that wants keyboard focus while its card is active.
protocol NodeContentView: NSView {
    var preferredFirstResponder: NSView? { get }
}

/// Chrome around a node: title bar to drag, edges and corners to resize, close, selection.
final class NodeContainerView: NSView {
    let nodeID: UUID
    var onActivate: (() -> Void)?
    var onClose: (() -> Void)?
    var onFrameChange: ((CGRect) -> Void)?
    static let titleHeight: CGFloat = 36
    private let chrome = FlippedChrome()
    private let titleFill = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let separator = NSView()
    private let closeMark = CloseMark()
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    /// The Claude Code account the card's session runs under, e.g. "work".
    private let badge = BadgeView()
    /// A page's icon before the title (browser cards).
    private let icon = NSImageView()
    /// One action in the title bar, e.g. "Open Preview" on a terminal.
    private let accessory = NSButton()
    private var accessoryAction: (() -> Void)?
    /// Small icon buttons in the title bar, e.g. back and reload for an app-like page.
    private var tools: [NSButton] = []
    private var toolActions: [() -> Void] = []
    private let body: NSView
    private var interaction: Interaction?
    private(set) var isActive = false
    static let minSize = CGSize(width: 320, height: 200)

    private struct ResizeEdge: OptionSet {
        let rawValue: Int
        static let north = ResizeEdge(rawValue: 1 << 0)
        static let south = ResizeEdge(rawValue: 1 << 1)
        static let west = ResizeEdge(rawValue: 1 << 2)
        static let east = ResizeEdge(rawValue: 1 << 3)
    }

    private enum Interaction {
        case drag(anchor: CGPoint, origin: CGPoint)
        case resize(edge: ResizeEdge, start: CGRect, anchor: CGPoint)
    }

    /// A card with a placeholder body: legacy kinds and external windows.
    convenience init(nodeID: UUID, title: String, symbol: String, message: String, frame: CGRect) {
        self.init(nodeID: nodeID, title: title, content: PlaceholderContentView(symbol: symbol, message: message), frame: frame)
    }

    /// A card around real content, e.g. `TerminalNode`.
    init(nodeID: UUID, title: String, content: NSView, frame: CGRect) {
        self.nodeID = nodeID
        body = content
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        chrome.wantsLayer = true
        chrome.layer?.backgroundColor = CanvasPalette.card.cgColor
        chrome.layer?.cornerRadius = 12
        chrome.layer?.masksToBounds = true
        chrome.layer?.borderWidth = 1
        chrome.layer?.borderColor = NSColor.black.withAlphaComponent(0.1).cgColor
        addSubview(chrome)

        titleFill.wantsLayer = true
        titleFill.layer?.backgroundColor = CanvasPalette.titleBar.cgColor
        chrome.addSubview(titleFill)

        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.drawsBackground = false
        titleField.isBezeled = false
        titleField.isEditable = false
        titleField.isSelectable = false
        chrome.addSubview(titleField)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.isHidden = true
        chrome.addSubview(statusDot)
        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.isHidden = true
        chrome.addSubview(statusLabel)

        badge.isHidden = true
        chrome.addSubview(badge)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.isHidden = true
        chrome.addSubview(icon)
        accessory.bezelStyle = .rounded
        accessory.controlSize = .small
        accessory.font = .systemFont(ofSize: 11, weight: .medium)
        accessory.target = self
        accessory.action = #selector(runAccessory)
        accessory.isHidden = true
        chrome.addSubview(accessory)

        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
        chrome.addSubview(separator)
        chrome.addSubview(body)
        chrome.addSubview(closeMark)

        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        chrome.layer?.borderWidth = active ? 2 : 1
        chrome.layer?.borderColor = (active ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.1)).cgColor
    }

    /// The area under the title bar, in this view's coordinates.
    var bodyRect: CGRect {
        CGRect(x: 0, y: 36, width: bounds.width, height: max(0, bounds.height - 36))
    }

    func setMessage(_ message: String) {
        (body as? PlaceholderContentView)?.message = message
    }

    /// Where keyboard input goes when this card is active: the content's own
    /// responder if it has one, otherwise the card.
    var preferredFirstResponder: NSView {
        (body as? NodeContentView)?.preferredFirstResponder ?? self
    }

    func setTitle(_ title: String) {
        titleField.stringValue = title
        setAccessibilityLabel(title)
    }

    /// Agent state at the right of the title bar: a dot and a short label.
    /// nil hides it.
    func setStatus(_ text: String?, color: NSColor?) {
        let visible = text != nil
        statusDot.isHidden = !visible
        statusLabel.isHidden = !visible
        statusLabel.stringValue = text ?? ""
        statusLabel.textColor = color ?? .secondaryLabelColor
        statusDot.layer?.backgroundColor = (color ?? .secondaryLabelColor).cgColor
        setAccessibilityValue(text)
        needsLayout = true
    }

    func setIcon(_ image: NSImage?) {
        icon.image = image
        icon.isHidden = image == nil
        needsLayout = true
    }

    func setAccessory(_ title: String?, help: String? = nil, action: (() -> Void)?) {
        accessory.isHidden = title == nil
        accessory.title = title ?? ""
        accessory.toolTip = help
        accessoryAction = action
        needsLayout = true
    }

    @objc private func runAccessory() { accessoryAction?() }

    struct Tool {
        var symbol: String
        var help: String
        var enabled = true
        var action: () -> Void
    }

    func setTools(_ list: [Tool]) {
        if tools.count != list.count {
            tools.forEach { $0.removeFromSuperview() }
            tools = list.indices.map { index in
                let button = NSButton()
                button.isBordered = false
                button.imagePosition = .imageOnly
                button.contentTintColor = .secondaryLabelColor
                button.target = self
                button.action = #selector(runTool(_:))
                button.tag = index
                chrome.addSubview(button)
                return button
            }
        }
        for (button, tool) in zip(tools, list) {
            button.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.help)
            button.toolTip = tool.help
            button.isEnabled = tool.enabled
        }
        toolActions = list.map(\.action)
        needsLayout = true
    }

    @objc private func runTool(_ sender: NSButton) {
        guard toolActions.indices.contains(sender.tag) else { return }
        toolActions[sender.tag]()
    }

    func setBadge(_ text: String?, help: String? = nil) {
        badge.isHidden = text == nil
        badge.text = text ?? ""
        badge.toolTip = help
        needsLayout = true
    }

    override func layout() {
        super.layout()
        chrome.frame = bounds
        // Without a path Core Animation derives the shadow from the layer's
        // alpha on every change, including each zoom step.
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        let titleHeight = Self.titleHeight
        titleFill.frame = CGRect(x: 0, y: 0, width: bounds.width, height: titleHeight)
        closeMark.frame = CGRect(x: bounds.width - 30, y: 9, width: 18, height: 18)
        var titleRight = bounds.width - 38
        if !statusLabel.isHidden {
            // The field insets its text by 2 pt a side; measure the string and
            // add that back, so the status is never cut. The title gives way first.
            let textWidth = ceil((statusLabel.stringValue as NSString).size(withAttributes: [.font: statusLabel.font as Any]).width) + 6
            let labelWidth = min(textWidth, max(0, bounds.width - 120))
            let labelX = bounds.width - 40 - labelWidth
            statusLabel.frame = CGRect(x: labelX, y: 9, width: labelWidth, height: 18)
            statusDot.frame = CGRect(x: labelX - 14, y: 14, width: 8, height: 8)
            titleRight = labelX - 22
        }
        if !badge.isHidden {
            // Measured like the status: the badge is never cut, the title gives way.
            let width = badge.fittingWidth
            badge.frame = CGRect(x: titleRight - width, y: (Self.titleHeight - BadgeView.height) / 2, width: width, height: BadgeView.height)
            titleRight -= width + 8
        }
        for button in tools.reversed() {
            button.frame = CGRect(x: titleRight - 22, y: (Self.titleHeight - 20) / 2, width: 22, height: 20)
            titleRight -= 26
        }
        if !tools.isEmpty { titleRight -= 4 }
        if !accessory.isHidden {
            accessory.sizeToFit()
            let width = accessory.frame.width + 4
            accessory.frame = CGRect(x: titleRight - width, y: (Self.titleHeight - 22) / 2, width: width, height: 22)
            titleRight -= width + 8
        }
        var titleLeft: CGFloat = 14
        if !icon.isHidden {
            icon.frame = CGRect(x: 14, y: (Self.titleHeight - 16) / 2, width: 16, height: 16)
            titleLeft = 36
        }
        titleField.frame = CGRect(x: titleLeft, y: 8, width: max(0, titleRight - titleLeft), height: 20)
        separator.frame = CGRect(x: 0, y: titleHeight - 1, width: bounds.width, height: 1)
        body.frame = CGRect(x: 0, y: titleHeight, width: bounds.width, height: max(0, bounds.height - titleHeight))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let outer = resizeBand.outer
        guard bounds.insetBy(dx: -outer, dy: -outer).contains(local) else { return nil }
        if resizeEdge(at: local) != nil {
            return self
        }
        if local.y < Self.titleHeight {
            // The title bar drags the card, except its one action button.
            let inChrome = chrome.convert(point, from: superview)
            if !accessory.isHidden, accessory.frame.contains(inChrome) { return accessory }
            if let tool = tools.first(where: { $0.frame.contains(inChrome) }) { return tool }
            return self
        }
        // hitTest takes a point in the receiver's superview: `chrome`, not
        // `body` itself. Passing body coordinates shifted every hit by the
        // title bar's height — a browser's toolbar took no clicks.
        if let hit = body.hitTest(chrome.convert(point, from: superview)) { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        let local = convert(event.locationInWindow, from: nil)
        if closeHitRect.contains(local) {
            onClose?()
            return
        }
        let canvas = canvasPoint(of: event)
        if let edge = resizeEdge(at: local) {
            interaction = .resize(edge: edge, start: frame, anchor: canvas)
            return
        }
        if local.y < 36 {
            interaction = .drag(anchor: canvas, origin: frame.origin)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let interaction else { return }
        let canvas = canvasPoint(of: event)
        switch interaction {
        case .drag(let anchor, let origin):
            frame = CGRect(
                x: origin.x + canvas.x - anchor.x,
                y: origin.y + canvas.y - anchor.y,
                width: frame.width,
                height: frame.height
            )
        case .resize(let edge, let start, let anchor):
            frame = resized(start, edge: edge, dx: canvas.x - anchor.x, dy: canvas.y - anchor.y)
        }
        onFrameChange?(frame)
    }

    override func mouseUp(with event: NSEvent) {
        interaction = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        onActivate?()
    }

    /// Cursor for a point in this view's coordinates, matching a standard macOS
    /// window: resize arrows on edges and corners, the arrow elsewhere. Driven
    /// by mouse-moved events rather than cursor rects, because the resize band
    /// extends outside the view and cursor rects are clipped to it.
    func cursor(at local: CGPoint) -> NSCursor {
        guard let edge = resizeEdge(at: local) else { return .arrow }
        let position: NSCursor.FrameResizePosition
        switch (edge.contains(.north), edge.contains(.south), edge.contains(.west), edge.contains(.east)) {
        case (true, _, true, _): position = .topLeft
        case (true, _, _, true): position = .topRight
        case (_, true, true, _): position = .bottomLeft
        case (_, true, _, true): position = .bottomRight
        case (true, _, _, _): position = .top
        case (_, true, _, _): position = .bottom
        case (_, _, true, _): position = .left
        default: position = .right
        }
        return .frameResize(position: position, directions: resizeDirections(for: edge))
    }

    /// At the minimum size a standard window shows an outward-only arrow.
    private func resizeDirections(for edge: ResizeEdge) -> NSCursor.FrameResizeDirection.Set {
        let horizontal = edge.contains(.west) || edge.contains(.east)
        let vertical = edge.contains(.north) || edge.contains(.south)
        let atMinWidth = !horizontal || bounds.width <= Self.minSize.width + 0.5
        let atMinHeight = !vertical || bounds.height <= Self.minSize.height + 0.5
        return atMinWidth && atMinHeight ? .outward : .all
    }

    /// Taller than the drawn cross so it is easy to hit when zoomed out.
    private var closeHitRect: CGRect {
        CGRect(x: bounds.width - 36, y: 3, width: 30, height: 30)
    }

    /// Resize band in canvas points, sized in screen points so it stays grabbable
    /// at any zoom. It lies mostly outside the card: when zoomed out the title
    /// bar is only a few screen points tall and must stay a drag handle.
    private var resizeBand: (outer: CGFloat, inner: CGFloat) {
        let scale = max(enclosingScrollView?.magnification ?? 1, Camera.minScale)
        return (outer: 6 / scale, inner: min(3 / scale, 8))
    }

    private func resizeEdge(at local: CGPoint) -> ResizeEdge? {
        let (outer, inner) = resizeBand
        guard bounds.insetBy(dx: -outer, dy: -outer).contains(local) else { return nil }
        var edge = ResizeEdge()
        if local.y <= inner { edge.insert(.north) }
        if local.y >= bounds.height - inner { edge.insert(.south) }
        if local.x <= inner { edge.insert(.west) }
        if local.x >= bounds.width - inner { edge.insert(.east) }
        return edge.isEmpty ? nil : edge
    }

    private func canvasPoint(of event: NSEvent) -> CGPoint {
        superview?.convert(event.locationInWindow, from: nil) ?? .zero
    }

    private func resized(_ start: CGRect, edge: ResizeEdge, dx: CGFloat, dy: CGFloat) -> CGRect {
        var rect = start
        let minWidth = Self.minSize.width
        let minHeight = Self.minSize.height
        if edge.contains(.west) {
            let width = max(minWidth, start.width - dx)
            rect.origin.x = start.maxX - width
            rect.size.width = width
        }
        if edge.contains(.east) {
            rect.size.width = max(minWidth, start.width + dx)
        }
        if edge.contains(.north) {
            let height = max(minHeight, start.height - dy)
            rect.origin.y = start.maxY - height
            rect.size.height = height
        }
        if edge.contains(.south) {
            rect.size.height = max(minHeight, start.height + dy)
        }
        return rect
    }
}

private final class FlippedChrome: NSView {
    override var isFlipped: Bool { true }
}

private final class CloseMark: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.85).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        let inset: CGFloat = 4
        path.move(to: CGPoint(x: inset, y: inset))
        path.line(to: CGPoint(x: bounds.width - inset, y: bounds.height - inset))
        path.move(to: CGPoint(x: bounds.width - inset, y: inset))
        path.line(to: CGPoint(x: inset, y: bounds.height - inset))
        path.stroke()
    }
}

private final class PlaceholderContentView: NSView {
    let symbol: String
    var message: String {
        didSet { needsDisplay = true }
    }

    init(symbol: String, message: String) {
        self.symbol = symbol
        self.message = message
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .light)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let side: CGFloat = 28
            let rect = CGRect(x: (bounds.width - side) / 2, y: bounds.midY - 40, width: side, height: side)
            NSColor.secondaryLabelColor.withAlphaComponent(0.8).set()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.85, respectFlipped: true, hints: nil)
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]
        let text = message as NSString
        let size = text.boundingRect(
            with: CGSize(width: max(0, bounds.width - 32), height: 80),
            options: [.usesLineFragmentOrigin],
            attributes: attributes
        ).size
        text.draw(
            in: CGRect(x: 16, y: bounds.midY + 2, width: max(0, bounds.width - 32), height: size.height),
            withAttributes: attributes
        )
    }
}

/// A small capsule with centred text, e.g. the Claude Code account on a card.
/// An `NSTextField` sized to the capsule draws its text from the top.
final class BadgeView: NSView {
    static let height: CGFloat = 18
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            needsLayout = true
        }
    }

    var fittingWidth: CGFloat { ceil(label.intrinsicContentSize.width) + 16 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(0.14).cgColor
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: 0, y: ((bounds.height - size.height) / 2).rounded(), width: bounds.width, height: size.height)
    }
}
