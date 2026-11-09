import Foundation

@main struct TransparentNotesAndGroups {
    static func main() throws {
        var slide = PresentationSlide(text: "")
        assert(slide.backgroundHex == "#00000000")
        assert(slide.layers.isEmpty)
        slide.notes = "House lights down; wait for FOH cue."
        let group = UUID()
        var first = SlideLayer.makeText("First")
        first.groupID = group
        var second = SlideLayer.makeShape(.rectangle)
        second.groupID = group
        slide.layers = [first, second]
        let show = PresentationShow(title: "V0.2.15", slides: [slide])
        let json = try JSONEncoder().encode(show)
        let restored = try JSONDecoder().decode(PresentationShow.self, from: json)
        assert(restored.slides[0].notes == slide.notes)
        assert(restored.slides[0].backgroundHex == "#00000000")
        assert(restored.slides[0].layers[0].groupID == group)
        assert(restored.slides[0].layers[1].groupID == group)
        let oldJSON = """
        {"id":"00000000-0000-0000-0000-000000000001","backgroundHex":"#15263D","layers":[]}
        """.data(using: .utf8)!
        let old = try JSONDecoder().decode(PresentationSlide.self, from: oldJSON)
        assert(old.notes.isEmpty)
        assert(old.backgroundHex == "#15263D")
        print("PASS: transparent blank defaults, slide notes, group IDs, backward compatibility")
    }
}
