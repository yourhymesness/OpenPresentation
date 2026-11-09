import Foundation

/// swiftc PresentationSlide.swift SameSlideEditedRetake.swift -o /tmp/edited-retake && /tmp/edited-retake
@main struct SameSlideEditedRetake {
    static func main() {
        let initial = PresentationSlide(text: "Old text", backgroundHex: "#000000")
        var edited = initial
        edited.layers[0].text = "New text"
        precondition(!edited.hasSameProgramContent(as: initial), "Edited on-air text must transition")
        var notesOnly = initial
        notesOnly.notes = "Updated operator note"
        notesOnly.slideTitle = "Renamed"
        notesOnly.transitionSecondsOverride = 2.0
        precondition(notesOnly.hasSameProgramContent(as: initial), "Metadata does not require a visual retake")
        let transparent = PresentationSlide(text: "First")
        let prepared = transparent.preparedForProgram(after: initial)
        let unchanged = transparent.preparedForProgram(after: prepared)
        precondition(unchanged.hasSameProgramContent(as: prepared), "Inherited background must stay stable")
        var changedTransparent = transparent
        changedTransparent.layers[0].text = "Second"
        precondition(!changedTransparent.preparedForProgram(after: prepared).hasSameProgramContent(as: prepared))
        print("PASS: changed same-slide retakes transition, unchanged retakes do not")
    }
}
