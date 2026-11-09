import Foundation

/// Pure math for editor-only zoom. Never modifies a slide or a saved show.
/// "100%" maps one authored canvas pixel to one logical editor point.
enum CanvasZoom {
    static let minimumScale = 0.025
    static let maximumScale = 4.0
    static let presets: [Double] = [0.10, 0.25, 0.50, 0.75, 1.0, 1.25, 1.5, 2.0, 4.0]

    static func fitScale(canvas: ShowCanvasSize, viewportWidth: Double,
                         viewportHeight: Double, padding: Double = 8) -> Double {
        let width = max(1, viewportWidth - 2 * padding)
        let height = max(1, viewportHeight - 2 * padding)
        return min(width / Double(canvas.width), height / Double(canvas.height))
    }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return max(minimumScale, min(maximumScale, value))
    }

    // The current shared renderer bounds its drawing surface at 8192 points.
    // Do not let enlarged custom canvases outgrow that backing surface, or
    // hit regions and rendered pixels would no longer be aligned.
    static func maximumScale(for canvas: ShowCanvasSize) -> Double {
        min(maximumScale, 8192 / Double(canvas.width), 8192 / Double(canvas.height))
    }

    static func clamp(_ value: Double, canvas: ShowCanvasSize) -> Double {
        min(clamp(value), maximumScale(for: canvas))
    }

    static func scroll(current: Double, delta: Double) -> Double {
        guard delta.isFinite else { return clamp(current) }
        let boundedDelta = max(-24, min(24, delta))
        return clamp(current * exp(boundedDelta * 0.04))
    }

    static func pinch(current: Double, magnification: Double) -> Double {
        guard magnification.isFinite else { return clamp(current) }
        return clamp(current * max(0.1, 1 + magnification))
    }

    static func label(_ scale: Double) -> String {
        "\(Int((scale * 100).rounded()))%"
    }
}
