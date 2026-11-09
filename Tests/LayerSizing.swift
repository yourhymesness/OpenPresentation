import Foundation

@main struct LayerSizingTests {
    static func approximate(_ a: Double, _ b: Double) -> Bool { abs(a-b) < 0.0001 }
    static func main() throws {
        var squareImage = SlideLayer.makeImage(Data([1, 2, 3]), width: 0.3, height: 0.3)
        squareImage.applyScalePreset(.fit, pixelSize: CGSize(width: 1000, height: 1000))
        assert(approximate(squareImage.width, 0.5625))
        assert(approximate(squareImage.height, 1.0))
        assert(squareImage.resolvedContentMode == .fit)
        squareImage.applyScalePreset(.fill)
        assert(squareImage.width == 1 && squareImage.height == 1)
        assert(squareImage.resolvedContentMode == .fill)
        squareImage.applyScalePreset(.stretch)
        assert(squareImage.resolvedContentMode == .stretch)
        squareImage.applyScalePreset(.original)
        assert(approximate(squareImage.width, 1000.0/1920.0))
        assert(approximate(squareImage.height, 1000.0/1080.0))
        assert(squareImage.resolvedContentMode == .fit)

        var portrait = SlideLayer.makeVideo(path: "/tmp/test.mp4")
        portrait.applyScalePreset(.fit, pixelSize: CGSize(width: 1080, height: 1920))
        assert(approximate(portrait.width, (1080.0/1920.0)/(1920.0/1080.0)))
        assert(approximate(portrait.height, 1))

        var text = SlideLayer.makeText("Hello")
        text.applyScalePreset(.fill)
        assert(text.width == 1 && text.height == 1)
        text.applyScalePreset(.original)
        assert(text.width == 0.72 && text.height == 0.38)

        let original = PresentationShow(title: "Preset test", slides: [
            PresentationSlide(text: "", backgroundHex: "#111111")
        ])
        var copy = original
        copy.slides[0].layers = [squareImage, portrait, text]
        let json = try JSONEncoder().encode(copy)
        let loaded = try JSONDecoder().decode(PresentationShow.self, from: json)
        assert(loaded.slides[0].layers == copy.slides[0].layers)
        assert(loaded.formatVersion == 5)

        // Older v5 shows never encoded contentMode or media dimensions.
        let old = """
        {"formatVersion":5,"title":"Old show","slides":[{"layers":[{"id":"123E4567-E89B-12D3-A456-426614174002","name":"Old image","kind":"image","isVisible":true,"isLocked":false,"centerX":0.5,"centerY":0.5,"width":0.3,"height":0.3,"text":"","fontFamily":"Helvetica Neue","fontSize":112,"textColorHex":"#FFFFFF","textAlignment":"Center"}]}]}
        """
        let legacy = try JSONDecoder().decode(PresentationShow.self, from: Data(old.utf8))
        assert(legacy.slides[0].layers[0].resolvedContentMode == .fit)
        print("PASS: fit, fill, stretch, original size, source pixels, text presets, and v5 backward compatibility")
    }
}
