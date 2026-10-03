import AppKit
import CanvasCore

/// The toasts, top-right in the window over the canvas, in screen points like
/// the navigator. Only toasts take the mouse; the canvas around them stays live.
final class NoticeStackView: NSView {
    static let width: CGFloat = 300
    static let margin: CGFloat = 20
    static let gap: CGFloat = 10

    var onAction: ((UUID, Notice.Action) -> Void)?
    var onDismiss: ((UUID) -> Void)?
    var onHold: ((UUID, Bool) -> Void)?

    private var toasts: [UUID: ToastView] = [:]
    private let more = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        more.font = .systemFont(ofSize: 12, weight: .semibold)
        more.textColor = CanvasPalette.secondaryText
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
            let height = ToastView.height(for: notice, width: Self.width)
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

/// One notice (App design → Notice): a dot in the state's colour, what
/// happened, the detail in monospace, and for a permission prompt
/// "Allow 1 · Deny esc · Open card →". The keys work on the canvas while no
/// card has the keyboard.
private final class ToastView: NSView {
    var onAction: ((Notice.Action) -> Void)?
    var onDismiss: (() -> Void)?
    var onHold: ((Bool) -> Void)?

    private let dot = NSView()
    private let title = NSTextField(labelWithString: "")
    private let age = NSTextField(labelWithString: "")
    private let text = NSTextField(wrappingLabelWithString: "")
    private let close = NSButton()
    private var buttons: [ToastButton] = []
    private var actions: [Notice.Action] = []
    private var notice: Notice
    private var tracking: NSTrackingArea?
    private var ageTimer: Timer?

    override var isFlipped: Bool { true }

    static let padding: CGFloat = 14

    static func height(for notice: Notice, width: CGFloat) -> CGFloat {
        let detail = Self.detail(notice)
        let textHeight = detail.isEmpty ? 0 : min(2, lines(detail, width: width - padding * 2)) * 15 + 6
        let actionsHeight: CGFloat = notice.actions.contains(.allow) ? 8 + 24 : 0
        return 12 + 18 + textHeight + actionsHeight + 12
    }

    private static func lines(_ text: String, width: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: 200), options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return max(1, ceil(rect.height / font.boundingRectForFont.height.rounded()))
    }

    /// "refactor-auth needs permission", "docs is done".
    static func headline(_ notice: Notice) -> String {
        switch notice.kind {
        case .waiting: notice.actions.contains(.allow) ? "\(notice.title) needs permission" : "\(notice.title) has a question"
        case .done: "\(notice.title) is done"
        case .error: "\(notice.title) stopped"
        case .info: notice.title
        }
    }

    /// "Bash: rm -rf dist", without the words the headline already says.
    static func detail(_ notice: Notice) -> String {
        var text = notice.text
        for prefix in ["Wants permission: ", "Needs permission", "Finished"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if let open = text.firstIndex(of: "("), text.hasSuffix(")"), !text[..<open].contains(" ") {
            // "Bash(npm test)" reads as "Bash: npm test".
            text = "\(text[..<open]): \(text[text.index(after: open)..<text.index(before: text.endIndex)])"
        }
        return text
    }

    init(notice: Notice) {
        self.notice = notice
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -12)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.textColor = CanvasPalette.text
        title.lineBreakMode = .byTruncatingTail
        age.font = .systemFont(ofSize: 11)
        age.textColor = CanvasPalette.secondaryText
        age.alignment = .right
        text.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        text.textColor = CanvasPalette.secondaryText
        text.maximumNumberOfLines = 2
        text.lineBreakMode = .byTruncatingTail
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        close.isBordered = false
        close.imagePosition = .imageOnly
        close.contentTintColor = CanvasPalette.secondaryText
        close.target = self
        close.action = #selector(dismiss)
        close.isHidden = true
        for view in [dot, title, age, text, close] as [NSView] { addSubview(view) }
        update(notice)
        applyColors()
        setAccessibilityRole(.group)
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAge() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ageTimer = timer
    }

    required init?(coder: NSCoder) { nil }

