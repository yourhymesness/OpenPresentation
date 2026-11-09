import Foundation

@main struct CanvasZoomAndTextOutlineTests {
    static func main() throws {
        let wide = ShowCanvasSize.fullHD
        let portrait = ShowCanvasSize(width: 1080, height: 1920)
        let fitWide = CanvasZoom.fitScale(canvas: wide, viewportWidth: 640,
                                           viewportHeight: 360, padding: 0)
        let fitPortrait = CanvasZoom.fitScale(canvas: portrait, viewportWidth: 640,
                                               viewportHeight: 360, padding: 0)
        precondition(abs(fitWide - 1.0 / 3) < 0.00001)
        precondition(abs(fitPortrait - 0.1875) < 0.00001)
        precondition(CanvasZoom.scroll(current: fitWide, delta: 3) > fitWide)
        precondition(CanvasZoom.scroll(current: fitWide, delta: -3) < fitWide)
        precondition(CanvasZoom.pinch(current: 1, magnification: 0.2) > 1)
        precondition(CanvasZoom.pinch(current: 1, magnification: -0.2) < 1)
        precondition(CanvasZoom.clamp(999) == CanvasZoom.maximumScale)
        precondition(CanvasZoom.clamp(0) == CanvasZoom.minimumScale)
        precondition(CanvasZoom.label(1) == "100%")
        precondition(CanvasZoom.maximumScale(for: wide) == 4)
        precondition(abs(CanvasZoom.maximumScale(for: ShowCanvasSize(width: 8192, height: 8192)) - 1) < 0.00001)
        precondition(CanvasZoom.clamp(4, canvas: ShowCanvasSize(width: 8192, height: 8192)) == 1)

        let old = SlideLayer.makeText("White lyrics", color: "#FFFFFF")
        precondition(old.resolvedTextOutlineWidth == 0)
        precondition(old.resolvedTextOutlineColor == "#000000")
        var modern = old
        modern.textOutlineWidth = 3
        modern.textOutlineColorHex = "#1A1A1A"
        let encoded = try JSONEncoder().encode(modern)
        let decoded = try JSONDecoder().decode(SlideLayer.self, from: encoded)
        precondition(decoded == modern)
        precondition(decoded.resolvedTextOutlineWidth == 3)

        // Simulate an older show file without the optional outline keys.
        var legacyObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacyObject.removeValue(forKey: "textOutlineWidth")
        legacyObject.removeValue(forKey: "textOutlineColorHex")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(SlideLayer.self, from: legacyData)
        precondition(legacy.resolvedTextOutlineWidth == 0)
        precondition(legacy.resolvedTextOutlineColor == "#000000")
        print("PASS canvas zoom math and optional text outline persistence")
    }
}
