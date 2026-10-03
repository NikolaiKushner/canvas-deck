import AppKit
import CanvasCore

/// Document that holds node views. The dot grid is a pattern background on a
/// backdrop subview that reaches far past the document in every direction, so
/// the lattice covers negative canvas coordinates too (the canvas pans past
/// the document's edges). No backing store: the render server tiles the dots
/// under any zoom.
final class CanvasDocumentView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// Half-extent of the backdrop in canvas points: 24 · 2¹⁴, a multiple of
    /// every grid step `DotGrid` can produce, so dots land on multiples of the
    /// step in canvas coordinates whatever the level.
    private static let backdropReach: CGFloat = DotGrid.baseStep * 16_384
    private let backdrop = DotBackdropView()
    private var dotStep: CGFloat = 0
    private var dotRadius: CGFloat = 0
    private var settle: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        backdrop.frame = CGRect(
            x: -Self.backdropReach, y: -Self.backdropReach,
            width: Self.backdropReach * 2, height: Self.backdropReach * 2
        )
        addSubview(backdrop)
    }

    required init?(coder: NSCoder) { nil }

    /// Grid level changes at once; the dot radius, which changes continuously
    /// with zoom, is only re-tiled once the zoom has settled for a moment.
    func updateDots(scale: CGFloat, settled: Bool = false) {
        let step = DotGrid.canvasStep(scale: scale)
        let radius = (1.2 / max(scale, Camera.minScale) * 10).rounded() / 10
        settle?.cancel()
        if step != dotStep {
            applyDots(step: step, radius: radius)
            return
        }
        guard radius != dotRadius else { return }
        if settled {
            applyDots(step: step, radius: radius)
        } else {
            let work = DispatchWorkItem { [weak self] in self?.applyDots(step: step, radius: radius) }
            settle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }

    private func applyDots(step: CGFloat, radius: CGFloat) {
        dotStep = step
        dotRadius = radius
        var color = CanvasPalette.dot.cgColor
        withEffectiveAppearance { color = CanvasPalette.dot.cgColor }
        backdrop.layer?.backgroundColor = step > 0 ? DotPattern.cgColor(step: step, radius: radius, color: color) : nil
    }

    /// Light ↔ dark: the dots are redrawn in the other colour.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if dotStep > 0 { applyDots(step: dotStep, radius: dotRadius) }
    }

    /// Nodes can sit at negative canvas coordinates, outside this view's frame.
    /// The default hit test stops at the frame, which made those parts unclickable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for subview in subviews.reversed() {
            if let hit = subview.hitTest(local) { return hit }
        }
        return self
    }
}

/// Carries the dot pattern; never drawn by the app, never hit.
private final class DotBackdropView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class CanvasRootView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// Hint text that does not steal clicks from the canvas behind it.
final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
