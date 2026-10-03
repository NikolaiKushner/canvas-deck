import AppKit
import CanvasCore

/// Card content that wants keyboard focus while its card is active.
protocol NodeContentView: NSView {
    var preferredFirstResponder: NSView? { get }
}

/// Chrome around a node: title bar to drag, edges and corners to resize,
/// selection. The title bar follows the design (App design → Card Header v2):
/// kind icon, title, folder, agent state pill, account, ⋯ menu.
final class NodeContainerView: NSView {
    let nodeID: UUID
    var onActivate: (() -> Void)?
    var onClose: (() -> Void)?
    var onFrameChange: ((CGRect) -> Void)?
    /// The ⋯ button: the controller pops its menu up from it.
    var onMore: ((NSView) -> Void)?
    /// A click on the folder text, e.g. a browser's address to edit.
    var onFolderClick: (() -> Void)?
    static let titleHeight: CGFloat = 40
    static let cornerRadius: CGFloat = 14
    private let chrome = FlippedChrome()
    private let titleFill = NSView()
    private let iconChip = NSView()
    private let glyph = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let folderField = NSTextField(labelWithString: "")
    private let separator = NSView()
    private let statePill = StatePillView()
    /// The Claude Code account the card's session runs under, e.g. "work".
    private let badge = BadgeView()
    private let more = NSButton()
    /// Closes the card in one click; the ⋯ menu has the rest.
    private let closeButton = NSButton()
    /// A page's icon in the icon square (browser cards).
    private let icon = NSImageView()
    /// One action in the title bar, e.g. a Linear issue's menu.
    private let accessory = NSButton()
    private var accessoryAction: (() -> Void)?
    /// Small icon buttons in the title bar, e.g. back and reload for an app-like page.
    private var tools: [NSButton] = []
    private var toolActions: [() -> Void] = []
    /// Under the content: "Dev server on localhost:3000 [Open preview]".
    private let inlineBar = InlineActionBar()
    private let body: NSView
    /// Space between the card's edge and its content: a terminal's text
    /// sits off the edge as in the design, a web page fills the card.
    var contentInsets = NSEdgeInsets() {
        didSet { needsLayout = true }
    }
    private var interaction: Interaction?
    private(set) var isActive = false
    /// A state that wants the user (permission, a question, an error): a ring in its colour.
    private var attention: NSColor?
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
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -8)

        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = Self.cornerRadius
        chrome.layer?.cornerCurve = .continuous
        chrome.layer?.masksToBounds = true
        addSubview(chrome)

        titleFill.wantsLayer = true
        chrome.addSubview(titleFill)

        iconChip.wantsLayer = true
        iconChip.layer?.cornerRadius = 6
        chrome.addSubview(iconChip)
        glyph.contentTintColor = CanvasPalette.text
        chrome.addSubview(glyph)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.isHidden = true
        chrome.addSubview(icon)

        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = CanvasPalette.text
        titleField.lineBreakMode = .byTruncatingTail
        chrome.addSubview(titleField)
        folderField.font = .systemFont(ofSize: 12)
        folderField.textColor = CanvasPalette.secondaryText
        folderField.lineBreakMode = .byTruncatingMiddle
        chrome.addSubview(folderField)

        statePill.isHidden = true
        chrome.addSubview(statePill)
        badge.isHidden = true
        chrome.addSubview(badge)

        more.title = ""
        more.attributedTitle = NSAttributedString(string: "⋯", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: CanvasPalette.secondaryText,
        ])
        more.isBordered = false
        more.target = self
        more.action = #selector(showMore)
        more.toolTip = "Card actions"
        more.setAccessibilityLabel("Card actions")
        chrome.addSubview(more)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = CanvasPalette.secondaryText
        closeButton.target = self
        closeButton.action = #selector(closeCard)
        closeButton.toolTip = "Close card"
        chrome.addSubview(closeButton)

        accessory.bezelStyle = .rounded
        accessory.controlSize = .small
        accessory.font = .systemFont(ofSize: 11, weight: .medium)
        accessory.target = self
        accessory.action = #selector(runAccessory)
        accessory.isHidden = true
        chrome.addSubview(accessory)

        separator.wantsLayer = true
        chrome.addSubview(separator)
        chrome.addSubview(body)
        inlineBar.isHidden = true
        chrome.addSubview(inlineBar)

        applyColors()
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        withEffectiveAppearance {
            chrome.layer?.backgroundColor = CanvasPalette.card.cgColor
            titleFill.layer?.backgroundColor = CanvasPalette.card.cgColor
            iconChip.layer?.backgroundColor = CanvasPalette.chipStrong.cgColor
            separator.layer?.backgroundColor = CanvasPalette.line.cgColor
        }
        applyRing()
    }

    /// Focus wins over attention: blue for the card you are in, the state's
    /// colour with a glow for one that waits for you, a hairline otherwise.
    private func applyRing() {
        let dark = isDarkAppearance
        withEffectiveAppearance {
            if isActive {
                chrome.layer?.borderWidth = 2
                chrome.layer?.borderColor = CanvasPalette.accent.cgColor
                layer?.shadowColor = NSColor.black.cgColor
                layer?.shadowOpacity = (dark ? CanvasPalette.shadowOpacity.dark : CanvasPalette.shadowOpacity.light) * 1.6
                layer?.shadowRadius = 18
                layer?.shadowOffset = CGSize(width: 0, height: -14)
            } else if let attention {
                chrome.layer?.borderWidth = 2
                chrome.layer?.borderColor = attention.cgColor
                layer?.shadowColor = attention.cgColor
                layer?.shadowOpacity = 0.32
                layer?.shadowRadius = 12
                layer?.shadowOffset = .zero
            } else {
                chrome.layer?.borderWidth = 1
                chrome.layer?.borderColor = CanvasPalette.edge.cgColor
                layer?.shadowColor = NSColor.black.cgColor
                layer?.shadowOpacity = dark ? CanvasPalette.shadowOpacity.dark : CanvasPalette.shadowOpacity.light
                layer?.shadowRadius = 12
                layer?.shadowOffset = CGSize(width: 0, height: -8)
            }
        }
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        applyRing()
    }

    func setAttention(_ color: NSColor?) {
        guard attention != color else { return }
        attention = color
        applyRing()
    }

    /// The area under the title bar, in this view's coordinates.
    var bodyRect: CGRect {
        CGRect(x: 0, y: Self.titleHeight, width: bounds.width, height: max(0, bounds.height - Self.titleHeight))
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
        needsLayout = true
    }

    /// The kind's icon in the square, the same SF Symbol as in the dock:
    /// sparkles for Claude Code, terminal, globe. A page's own icon replaces it.
    func setSymbol(_ name: String) {
        glyph.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10.5, weight: .medium))
        needsLayout = true
    }

    /// Secondary text after the title: the folder, or a page's address.
    func setFolder(_ text: String?) {
        guard folderField.stringValue != (text ?? "") else { return }
        folderField.stringValue = text ?? ""
        needsLayout = true
    }

    /// Agent state as a tinted pill: "Working · 38s", "Needs permission". nil hides it.
    func setStatus(_ text: String?, color: NSColor?) {
        statePill.isHidden = text == nil
        statePill.set(text ?? "", color: color ?? CanvasPalette.secondaryText)
        setAccessibilityValue(text)
        needsLayout = true
    }

    func setIcon(_ image: NSImage?) {
        icon.image = image
        icon.isHidden = image == nil
        glyph.isHidden = image != nil
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
    @objc private func showMore() { onMore?(more) }
    @objc private func closeCard() { onClose?() }

    /// A one-line bar under the content with one button; nil removes it.
    func setInlineAction(_ text: String?, button: String = "", action: (() -> Void)? = nil) {
        inlineBar.isHidden = text == nil
        inlineBar.set(text: text ?? "", button: button, action: action)
        needsLayout = true
    }

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
                button.contentTintColor = CanvasPalette.secondaryText
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
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
        let h = Self.titleHeight
        titleFill.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)

        // Right to left: ×, ⋯, account, state, tools, accessory.
        var right = bounds.width - 8
        closeButton.frame = CGRect(x: right - 20, y: (h - 22) / 2, width: 20, height: 22)
        right -= 20 + 2
        more.frame = CGRect(x: right - 20, y: (h - 22) / 2, width: 20, height: 22)
        right -= 20 + 8
        if !badge.isHidden {
            let width = badge.fittingWidth
            badge.frame = CGRect(x: right - width, y: (h - BadgeView.height) / 2, width: width, height: BadgeView.height)
            right -= width + 8
        }
        if !statePill.isHidden {
            // Measured, never cut: the title and folder give way first.
            let width = min(statePill.fittingWidth, max(0, bounds.width - 140))
            statePill.frame = CGRect(x: right - width, y: (h - StatePillView.height) / 2, width: width, height: StatePillView.height)
            right -= width + 8
        }
        for button in tools.reversed() {
            button.frame = CGRect(x: right - 22, y: (h - 20) / 2, width: 22, height: 20)
            right -= 26
        }
        if !tools.isEmpty { right -= 4 }
        if !accessory.isHidden {
            accessory.sizeToFit()
            let width = accessory.frame.width + 4
            accessory.frame = CGRect(x: right - width, y: (h - 22) / 2, width: width, height: 22)
            right -= width + 8
        }

        // Left to right: icon, title, folder.
        iconChip.frame = CGRect(x: 12, y: (h - 20) / 2, width: 20, height: 20)
        icon.frame = iconChip.frame.insetBy(dx: 2, dy: 2)
        glyph.frame = iconChip.frame.insetBy(dx: 3, dy: 3)
        let left = iconChip.frame.maxX + 8
        let space = max(0, right - left)
        let titleWidth = min(Self.textWidth(titleField) + 4, space)
        let titleHeight = titleField.intrinsicContentSize.height
        titleField.frame = CGRect(x: left, y: (h - titleHeight) / 2, width: titleWidth, height: titleHeight)
        let folderX = titleField.frame.maxX + 6
        let folderWidth = max(0, right - folderX)
        folderField.isHidden = folderField.stringValue.isEmpty || folderWidth < 40
        let folderHeight = folderField.intrinsicContentSize.height
        folderField.frame = CGRect(x: folderX, y: (h - folderHeight) / 2, width: min(folderWidth, Self.textWidth(folderField) + 4), height: folderHeight)

        separator.frame = CGRect(x: 0, y: h - 1, width: bounds.width, height: 1)
        var content = CGRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
        if !inlineBar.isHidden {
            let barHeight = InlineActionBar.height
            let strip = barHeight + 24
            content.size.height = max(0, content.height - strip)
            let width = min(inlineBar.fittingWidth, bounds.width - 32)
            inlineBar.frame = CGRect(x: 16, y: content.maxY + 12, width: width, height: barHeight)
        }
        body.frame = CGRect(
            x: content.minX + contentInsets.left,
            y: content.minY + contentInsets.top,
            width: max(0, content.width - contentInsets.left - contentInsets.right),
            height: max(0, content.height - contentInsets.top - contentInsets.bottom)
        )
    }

    /// A label's text width from its string: a field's intrinsic width
    /// follows its last frame, which cut short titles.
    private static func textWidth(_ field: NSTextField) -> CGFloat {
        ceil((field.stringValue as NSString).size(withAttributes: [.font: field.font as Any]).width)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let outer = resizeBand.outer
        guard bounds.insetBy(dx: -outer, dy: -outer).contains(local) else { return nil }
        if resizeEdge(at: local) != nil {
            return self
        }
        let inChrome = chrome.convert(point, from: superview)
        if local.y < Self.titleHeight {
            // The title bar drags the card, except its buttons.
            if !accessory.isHidden, accessory.frame.contains(inChrome) { return accessory }
            if let tool = tools.first(where: { $0.frame.contains(inChrome) }) { return tool }
            if more.frame.contains(inChrome) { return more }
            if closeButton.frame.contains(inChrome) { return closeButton }
            return self
        }
        if !inlineBar.isHidden, let hit = inlineBar.hitTest(inChrome) { return hit }
        // hitTest takes a point in the receiver's superview: `chrome`, not
        // `body` itself. Passing body coordinates shifted every hit by the
        // title bar's height — a browser's toolbar took no clicks.
        if let hit = body.hitTest(chrome.convert(point, from: superview)) { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        let local = convert(event.locationInWindow, from: nil)
        if onFolderClick != nil, !folderField.isHidden, folderField.frame.insetBy(dx: -2, dy: -4).contains(local), event.clickCount == 1 {
            onFolderClick?()
            return
        }
        let canvas = canvasPoint(of: event)
        if let edge = resizeEdge(at: local) {
            interaction = .resize(edge: edge, start: frame, anchor: canvas)
            return
        }
        if local.y < Self.titleHeight {
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

/// The account label on a card, e.g. "work": a rounded square of the chip
/// colour. An `NSTextField` sized to it draws its text from the top, hence
/// the own layout.
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

    var fittingWidth: CGFloat { ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font as Any]).width) + 16 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = CanvasPalette.secondaryText
        label.alignment = .center
        addSubview(label)
        applyColors()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        withEffectiveAppearance { layer?.backgroundColor = CanvasPalette.chip.cgColor }
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: 0, y: ((bounds.height - size.height) / 2).rounded(), width: bounds.width, height: size.height)
    }
}

