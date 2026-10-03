import AppKit
import CanvasCore
import QuartzCore

/// Scroll view whose clip view is an unbounded flipped canvas. Magnification is
/// applied by AppKit; this view only reports camera changes so the grid and
/// minimap can follow.
final class CanvasScrollView: NSScrollView {
    var onCameraChanged: (() -> Void)?
    /// Scrolls a card let through but did not use. NSScrollView's own
    /// scrolling would move the clip behind the camera's back and pin it to
    /// the document's edges — the canvas jumped when a card slid under the
    /// cursor mid-gesture. The canvas pans them instead.
    var onUnhandledScroll: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onUnhandledScroll?(event)
    }

    override var magnification: CGFloat {
        didSet {
            guard magnification != oldValue else { return }
            // Nothing is redrawn here: the dot grid is a pattern on the
            // document layer, so Core Animation scales it with the content.
            // A whole-window CoreGraphics fill per zoom step cost ~40% of the
            // main thread (measured with six streaming terminals).
            onCameraChanged?()
        }
    }

    /// Same placement as the native-zoom spike: magnification, then the clip
    /// origin so `center` stays in the middle of the window.
    func apply(_ camera: Camera) {
        guard contentSize.width > 1, contentSize.height > 1 else { return }
        let visible = CGSize(width: contentSize.width / camera.scale, height: contentSize.height / camera.scale)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        magnification = camera.scale
        contentView.setBoundsOrigin(CGPoint(
            x: camera.center.x - visible.width / 2,
            y: camera.center.y - visible.height / 2
        ))
        reflectScrolledClipView(contentView)
        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }

    func readCamera() -> Camera {
        let visible = contentView.bounds
        return Camera(center: CGPoint(x: visible.midX, y: visible.midY), scale: magnification)
    }
}

/// Clip view with no edges. The flat background comes from `drawsBackground`;
/// the dots live on the document layer (`CanvasDocumentView.updateDots`).
final class CanvasClipView: NSClipView {
    var onBoundsChange: (() -> Void)?

    override var isFlipped: Bool { true }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        proposedBounds
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        onBoundsChange?()
    }
}

/// Dot lattice as a Core Graphics pattern color. Set as a layer background it
/// is tiled by the render server, so zoom and pan cost the app process nothing.
/// A new pattern is built only when the grid level or the dot radius changes.
enum DotPattern {
    private final class Cell {
        let step: CGFloat
        let radius: CGFloat
        init(step: CGFloat, radius: CGFloat) {
            self.step = step
            self.radius = radius
        }
    }

    static func cgColor(step: CGFloat, radius: CGFloat) -> CGColor? {
        var callbacks = CGPatternCallbacks(
            version: 0,
            drawPattern: { info, context in
                guard let info else { return }
                let cell = Unmanaged<Cell>.fromOpaque(info).takeUnretainedValue()
                context.setFillColor(CanvasPalette.dot.cgColor)
                context.fillEllipse(in: CGRect(
                    x: cell.step / 2 - cell.radius,
                    y: cell.step / 2 - cell.radius,
                    width: cell.radius * 2,
                    height: cell.radius * 2
                ))
            },
            releaseInfo: { info in
                guard let info else { return }
                Unmanaged<Cell>.fromOpaque(info).release()
            }
        )
        let cell = Unmanaged.passRetained(Cell(step: step, radius: radius))
        guard let pattern = CGPattern(
            info: cell.toOpaque(),
            bounds: CGRect(x: 0, y: 0, width: step, height: step),
            matrix: .identity,
            xStep: step,
            yStep: step,
            tiling: .constantSpacing,
            isColored: true,
            callbacks: &callbacks
        ), let space = CGColorSpace(patternBaseSpace: nil) else {
            cell.release()
            return nil
        }
        var alpha: CGFloat = 1
        return CGColor(patternSpace: space, pattern: pattern, components: &alpha)
    }
}
