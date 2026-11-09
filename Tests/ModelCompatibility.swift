import Foundation

/// Run on macOS or Linux with:
/// swiftc PresentationSlide.swift ProjectStore.swift ModelCompatibility.swift -o /tmp/modeltest && /tmp/modeltest
@main struct ModelCompatibility {
    static func main() throws {
        let oldID = UUID(uuidString: "123E4567-E89B-12D3-A456-426614174000")!
        let legacyJSON = Data("""
        {
          "formatVersion": 1, "title": "Legacy Test",
          "slides": [{
            "id": "123E4567-E89B-12D3-A456-426614174000",
            "text": "Legacy title", "backgroundHex": "#0000FF",
            "foregroundHex": "#AAFFAA", "fontSize": 99,
            "imageLayers": [{
              "id": "123E4567-E89B-12D3-A456-426614174001",
              "imageData": "AQIDBA==", "centerX": 0.25,
              "centerY": 0.75, "width": 0.14, "height": 0.10
            }]
          }]
        }
        """.utf8)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: temp) }
        try legacyJSON.write(to: temp)
        let migrated = try ProjectStore.load(from: temp)
        assert(migrated.slides.count == 1)
        let slide = migrated.slides[0]
        assert(slide.id == oldID)
        assert(slide.layers.count == 2)
        assert(slide.layers[0].kind == .text)
        assert(slide.layers[0].text == "Legacy title")
        assert(slide.layers[0].fontSize == 99)
        assert(slide.layers[0].textColorHex == "#AAFFAA")
        assert(slide.layers[1].kind == .image)
        assert(slide.layers[1].imageData == Data([1, 2, 3, 4]))
        assert(slide.layers[1].centerX == 0.25)
        assert(slide.layers[1].centerY == 0.75)
        assert(slide.layers[1].width == 0.14)

        var modern = PresentationShow(title: "Layer Test", slides: [slide])
        modern.slides[0].layers.append(.makeText("Second text box", fontSize: 48))
        modern.slides[0].layers.swapAt(0, 1)
        modern.slides[0].layers[2].fontFamily = "Courier"
        modern.slides[0].layers[1].isVisible = false
        modern.slides[0].layers[1].isLocked = true
        try ProjectStore.save(modern, to: temp)
        let result = try ProjectStore.load(from: temp)
        assert(result.formatVersion == 6)
        assert(result.slides == modern.slides)
        assert(result.slides[0].layers.map(\.kind) == [.image, .text, .text])
        print("PASS: v0.1.4 migration, text/image layering, v5 JSON round-trip, visibility, locks, fonts")
    }
}
