import Foundation

@main struct LayerGeometryEightHandles {
    static func check(_ b: Bool, _ message: String) { precondition(b, message) }
    static func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.00001 }
    static func main() {
        var layer = SlideLayer.makeShape(.rectangle)
        layer.centerX = 0.5; layer.centerY = 0.5
        layer.width = 0.4; layer.height = 0.2
        let rect = LayerGeometry(layer: layer)
        let cw = 1920.0, ch = 1080.0
        // All eight handles independently move the corresponding sides.
        for h in LayerResizeHandle.allCases {
            let result = rect.resizing(from: h, deltaX: 80, deltaY: 60,
                                       canvasWidth: cw, canvasHeight: ch)
            check(result.left >= 0 && result.top >= 0 && result.right <= 1 && result.bottom <= 1,
                  "\(h) exceeded canvas")
            check(result.width > 0 && result.height > 0, "\(h) collapsed")
            if h.movesLeft { check(result.left > rect.left, "\(h) left side") }
            if h.movesRight { check(result.right > rect.right, "\(h) right side") }
            if h.movesTop { check(result.top > rect.top, "\(h) top side") }
            if h.movesBottom { check(result.bottom > rect.bottom, "\(h) bottom side") }
            if !h.affectsX { check(approx(result.left,rect.left) && approx(result.right,rect.right), "\(h) unexpected X") }
            if !h.affectsY { check(approx(result.top,rect.top) && approx(result.bottom,rect.bottom), "\(h) unexpected Y") }
        }
        let px = rect.setting(.width, pixels: 840)
        check(approx(px.width * cw, 840) && approx(px.height, rect.height), "W should be independent")
        let moved = px.setting(.x, pixels: 200).setting(.y, pixels: 50)
        check(approx(moved.left * cw, 200) && approx(moved.top * ch, 50), "exact X/Y")
        var updated = layer
        moved.applied(to: &updated)
        check(approx(updated.centerX, moved.centerX), "apply center")
        check(approx(updated.width, moved.width), "apply width")
        let locked = rect.resizing(from: .bottomRight, deltaX: 80, deltaY: 10,
                                   canvasWidth: cw, canvasHeight: ch, keepRatio: true)
        check(abs(locked.width * cw / (locked.height * ch) - rect.width * cw / (rect.height * ch)) < 0.00001,
              "locked pixel ratio")
        let edge = LayerGeometry(left: 0.93, top: 0.93, width: 0.07, height: 0.07)
        let capped = edge.resizing(from: .bottomRight, deltaX: 500, deltaY: 500,
                                   canvasWidth: cw, canvasHeight: ch)
        check(capped.right <= 1.000001 && capped.bottom <= 1.000001, "edge clamp")
        print("PASS: eight handles, free sizing, exact pixels, aspect lock, bounds")
    }
}
