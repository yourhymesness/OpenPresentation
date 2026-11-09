import Foundation

@main
struct CollectionsAndAutoplayMetadata {
    static func main() throws {
        let preshow = SlideCollection(name: "Pre-show")
        let showCollection = SlideCollection(name: "Show")
        var first = PresentationSlide(text: "Doors open")
        first.slideTitle = "Preshow 1"
        first.collectionID = preshow.id
        first.autoAdvanceSeconds = 8.5
        var second = PresentationSlide(text: "Welcome")
        second.collectionID = showCollection.id
        second.autoAdvanceSeconds = nil
        let saved = PresentationShow(title: "Event", slides: [first, second],
                                     collections: [preshow, showCollection], loopAutoAdvance: true)
        let read = try JSONDecoder().decode(PresentationShow.self, from: JSONEncoder().encode(saved))
        precondition(read.formatVersion == 5)
        precondition(read.loopAutoAdvance)
        precondition(read.collections.map(\.name) == ["Pre-show", "Show"])
        precondition(read.slides[0].collectionID == preshow.id)
        precondition(read.slides[0].autoAdvanceSeconds == 8.5)
        precondition(read.slides[1].autoAdvanceSeconds == nil)
        precondition(read.slides[0].resolvedAutoAdvanceSeconds == 8.5)
        precondition(read.slides[1].resolvedAutoAdvanceSeconds == 10.0)

        let old = """
        {"formatVersion":5,"title":"Old","slides":[{"id":"00000000-0000-0000-0000-000000000123","layers":[],"backgroundHex":"#00000000"}]}
        """
        let legacy = try JSONDecoder().decode(PresentationShow.self, from: Data(old.utf8))
        precondition(legacy.collections.isEmpty)
        precondition(legacy.loopAutoAdvance == false)
        precondition(legacy.slides.first?.collectionID == nil)
        precondition(legacy.slides.first?.autoAdvanceSeconds == nil)
        precondition(legacy.slides.first?.resolvedAutoAdvanceSeconds == 10.0)
        print("PASS: collections, auto-slide dwell and loop save/load; v5 legacy compatibility")
    }
}
