import Foundation

/// Normalized canvas coordinates. Pure model logic, independent of SwiftUI,
/// so group dragging and alignment can be tested outside macOS.
struct LayerCenter {
    var x: Double
    var y: Double
}

struct CanvasSnapGuide: Equatable {
    enum Axis: String { case horizontal, vertical }
    var axis: Axis
    var fraction: Double // 0...1 of the slide canvas
}

struct CanvasSnapResult {
    var deltaX: Double
    var deltaY: Double
    var guides: [CanvasSnapGuide]
}

enum CanvasSnapper {
    private struct Bounds {
        let left: Double
        let top: Double
        let right: Double
        let bottom: Double
        var centerX: Double { (left + right) / 2 }
        var centerY: Double { (top + bottom) / 2 }
    }

    /// Snap the entire moving group's boundaries/center to slide lines and
    /// other layer boundaries/centers (8 screen pixels). Locked layers are
    /// valid alignment targets but cannot be moved in the editor.
    static func resolve(layers: [SlideLayer], movingIDs: Set<UUID>,
                        initialCenters: [UUID: LayerCenter],
                        dragX: Double, dragY: Double,
                        canvasWidth: Double, canvasHeight: Double,
                        enabled: Bool) -> CanvasSnapResult {
        let moving = layers.filter { movingIDs.contains($0.id) && initialCenters[$0.id] != nil }
        guard !moving.isEmpty else { return CanvasSnapResult(deltaX: 0, deltaY: 0, guides: []) }
        let group = groupBounds(moving, centers: initialCenters)
        let xMin = -group.left
        let xMax = 1 - group.right
        let yMin = -group.top
        let yMax = 1 - group.bottom
        var dx = clamped(dragX, min: xMin, max: xMax)
        var dy = clamped(dragY, min: yMin, max: yMax)
        var guides: [CanvasSnapGuide] = []
        if enabled {
            let targetsX = [0.0, 0.5, 1.0] + layers.filter { !movingIDs.contains($0.id) && $0.isVisible }.flatMap {
                [$0.centerX - $0.width / 2, $0.centerX, $0.centerX + $0.width / 2]
            }
            let targetsY = [0.0, 0.5, 1.0] + layers.filter { !movingIDs.contains($0.id) && $0.isVisible }.flatMap {
                [$0.centerY - $0.height / 2, $0.centerY, $0.centerY + $0.height / 2]
            }
            if let found = closestSnap(lines: [group.left + dx, group.centerX + dx, group.right + dx],
                                       targets: targetsX, tolerance: 8 / max(canvasWidth, 1)) {
                dx = clamped(dx + found.correction, min: xMin, max: xMax)
                if abs(dx - dragX) <= 10 / max(canvasWidth, 1) || abs(found.correction) < 1e-7 {
                    guides.append(CanvasSnapGuide(axis: .vertical, fraction: found.target))
                }
            }
            if let found = closestSnap(lines: [group.top + dy, group.centerY + dy, group.bottom + dy],
                                       targets: targetsY, tolerance: 8 / max(canvasHeight, 1)) {
                dy = clamped(dy + found.correction, min: yMin, max: yMax)
                if abs(dy - dragY) <= 10 / max(canvasHeight, 1) || abs(found.correction) < 1e-7 {
                    guides.append(CanvasSnapGuide(axis: .horizontal, fraction: found.target))
                }
            }
        }
        return CanvasSnapResult(deltaX: dx, deltaY: dy, guides: guides)
    }

    private static func groupBounds(_ layers: [SlideLayer], centers: [UUID: LayerCenter]) -> Bounds {
        let left = layers.map { (centers[$0.id]?.x ?? $0.centerX) - $0.width / 2 }.min() ?? 0
        let right = layers.map { (centers[$0.id]?.x ?? $0.centerX) + $0.width / 2 }.max() ?? 1
        let top = layers.map { (centers[$0.id]?.y ?? $0.centerY) - $0.height / 2 }.min() ?? 0
        let bottom = layers.map { (centers[$0.id]?.y ?? $0.centerY) + $0.height / 2 }.max() ?? 1
        return Bounds(left: left, top: top, right: right, bottom: bottom)
    }

    private static func closestSnap(lines: [Double], targets: [Double], tolerance: Double)
        -> (correction: Double, target: Double)? {
        var best: (correction: Double, target: Double)?
        for line in lines {
            for target in targets {
                let correction = target - line
                guard abs(correction) <= tolerance else { continue }
                if best == nil || abs(correction) < abs(best!.correction) {
                    best = (correction, target)
                }
            }
        }
        return best
    }

    private static func clamped(_ value: Double, min lower: Double, max upper: Double) -> Double {
        Swift.min(Swift.max(value, Swift.min(lower, upper)), Swift.max(lower, upper))
    }
}

// MARK: - Eight-point layer geometry editing

/// Normalized layer rect relative to the current authored canvas. All layout
/// logic is pure and portable; pixels are introduced only at input boundaries.
struct LayerGeometry: Equatable {
    var left: Double
    var top: Double
    var width: Double
    var height: Double

    var right: Double { left + width }
    var bottom: Double { top + height }
    var centerX: Double { left + width / 2 }
    var centerY: Double { top + height / 2 }

