import Foundation

@main struct CanvasSizePersistenceTests {
    static func main() throws {
        let presets = ShowCanvasPreset.allCases.filter { $0 != .custom }
        precondition(presets.count == 10)
        precondition(ShowCanvasPreset.portraitHD.size?.ratio == 1080.0 / 1920.0)
        precondition(ShowCanvasPreset.squareHD.size?.ratio == 1)
        precondition(ShowCanvasPreset.wide3072.size?.ratio == 4)
        precondition(ShowCanvasSize.fullHD.sizeLabel == "1920 × 1080")
        precondition(ShowCanvasSize.fullHD.ratioLabel == "16:9")
        precondition(ShowCanvasSize(width: 1080, height: 1920).ratioLabel == "9:16")
        precondition(ShowCanvasSize(width: -50, height: 90000) ==
                     ShowCanvasSize(width: 64, height: 8192))

        let legacy = Data(#"{"formatVersion":5,"title":"Legacy","slides":[]}"#.utf8)
        let old = try JSONDecoder().decode(PresentationShow.self, from: legacy)
        precondition(old.canvasSize == .fullHD, "v5 must preserve 1920×1080")

        for preset in presets {
            let canvas = preset.size!
            let slide = PresentationSlide(text: "Sample", backgroundHex: "#111111")
            let show = PresentationShow(title: "Canvas migration", slides: [slide], canvasSize: canvas)
            let roundtrip = try JSONDecoder().decode(PresentationShow.self,
                                                     from: JSONEncoder().encode(show))
            precondition(roundtrip.formatVersion == 6)
            precondition(roundtrip.canvasSize == canvas, "Canvas lost during JSON roundtrip: \(preset)")
            precondition(roundtrip.slides[0].layers == show.slides[0].layers,
                         "Normalized geometry changed: \(preset)")
        }
        let portrait = ShowCanvasSize(width: 1080, height: 1920)
        let square = SlideLayer.makeShape(.square, canvasSize: portrait)
        precondition(abs(square.width * 1080 - square.height * 1920) < 0.0001)
        let circle = SlideLayer.makeShape(.circle, canvasSize: portrait)
        precondition(abs(circle.width * 1080 - circle.height * 1920) < 0.0001)
        let triangle = SlideLayer.makeShape(.equilateralTriangle, canvasSize: portrait)
        precondition(abs((triangle.width * 1080) / (triangle.height * 1920) - 2 / sqrt(3)) < 0.0001)
        var image = SlideLayer.makeImage(Data([1, 2, 3]), width: 0.5, height: 0.5)
        image.applyScalePreset(.original, pixelSize: CGSize(width: 540, height: 960), canvasSize: portrait)
        precondition(abs(image.width - 0.5) < 1e-7 && abs(image.height - 0.5) < 1e-7)
        let scene = LayerGeometry(layer: square).setting(.width, pixels: 100,
                       canvasWidth: Double(portrait.width), canvasHeight: Double(portrait.height))
        precondition(abs(scene.width * 1080 - 100) < 0.0001)

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try ProjectStore.save(PresentationShow(title: "Portrait", slides: [], canvasSize: portrait), to: temp)
        let loaded = try ProjectStore.load(from: temp)
        precondition(loaded.formatVersion == 6)
        precondition(loaded.canvasSize == portrait)
        try FileManager.default.removeItem(at: temp)
        print("PASS: canvas presets, v5 fallback, v6 JSON/save/load, shapes, normalized geometry, pixel fields")
    }
}
