import Foundation

/// Run as a macOS smoke test alongside the application's model sources.
/// Program takes (including Auto's private takeSnapshotLive path) must never
/// steal the editor's selected slide while the operator is in Blind mode.
@MainActor
@main
struct BlindProgramSelectionSmokeTest {
    static func main() {
        let show = ShowController()
        show.addSlide()
        let firstID = show.selectedSlideID!
        show.addSlide()
        let editingID = show.selectedSlideID!
        show.addSlide()
        let thirdID = show.selectedSlideID!

        show.mode = .live
        show.takeLive(show.slides[0])
        precondition(show.liveSlideID == firstID)
        show.mode = .blind
        show.select(show.slides[2])
        precondition(show.selectedSlideID == thirdID)

        show.advanceProgram(by: 1)
        precondition(show.liveSlideID == editingID)
        precondition(show.selectedSlideID == thirdID,
                     "Program navigation changed the Blind editor selection")
        show.advanceProgram(by: -1)
        precondition(show.liveSlideID == firstID)
        precondition(show.selectedSlideID == thirdID)
        print("PASS: Blind Program navigation does not change editing selection")
    }
}