    init(layer: SlideLayer) {
        left = layer.centerX - layer.width / 2
        top = layer.centerY - layer.height / 2
        width = layer.width
        height = layer.height
    }

    init(left: Double, top: Double, width: Double, height: Double) {
        self.left = left; self.top = top; self.width = width; self.height = height
    }

    func applied(to layer: inout SlideLayer) {
        layer.centerX = centerX; layer.centerY = centerY
        layer.width = width; layer.height = height
    }

    /// Positions belong to the top-left origin of the canvas. Dimensions can
    /// be edited independently, bounded by the edge and a 16px minimum.
    func setting(_ field: LayerDimensionField, pixels: Double,
                 canvasWidth: Double = 1920, canvasHeight: Double = 1080,
                 keepRatio: Bool = false) -> LayerGeometry {
        guard pixels.isFinite else { return self }
        let cw = max(canvasWidth, 1), ch = max(canvasHeight, 1)
        let minW = min(1, 16 / cw), minH = min(1, 16 / ch)
        var result = self
        switch field {
        case .x:
            result.left = min(max(0, pixels / cw), max(0, 1 - width))
        case .y:
            result.top = min(max(0, pixels / ch), max(0, 1 - height))
        case .width:
            result.width = min(max(minW, pixels / cw), 1 - left)
            if keepRatio {
                let ratio = (height * ch) / max(width * cw, 1)
                result.height = min(max(minH, result.width * cw * ratio / ch), 1 - top)
                result.width = min(result.width, result.height * ch / max(ratio, 0.00001) / cw)
            }
        case .height:
            result.height = min(max(minH, pixels / ch), 1 - top)
            if keepRatio {
                let ratio = (width * cw) / max(height * ch, 1)
                result.width = min(max(minW, result.height * ch * ratio / cw), 1 - left)
                result.height = min(result.height, result.width * cw / max(ratio, 0.00001) / ch)
            }
        }
        return result
    }

    /// Resizes the dragged edge/corner around the *opposite* fixed edges.
    /// Holding the aspect lock during a corner drag preserves pixel aspect.
    func resizing(from handle: LayerResizeHandle, deltaX: Double, deltaY: Double,
                  canvasWidth: Double, canvasHeight: Double,
                  keepRatio: Bool = false) -> LayerGeometry {
        let cw = max(canvasWidth, 1), ch = max(canvasHeight, 1)
        let minW = min(1, 16 / cw), minH = min(1, 16 / ch)
        var l = left, r = right, t = top, b = bottom
        let dx = deltaX / cw, dy = deltaY / ch
        if handle.movesLeft { l = max(0, min(r - minW, left + dx)) }
        if handle.movesRight { r = min(1, max(l + minW, right + dx)) }
        if handle.movesTop { t = max(0, min(b - minH, top + dy)) }
        if handle.movesBottom { b = min(1, max(t + minH, bottom + dy)) }

        if keepRatio {
            // Aspect lock is applied to corners and edge midpoints. Keep the
            // opposite side/corner anchored and fit inside the canvas.
            let ratio = (width * cw) / max(height * ch, 0.00001)
            var proposedW = r - l, proposedH = b - t
            if handle.affectsX && handle.affectsY {
                let xChange = abs((proposedW - width) / max(width, 0.0001))
                let yChange = abs((proposedH - height) / max(height, 0.0001))
                if xChange >= yChange { proposedH = proposedW * cw / ratio / ch }
                else { proposedW = proposedH * ch * ratio / cw }
            } else if handle.affectsX {
                proposedH = proposedW * cw / ratio / ch
            } else {
                proposedW = proposedH * ch * ratio / cw
            }
            let anchorX = handle.movesLeft ? right : (handle.movesRight ? left : centerX)
            let anchorY = handle.movesTop ? bottom : (handle.movesBottom ? top : centerY)
            let availableW = handle.movesLeft ? anchorX : (handle.movesRight ? 1 - anchorX : 2 * min(anchorX, 1 - anchorX))
            let availableH = handle.movesTop ? anchorY : (handle.movesBottom ? 1 - anchorY : 2 * min(anchorY, 1 - anchorY))
            let factor = min(1, availableW / max(proposedW, 0.0001), availableH / max(proposedH, 0.0001))
            proposedW = max(minW, proposedW * factor)
            proposedH = max(minH, proposedH * factor)
            if handle.movesLeft { l = anchorX - proposedW; r = anchorX }
            else if handle.movesRight { l = anchorX; r = anchorX + proposedW }
            else { l = anchorX - proposedW / 2; r = anchorX + proposedW / 2 }
            if handle.movesTop { t = anchorY - proposedH; b = anchorY }
            else if handle.movesBottom { t = anchorY; b = anchorY + proposedH }
            else { t = anchorY - proposedH / 2; b = anchorY + proposedH / 2 }
        }
        return LayerGeometry(left: l, top: t, width: r - l, height: b - t)
    }
}

enum LayerDimensionField { case x, y, width, height }

enum LayerResizeHandle: String, CaseIterable, Identifiable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    var id: Self { self }
    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var affectsX: Bool { movesLeft || movesRight }
    var affectsY: Bool { movesTop || movesBottom }
    var fx: Double { movesLeft ? 0 : (movesRight ? 1 : 0.5) }
    var fy: Double { movesTop ? 0 : (movesBottom ? 1 : 0.5) }
}
