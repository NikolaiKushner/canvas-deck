import CoreGraphics

/// Miro-style dot lattice. `canvasStep` is the distance between dots in canvas
/// points. It doubles when zooming out and halves when zooming in, so the gap
/// on screen stays between `minScreenSpacing` and `maxScreenSpacing`.
public enum DotGrid {
    public static let baseStep: CGFloat = 24
    public static let minScreenSpacing: CGFloat = 16
    public static let maxScreenSpacing: CGFloat = 32
    /// Finest lattice still lands on `baseStep / 16`.
    public static let finestStep: CGFloat = baseStep / 16

    public static func canvasStep(scale: CGFloat) -> CGFloat {
        let scale = max(scale, 0.000_1)
        var step = baseStep
        while step * scale < minScreenSpacing {
            step *= 2
        }
        while step * scale > maxScreenSpacing, step / 2 >= finestStep {
            let finer = step / 2
            if finer * scale < minScreenSpacing { break }
            step = finer
        }
        return step
    }
}
