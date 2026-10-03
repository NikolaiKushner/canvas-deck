import AppKit
import CanvasCore

/// The navigator's zoom menu: type a percentage, or the View menu's zoom commands.
@MainActor
final class ZoomMenu: NSObject, NSTextFieldDelegate {
    struct Actions {
        var zoomIn: () -> Void
        var zoomOut: () -> Void
        var fitAll: () -> Void
        var zoomToCard: () -> Void
        var zoomTo: (CGFloat) -> Void
    }

    static let presets: [CGFloat] = [0.5, 1, 2]

    private let menu = NSMenu()
    private let field = ZoomField()
    private let actions: Actions
    private var handlers: [NSMenuItem: () -> Void] = [:]

    /// "16%", "37%", "100%", "256%".
    static func percentText(_ scale: CGFloat) -> String { "\(Int((scale * 100).rounded()))%" }

    /// "150", "150%", " 75 % " → 1.5, 0.75; nil for anything else.
    static func parsePercent(_ text: String) -> CGFloat? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), value.isFinite, value > 0 else { return nil }
        return CGFloat(value / 100)
    }

    init(scale: CGFloat, hasCards: Bool, actions: Actions) {
        self.actions = actions
        super.init()
        menu.autoenablesItems = false

        let row = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 36))
        field.frame = CGRect(x: 14, y: 5, width: 172, height: 24)
        field.stringValue = Self.percentText(scale)
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.placeholderString = "Zoom %"
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.setAccessibilityLabel("Zoom percentage")
        row.addSubview(field)
        let fieldItem = NSMenuItem()
        fieldItem.view = row
        menu.addItem(fieldItem)
        menu.addItem(.separator())

        add("Zoom In", key: "=", modifiers: .command, enabled: scale < Camera.maxScale - 0.0001, actions.zoomIn)
        add("Zoom Out", key: "-", modifiers: .command, enabled: scale > Camera.minScale + 0.0001, actions.zoomOut)
        menu.addItem(.separator())
        add("Fit All", key: "1", modifiers: .shift, enabled: hasCards, actions.fitAll)
        add("Zoom to Card", key: "2", modifiers: .shift, enabled: hasCards, actions.zoomToCard)
        menu.addItem(.separator())
        for preset in Self.presets {
            let item = add("Zoom to \(Self.percentText(preset))", key: preset == 1 ? "0" : "", modifiers: .shift, enabled: true) {
                actions.zoomTo(preset)
            }
            item.state = abs(scale - preset) < 0.0005 ? .on : .off
        }
        // 16% … 256% is 0x10 … 0x100.
        let limits = NSMenuItem(title: "\(Self.percentText(Camera.minScale)) – \(Self.percentText(Camera.maxScale)) · 0x10 – 0x100", action: nil, keyEquivalent: "")
        limits.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(limits)
    }

    @discardableResult
    private func add(_ title: String, key: String, modifiers: NSEvent.ModifierFlags, enabled: Bool, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.isEnabled = enabled
        handlers[item] = handler
        menu.addItem(item)
        return item
    }

    @objc private func run(_ item: NSMenuItem) { handlers[item]?() }

    /// Opens above the control, right edges aligned, with the field ready to type.
    func popUp(from pill: NSView) {
        field.focusWhenShown = true
        let width = menu.size.width
        menu.popUp(positioning: nil, at: CGPoint(x: pill.bounds.maxX - width, y: pill.bounds.maxY + 6), in: pill)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if let scale = Self.parsePercent(field.stringValue) {
                menu.cancelTracking()
                actions.zoomTo(scale)
            } else {
                NSSound.beep()
            }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            menu.cancelTracking()
            return true
        }
        return false
    }
}

/// Takes the keyboard as soon as the menu shows it, text selected.
private final class ZoomField: NSTextField {
    var focusWhenShown = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusWhenShown, let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            window.makeFirstResponder(self)
            self.currentEditor()?.selectAll(nil)
        }
    }
}
