import AppKit
import CanvasCore

/// The toasts, top-right in the window over the canvas, in screen points like
/// the minimap. Only toasts take the mouse; the canvas around them stays live.
final class NoticeStackView: NSView {
    static let width: CGFloat = 320
    static let margin: CGFloat = 12
    static let gap: CGFloat = 8

    var onAction: ((UUID, Notice.Action) -> Void)?
    var onDismiss: ((UUID) -> Void)?
    var onHold: ((UUID, Bool) -> Void)?

    private var toasts: [UUID: ToastView] = [:]
    private let more = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        more.font = .systemFont(ofSize: 12, weight: .semibold)
        more.textColor = .secondaryLabelColor
        more.alignment = .center
        more.wantsLayer = true
        more.isHidden = true
        addSubview(more)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ notices: [Notice], more hidden: Int) {
        let ids = Set(notices.map(\.id))
        for (id, toast) in toasts where !ids.contains(id) {
            toasts[id] = nil
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                toast.animator().alphaValue = 0
            }, completionHandler: { toast.removeFromSuperview() })
        }
        var y = Self.margin
        let x = bounds.width - Self.width - Self.margin
        for notice in notices {
            let height = ToastView.height(for: notice)
            let frame = CGRect(x: x, y: y, width: Self.width, height: height)
            if let toast = toasts[notice.id] {
                toast.update(notice)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    toast.animator().frame = frame
                }
            } else {
                let toast = ToastView(notice: notice)
                toast.onAction = { [weak self] action in self?.onAction?(notice.id, action) }
                toast.onDismiss = { [weak self] in self?.onDismiss?(notice.id) }
                toast.onHold = { [weak self] holding in self?.onHold?(notice.id, holding) }
                toast.frame = frame.offsetBy(dx: 24, dy: 0)
                toast.alphaValue = 0
                addSubview(toast)
                toasts[notice.id] = toast
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    toast.animator().frame = frame
                    toast.animator().alphaValue = 1
                }
            }
            y += height + Self.gap
        }
        more.isHidden = hidden == 0
        more.stringValue = "+\(hidden) more"
        more.frame = CGRect(x: x, y: y, width: Self.width, height: 18)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === more ? nil : hit
    }
}

private final class ToastView: NSView {
    var onAction: ((Notice.Action) -> Void)?
    var onDismiss: (() -> Void)?
    var onHold: ((Bool) -> Void)?

    private let stripe = NSView()
    private let title = NSTextField(labelWithString: "")
    private let text = NSTextField(wrappingLabelWithString: "")
    private let close = NSButton()
    private var buttons: [NSButton] = []
    private var actions: [Notice.Action] = []
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    static func height(for notice: Notice) -> CGFloat {
        notice.actions == [.open] ? 66 : 100
    }

    init(notice: Notice) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = CanvasPalette.card.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(0.1).cgColor
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        stripe.wantsLayer = true
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        text.font = .systemFont(ofSize: 12)
        text.textColor = .secondaryLabelColor
        text.maximumNumberOfLines = 2
        text.lineBreakMode = .byTruncatingTail
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        close.isBordered = false
        close.imagePosition = .imageOnly
        close.contentTintColor = .tertiaryLabelColor
        close.target = self
        close.action = #selector(dismiss)
        for view in [stripe, title, text, close] as [NSView] { addSubview(view) }
        update(notice)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    func update(_ notice: Notice) {
        stripe.layer?.backgroundColor = Self.color(notice.kind).cgColor
        title.stringValue = notice.title
        text.stringValue = notice.text
        setAccessibilityLabel("\(notice.title): \(notice.text)")
        guard notice.actions != actions else { return }
        actions = notice.actions
        buttons.forEach { $0.removeFromSuperview() }
        buttons = notice.actions == [.open] ? [] : notice.actions.map { action in
            let button = NSButton(title: Self.title(action), target: self, action: #selector(press(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.tag = notice.actions.firstIndex(of: action) ?? 0
            if action == .allow { button.bezelColor = .controlAccentColor }
            addSubview(button)
            return button
        }
        needsLayout = true
    }

    static func title(_ action: Notice.Action) -> String {
        switch action {
        case .allow: "Allow"
        case .deny: "Deny"
        case .open: "Open"
        }
    }

    static func color(_ kind: Notice.Kind) -> NSColor {
        switch kind {
        case .waiting: .systemOrange
        case .done: .systemGreen
        case .error: .systemRed
        case .info: .systemBlue
        }
    }

    override func layout() {
        super.layout()
        stripe.frame = CGRect(x: 0, y: 0, width: 4, height: bounds.height)
        close.frame = CGRect(x: bounds.width - 28, y: 8, width: 20, height: 20)
        title.frame = CGRect(x: 16, y: 10, width: bounds.width - 16 - 32, height: 18)
        text.frame = CGRect(x: 16, y: 30, width: bounds.width - 32, height: 30)
        var x: CGFloat = 16
        for button in buttons {
            button.sizeToFit()
            let width = max(64, button.frame.width)
            button.frame = CGRect(x: x, y: bounds.height - 34, width: width, height: 24)
            x += width + 8
        }
    }

    @objc private func press(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        onAction?(actions[sender.tag])
    }

    @objc private func dismiss() { onDismiss?() }

    /// The body opens the card; buttons and × are handled above.
    override func mouseDown(with event: NSEvent) { onAction?(.open) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHold?(true) }
    override func mouseExited(with event: NSEvent) { onHold?(false) }
}
