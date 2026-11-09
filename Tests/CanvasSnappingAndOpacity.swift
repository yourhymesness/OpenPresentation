import Foundation

@main struct CanvasSnappingAndOpacity {
    static func main() throws {
        var first = SlideLayer.makeText("First")
        first.centerX = 0.24; first.centerY = 0.45
        first.width = 0.20; first.height = 0.12
        var second = SlideLayer.makeText("Second")
        second.centerX = 0.72; second.centerY = 0.45
        second.width = 0.20; second.height = 0.12
        let origin = [first.id: LayerCenter(x: first.centerX, y: first.centerY),
                      second.id: LayerCenter(x: second.centerX, y: second.centerY)]
        let aligned = CanvasSnapper.resolve(layers: [first, second], movingIDs: [first.id],
            initialCenters: origin, dragX: 0.478, dragY: 0,
            canvasWidth: 1920, canvasHeight: 1080, enabled: true)
        assert(abs(first.centerX + aligned.deltaX - second.centerX) < 0.0001)
        assert(aligned.guides.contains(where: { $0.axis == .vertical }))
        let free = CanvasSnapper.resolve(layers: [first, second], movingIDs: [first.id],
            initialCenters: origin, dragX: 0.478, dragY: 0,
            canvasWidth: 1920, canvasHeight: 1080, enabled: false)
        assert(abs(free.deltaX - 0.478) < 1e-7)
        assert(free.guides.isEmpty)
        let grouped = CanvasSnapper.resolve(layers: [first, second], movingIDs: [first.id, second.id],
            initialCenters: origin, dragX: 0.9, dragY: 0,
            canvasWidth: 1920, canvasHeight: 1080, enabled: false)
        assert(grouped.deltaX < 0.2) // group stays inside right edge
        assert(grouped.deltaX >= 0)

        first.opacity = 0.37
        second.opacity = 0
        let slide = PresentationSlide(text: "")
        var show = PresentationShow(title: "Opacity Test", slides: [slide])
        show.slides[0].layers = [first, second]
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: path) }
        try ProjectStore.save(show, to: path)
        let opened = try ProjectStore.load(from: path)
        assert(opened.slides[0].layers[0].resolvedOpacity == 0.37)
        assert(opened.slides[0].layers[1].resolvedOpacity == 0)
        assert(SlideLayer.makeText().resolvedOpacity == 1)
        let legacy = try JSONEncoder().encode(SlideLayer.makeText())
        let decoded = try JSONDecoder().decode(SlideLayer.self, from: legacy)
        assert(decoded.resolvedOpacity == 1)
        print("PASS: snapping, no-snap, group movement bounds and opacity serialization")
    }
}
