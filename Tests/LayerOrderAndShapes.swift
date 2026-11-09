import Foundation

@main struct LayerOrderAndShapes {
    static func main() throws {
        var layers = [SlideLayer.makeText("Bottom"), SlideLayer.makeText("Middle"),
                      SlideLayer.makeText("Top")]
        let bottom = layers[0].id, middle = layers[1].id, top = layers[2].id
        LayerOrdering.apply(.front, id: bottom, layers: &layers)
        assert(layers.map(\.id) == [middle, top, bottom])
        LayerOrdering.apply(.back, id: bottom, layers: &layers)
        assert(layers.map(\.id) == [bottom, middle, top])
        LayerOrdering.apply(.forward, id: bottom, layers: &layers)
        assert(layers.map(\.id) == [middle, bottom, top])
        LayerOrdering.apply(.backward, id: bottom, layers: &layers)
        assert(layers.map(\.id) == [bottom, middle, top])
        LayerOrdering.drag(bottom, onto: top, layers: &layers)
        assert(layers.map(\.id) == [middle, top, bottom])
        LayerOrdering.drag(bottom, onto: middle, layers: &layers)
        assert(layers.map(\.id) == [bottom, middle, top])
        layers[0].isLocked = true
        LayerOrdering.apply(.front, id: bottom, layers: &layers)
        assert(layers[0].id == bottom)

        var slide = PresentationSlide(text: "Opening")
        for kind in SlideShapeKind.allCases {
            var object = SlideLayer.makeShape(kind)
            object.shapeFillHex = "#AABBCC"
            object.shapeStrokeHex = "#112233"
            object.shapeStrokeWidth = 8
            slide.layers.append(object)
        }
        let show = PresentationShow(title: "Vector Objects", slides: [slide])
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: path) }
        try ProjectStore.save(show, to: path)
        let restored = try ProjectStore.load(from: path)
        assert(restored.slides == show.slides)
        assert(restored.formatVersion == 5)
        let kinds = restored.slides[0].layers.compactMap(\.shapeKind)
        assert(kinds == SlideShapeKind.allCases)
        print("PASS: layer ordering, drag reorder, locked layers, vector object JSON round-trip and v5 show format")
    }
}
