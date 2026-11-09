import Foundation

@main struct MediaStretchAndShapes {
    static func close(_ a: Double, _ b: Double, tolerance: Double = 1e-7) -> Bool {
        abs(a - b) < tolerance
    }

    static func main() throws {
        // Media locks by default but can be stretched independently while
        // Option is held. The actual picture/video pixel mode must follow.
        var picture = SlideLayer.makeImage(Data([0x89, 0x50]), width: 0.4, height: 0.25)
        precondition(picture.resolvedAspectRatioLocked, "images should lock by default")
        let original = LayerGeometry(layer: picture)
        let ordinary = original.resizing(from: .right, deltaX: 80, deltaY: 0,
                                         canvasWidth: 1920, canvasHeight: 1080,
                                         keepRatio: picture.resolvedAspectRatioLocked)
        precondition(close(ordinary.width * 1920 / (ordinary.height * 1080),
                           original.width * 1920 / (original.height * 1080)))
        let stretched = original.resizing(from: .right, deltaX: 80, deltaY: 0,
                                          canvasWidth: 1920, canvasHeight: 1080,
                                          keepRatio: false)
        precondition(close(stretched.height, original.height))
        stretched.applied(to: &picture)
        picture.applyResizeModifier(freeStretch: true)
        precondition(picture.resolvedContentMode == .stretch)
        precondition(picture.resolvedAspectRatioLocked,
                     "one-time modifier must not persistently switch off the lock")
        picture.contentMode = .fit
        precondition(picture.resolvedContentMode == .fit)
        picture.aspectRatioLocked = false
        precondition(!picture.resolvedAspectRatioLocked)

        var video = SlideLayer(name: "Test Video", kind: .video, width: 0.3,
                               height: 0.2, videoPath: "/tmp/clip.mov")
        precondition(video.resolvedAspectRatioLocked, "videos lock by default")
        video.applyResizeModifier(freeStretch: true)
        precondition(video.resolvedContentMode == .stretch)

        let shapeChecks: [(SlideShapeKind, Double, Double)] = [
            (.square, 280, 280), (.circle, 280, 280),
            (.equilateralTriangle, 320, 320 * sqrt(3) / 2)
        ]
        for (kind, pixelsW, pixelsH) in shapeChecks {
            let layer = SlideLayer.makeShape(kind)
            precondition(layer.resolvedAspectRatioLocked, "\(kind) should lock aspect")
            precondition(close(layer.width * 1920, pixelsW), "\(kind) width")
            precondition(close(layer.height * 1080, pixelsH), "\(kind) height")
            let ratio = layer.width * 1920 / (layer.height * 1080)
            precondition(close(ratio, kind.intrinsicPixelAspect!), "\(kind) intrinsic aspect")
            let grown = LayerGeometry(layer: layer).resizing(from: .bottomRight,
                deltaX: 38, deltaY: 3, canvasWidth: 1920, canvasHeight: 1080,
                keepRatio: layer.resolvedAspectRatioLocked)
            precondition(close(grown.width * 1920 / (grown.height * 1080), ratio),
                         "\(kind) should remain geometrically correct after normal resize")
            let decoded = try JSONDecoder().decode(SlideLayer.self, from: JSONEncoder().encode(layer))
            precondition(decoded.resolvedShapeKind == kind)
            precondition(decoded.resolvedAspectRatioLocked)
        }
        var converted = SlideLayer.makeShape(.rectangle)
        converted.selectShape(.equilateralTriangle)
        precondition(close(converted.width * 1920 / (converted.height * 1080),
                           2 / sqrt(3)))
        precondition(converted.resolvedAspectRatioLocked)
        converted.selectShape(.circle)
        precondition(close(converted.width * 1920, converted.height * 1080))

        let ordinaryRect = SlideLayer.makeShape(.rectangle)
        precondition(!ordinaryRect.resolvedAspectRatioLocked)
        precondition(SlideLayer.makeShape(.ellipse).resolvedShapeKind == .ellipse)
        print("PASS: media aspect lock, Option-free-stretch mapping, three exact shapes, conversion and Codable")
    }
}
