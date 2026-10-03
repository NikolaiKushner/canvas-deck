import AppKit

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

extension ClosureMenuItem {
    /// The ⌘ shortcut shown next to the item, and whether it can be chosen.
    func with(key: String, enabled: Bool = true) -> ClosureMenuItem {
        keyEquivalent = key
        keyEquivalentModifierMask = .command
        isEnabled = enabled
        return self
    }
}
