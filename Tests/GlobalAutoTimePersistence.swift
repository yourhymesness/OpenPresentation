import Foundation

@main
struct GlobalAutoTimePersistence {
    static func main() throws {
        let slide = PresentationSlide(text: "First")
        var second = PresentationSlide(text: "Second")
        second.autoAdvanceSeconds = 4.5
        let show = PresentationShow(title: "Program", slides: [slide, second],
                                    globalAutoAdvanceSeconds: 17.5)
        let roundTrip = try JSONDecoder().decode(PresentationShow.self, from: JSONEncoder().encode(show))
        precondition(roundTrip.globalAutoAdvanceSeconds == 17.5)
        precondition(roundTrip.slides[0].autoAdvanceSeconds == nil)
        precondition(roundTrip.slides[1].autoAdvanceSeconds == 4.5)
        let legacy = Data(#"{"formatVersion":5,"title":"Legacy","slides":[]}"#.utf8)
        let old = try JSONDecoder().decode(PresentationShow.self, from: legacy)
        precondition(old.globalAutoAdvanceSeconds == 10)
        precondition(old.globalTransitionSeconds == 0.65)
        print("PASS: global auto duration and per-slide override persist; v5 fallback")
    }
}