    override func removeFromSuperview() {
        ageTimer?.invalidate()
        super.removeFromSuperview()
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
        }
        layer?.shadowOpacity = (dark ? CanvasPalette.shadowOpacity.dark : CanvasPalette.shadowOpacity.light) * 1.4
    }

    func update(_ notice: Notice) {
        self.notice = notice
        dot.layer?.backgroundColor = Self.color(notice).cgColor
        title.stringValue = Self.headline(notice)
        text.stringValue = Self.detail(notice)
        text.isHidden = text.stringValue.isEmpty
        updateAge()
        setAccessibilityLabel("\(title.stringValue): \(notice.text)")
        guard notice.actions != actions else { return }
        actions = notice.actions
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        if notice.actions.contains(.allow) {
            buttons = [
                ToastButton(title: "Allow", key: "1", style: .primary) { [weak self] in self?.onAction?(.allow) },
                ToastButton(title: "Deny", key: "esc", style: .secondary) { [weak self] in self?.onAction?(.deny) },
                ToastButton(title: "Open card →", key: nil, style: .link) { [weak self] in self?.onAction?(.open) },
            ]
            buttons.forEach(addSubview)
        }
        needsLayout = true
    }

    private func updateAge() {
        let seconds = Date().timeIntervalSince(notice.postedAt)
        age.stringValue = seconds < 60 ? "now" : seconds < 3600 ? "\(Int(seconds / 60))m" : "\(Int(seconds / 3600))h"
    }

    static func color(_ notice: Notice) -> NSColor {
        switch notice.kind {
        case .waiting: notice.actions.contains(.allow) ? CanvasPalette.permission : CanvasPalette.question
        case .done: CanvasPalette.done
        case .error: CanvasPalette.error
        case .info: CanvasPalette.working
        }
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        let pad = Self.padding
        dot.frame = CGRect(x: pad, y: 12 + 5, width: 8, height: 8)
        let ageWidth = ceil(age.intrinsicContentSize.width) + 2
        age.frame = CGRect(x: bounds.width - pad - ageWidth, y: 13, width: ageWidth, height: 16)
        close.frame = CGRect(x: bounds.width - pad - 16, y: 12, width: 16, height: 18)
        title.frame = CGRect(x: pad + 16, y: 12, width: max(0, age.frame.minX - pad - 16 - 6), height: 18)
        var y: CGFloat = 12 + 18 + 6
        if !text.isHidden {
            let lines = min(2, Self.lines(text.stringValue, width: bounds.width - pad * 2))
            text.frame = CGRect(x: pad, y: y, width: bounds.width - pad * 2, height: lines * 15)
            y += lines * 15
        }
        var x = pad
        for button in buttons {
            let width = button.fittingWidth
            button.frame = CGRect(x: x, y: bounds.height - 12 - 24, width: width, height: 24)
            x += width + (button.style == .secondary ? 10 : 6)
        }
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

    /// × shows on hover, in place of the age.
    override func mouseEntered(with event: NSEvent) {
        onHold?(true)
        close.isHidden = false
        age.isHidden = true
    }

    override func mouseExited(with event: NSEvent) {
        onHold?(false)
        close.isHidden = true
        age.isHidden = false
    }
}

/// "Allow 1": a label and its key, filled blue, grey, or a plain link.
private final class ToastButton: NSView {
    enum Style { case primary, secondary, link }
    let style: Style
    private let label = NSTextField(labelWithString: "")
    private let key = NSTextField(labelWithString: "")
    private let action: () -> Void

    init(title: String, key keyText: String?, style: Style, action: @escaping () -> Void) {
        self.style = style
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        label.stringValue = title
        label.font = .systemFont(ofSize: 12, weight: .medium)
        key.stringValue = keyText ?? ""
        key.font = .systemFont(ofSize: 11)
        key.isHidden = keyText == nil
        addSubview(label)
        addSubview(key)
        applyColors()
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    var fittingWidth: CGFloat {
        if style == .link { return ceil(label.intrinsicContentSize.width) + 4 }
        return 12 + ceil(label.intrinsicContentSize.width) + (key.isHidden ? 0 : 6 + ceil(key.intrinsicContentSize.width)) + 10
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        withEffectiveAppearance {
            switch style {
            case .primary:
                layer?.backgroundColor = CanvasPalette.accent.cgColor
                label.textColor = .white
                key.textColor = NSColor.white.withAlphaComponent(0.7)
            case .secondary:
                layer?.backgroundColor = CanvasPalette.chipStrong.cgColor
                label.textColor = CanvasPalette.text
                key.textColor = CanvasPalette.secondaryText
            case .link:
                layer?.backgroundColor = nil
                label.textColor = CanvasPalette.accent
            }
        }
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        let x: CGFloat = style == .link ? 2 : 12
        label.frame = CGRect(x: x, y: (bounds.height - size.height) / 2, width: ceil(size.width) + 2, height: size.height)
        let keySize = key.intrinsicContentSize
        key.frame = CGRect(x: label.frame.maxX + 4, y: (bounds.height - keySize.height) / 2, width: ceil(keySize.width) + 2, height: keySize.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}
