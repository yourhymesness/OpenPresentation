import Foundation

@main struct FontHoverPreviewTests {
    static func main() throws {
        var original = PresentationSlide(text: "Greetings", backgroundHex: "#223344")
        let firstID = original.layers[0].id
        var another = SlideLayer.makeText("This must not change", name: "Second")
        another.fontFamily = "Helvetica Neue"
        original.layers.append(another)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let priorData = try encoder.encode(original)
        let previousFont = original.layers[0].fontFamily
        let draft = original.previewingFont("Georgia", onLayer: firstID)
        precondition(draft.layers[0].fontFamily == "Georgia")
        precondition(draft.layers[1] == original.layers[1])
        precondition(original.layers[0].fontFamily == previousFont)
        let postPreviewData = try encoder.encode(original)
        precondition(postPreviewData == priorData,
                     "A hover must not mutate or serialize into the saved slide")
        precondition(original.previewingFont(nil, onLayer: firstID) == original)
        precondition(original.previewingFont("", onLayer: firstID) == original)
        precondition(original.previewingFont("Georgia", onLayer: UUID()) == original)
        precondition(original.previewingFont("Georgia", onLayer: another.id).layers[0] == original.layers[0])
        // Committing is an explicit authored edit, not a hover side effect.
        var committed = original
        committed.layers[0].fontFamily = "Georgia"
        precondition(committed.layers[0].fontFamily == draft.layers[0].fontFamily)
        print("PASS: on-canvas hover font draft is non-destructive and selection-scoped")
    }
}