/// "● Working · 38s": the agent's state, tinted in its colour.
final class StatePillView: NSView {
    static let height: CGFloat = 20
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private var color: NSColor = CanvasPalette.secondaryText

    var fittingWidth: CGFloat {
        8 + 7 + 6 + ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font as Any]).width) + 2 + 9
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        addSubview(dot)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func set(_ text: String, color: NSColor) {
        label.stringValue = text
        self.color = color
        applyColors()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        let dark = isDarkAppearance
        withEffectiveAppearance {
            layer?.backgroundColor = color.withAlphaComponent(dark ? 0.18 : 0.12).cgColor
            dot.layer?.backgroundColor = color.cgColor
        }
        // Yellow text is unreadable on white: a dark yellow in the light theme.
        label.textColor = !dark && color == CanvasPalette.question ? NSColor(hex: 0x8A6D00) : color
    }

    override func layout() {
        super.layout()
        dot.frame = CGRect(x: 8, y: (bounds.height - 7) / 2, width: 7, height: 7)
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: 21, y: (bounds.height - size.height) / 2, width: max(0, bounds.width - 21 - 7), height: size.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// "Dev server on localhost:3000 [Open preview]" under a terminal's output.
final class InlineActionBar: NSView {
    static let height: CGFloat = 32
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton()
    private var action: (() -> Void)?

    var fittingWidth: CGFloat { 10 + ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font as Any]).width) + 4 + 8 + buttonWidth + 6 }
    private var buttonWidth: CGFloat { ceil(button.attributedTitle.size().width) + 20 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = CanvasPalette.text
        label.lineBreakMode = .byTruncatingTail
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = CanvasPalette.accent.cgColor
        button.target = self
        button.action = #selector(run)
        addSubview(label)
        addSubview(button)
        applyColors()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func set(text: String, button title: String, action: (() -> Void)?) {
        label.stringValue = text
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        self.action = action
        needsLayout = true
    }

    @objc private func run() { action?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        let dark = isDarkAppearance
        layer?.backgroundColor = CanvasPalette.accent.withAlphaComponent(dark ? 0.18 : 0.08).cgColor
    }

    override func layout() {
        super.layout()
        let width = buttonWidth
        button.frame = CGRect(x: bounds.width - 6 - width, y: (bounds.height - 22) / 2, width: width, height: 22)
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: 10, y: (bounds.height - size.height) / 2, width: max(0, button.frame.minX - 18), height: size.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return button.frame.contains(local) ? button : (bounds.contains(local) ? self : nil)
    }
}
