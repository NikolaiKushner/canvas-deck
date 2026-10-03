import AppKit

/// The floating dock at the left of the canvas (App design → Tool dock):
/// new Claude Code, terminal, browser, Linear, then Fit All.
final class ToolDockView: NSView {
    struct Tool {
        /// An SF Symbol, the same one the card of this kind shows.
        var symbol: String
        /// Under the icon, so the dock reads without hovering.
        var title: String
        var help: String
        var primary = false
        var action: () -> Void
    }

    private var buttons: [DockButton] = []
    private let separator = NSView()
    /// Index of the first tool after the separator.
    private let splitAt: Int
    static let buttonSize = CGSize(width: 58, height: 52)
    static let padding: CGFloat = 6
    static let gap: CGFloat = 4

    init(tools: [Tool], separatorBefore: Int) {
        splitAt = separatorBefore
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        buttons = tools.map { DockButton(tool: $0) }
        buttons.forEach(addSubview)
        separator.wantsLayer = true
        addSubview(separator)
        applyColors()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    var dockSize: NSSize {
        let count = CGFloat(buttons.count)
        let height = Self.padding * 2 + count * Self.buttonSize.height + (count - 1) * Self.gap + 1 + Self.gap
        return NSSize(width: Self.buttonSize.width + Self.padding * 2, height: height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        let dark = isDarkAppearance
        withEffectiveAppearance {
            layer?.backgroundColor = CanvasPalette.card.cgColor
            layer?.borderColor = CanvasPalette.edge.cgColor
            separator.layer?.backgroundColor = CanvasPalette.chipStrong.cgColor
        }
        layer?.shadowOpacity = dark ? CanvasPalette.shadowOpacity.dark : CanvasPalette.shadowOpacity.light
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 14, cornerHeight: 14, transform: nil)
        var y = Self.padding
        for (index, button) in buttons.enumerated() {
            if index == splitAt {
                separator.frame = CGRect(x: (bounds.width - 24) / 2, y: y, width: 24, height: 1)
                y += 1 + Self.gap
            }
            button.frame = CGRect(x: Self.padding, y: y, width: Self.buttonSize.width, height: Self.buttonSize.height)
            y += Self.buttonSize.height + Self.gap
        }
    }
}

private final class DockButton: NSView {
    private let tool: ToolDockView.Tool
    private let image = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hovering = false { didSet { applyColors() } }
    private var pressed = false { didSet { applyColors() } }

    init(tool: ToolDockView.Tool) {
        self.tool = tool
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        image.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        image.contentTintColor = tool.primary ? .white : CanvasPalette.text
        addSubview(image)
        label.stringValue = tool.title
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.alignment = .center
        label.textColor = tool.primary ? NSColor.white.withAlphaComponent(0.9) : CanvasPalette.secondaryText
        addSubview(label)
        toolTip = tool.help
        setAccessibilityRole(.button)
        setAccessibilityLabel(tool.help)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        applyColors()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        withEffectiveAppearance {
            if tool.primary {
                layer?.backgroundColor = CanvasPalette.accent.blended(withFraction: pressed ? 0.2 : hovering ? 0.08 : 0, of: .black)?.cgColor
            } else {
                layer?.backgroundColor = pressed ? CanvasPalette.chipStrong.cgColor : hovering ? CanvasPalette.chip.cgColor : NSColor.clear.cgColor
            }
        }
    }

    override func layout() {
        super.layout()
        image.frame = CGRect(x: (bounds.width - 22) / 2, y: 8, width: 22, height: 20)
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: 0, y: bounds.height - 8 - size.height, width: bounds.width, height: size.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { tool.action() }
    }
    override func accessibilityPerformPress() -> Bool { tool.action(); return true }
}
