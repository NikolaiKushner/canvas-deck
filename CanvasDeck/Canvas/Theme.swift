import AppKit

/// Colours of the canvas and its chrome, light and dark, from the design
/// (Figma "Canvas Deck — Brand", page App design). Dynamic: a layer that takes
/// a `cgColor` must resolve it again when the appearance changes, see
/// `NSView.withEffectiveAppearance`.
enum CanvasPalette {
    static let background = dynamic(light: 0xF3F4F6, dark: 0x0E1015)
    /// Softened toward the background so the lattice stays visible without pulling focus.
    static let dot = dynamic(light: 0xD3D6DC, dark: 0x323845)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x1B1E26)
    /// The window's toolbar.
    static let bar = dynamic(light: 0xF9FAFB, dark: 0x15181F)
    static let text = dynamic(light: 0x1F2328, dark: 0xE6E8EC)
    static let secondaryText = dynamic(light: 0x6B7280, dark: 0x8B93A1)
    /// Hairlines: card edges, the line under a card's title bar.
    static let line = dynamic(light: (0x000000, 0.07), dark: (0xFFFFFF, 0.08))
    static let edge = dynamic(light: (0x000000, 0.09), dark: (0xFFFFFF, 0.11))
    /// Small fills: chips, the icon square, the account label.
    static let chip = dynamic(light: (0x000000, 0.05), dark: (0xFFFFFF, 0.07))
    static let chipStrong = dynamic(light: (0x000000, 0.08), dark: (0xFFFFFF, 0.11))
    static let shadowOpacity: (light: Float, dark: Float) = (0.10, 0.45)

    /// Agent states, the macOS system colours the cards always used.
    static let working = NSColor(hex: 0x0A84FF)
    static let permission = NSColor(hex: 0xFF9F0A)
    static let question = NSColor(hex: 0xE5B800)
    static let done = NSColor(hex: 0x30D158)
    static let error = NSColor(hex: 0xFF453A)
    static let accent = working

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { isDark($0) ? NSColor(hex: dark) : NSColor(hex: light) }
    }

    private static func dynamic(light: (UInt32, CGFloat), dark: (UInt32, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let (hex, alpha) = isDark(appearance) ? dark : light
            return NSColor(hex: hex).withAlphaComponent(alpha)
        }
    }
}

extension NSView {
    /// Runs `body` with this view's appearance current, so dynamic colours
    /// turned into `cgColor` resolve to its light or dark value.
    func withEffectiveAppearance(_ body: () -> Void) {
        effectiveAppearance.performAsCurrentDrawingAppearance(body)
    }

    var isDarkAppearance: Bool { CanvasPalette.isDark(effectiveAppearance) }
}
