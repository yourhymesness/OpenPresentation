import Foundation

@main struct SlideDuplicateIntegrity {
    static func main() throws {
        var slide = PresentationSlide(text: "Headline")
        slide.slideTitle = "Cue 7"
        slide.notes = "Follow spot"
        slide.autoAdvanceSeconds = 12
        slide.transitionSecondsOverride = 1.2
        slide.cueAudioGain = 0.34
        slide.collectionID = UUID()
        let group = UUID()
        var a = SlideLayer.makeText("Left", name: "A")
        var b = SlideLayer.makeText("Right", name: "B")
        a.groupID = group
        b.groupID = group
        slide.layers = [a, b]
        let copy = slide.duplicatedForLibrary()
        precondition(slide.id != copy.id)
        precondition(copy.layers[0].id != slide.layers[0].id)
        precondition(copy.layers[1].id != slide.layers[1].id)
        precondition(copy.layers[0].groupID != group)
        precondition(copy.layers[0].groupID == copy.layers[1].groupID)
        precondition(copy.layers.map(\.centerX) == slide.layers.map(\.centerX))
        precondition(copy.collectionID == slide.collectionID)
        precondition(copy.slideTitle == slide.slideTitle)
        precondition(copy.notes == slide.notes)
        precondition(copy.autoAdvanceSeconds == 12)
        precondition(copy.transitionSecondsOverride == 1.2)
        precondition(copy.cueAudioGain == 0.34)
        print("PASS: slide duplicating preserves all metadata while isolating identifiers")
    }
}
