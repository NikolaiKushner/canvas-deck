import AppKit

extension NSWindow.Level {
    /// Floating panels over the canvas window: pickers, ⌘K, the task panel.
    static let canvasPanel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 3)
}
