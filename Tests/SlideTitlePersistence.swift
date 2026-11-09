import Foundation

@main struct SlideTitlePersistence {
    static func main() throws {
        var slide = PresentationSlide(text: "Visible audience text")
        assert(slide.displayTitle == "Visible audience text")
        slide.slideTitle = "Cue 12 — Opening"
        assert(slide.displayTitle == "Cue 12 — Opening")
        assert(slide.text == "Visible audience text")
        let root = FileManager.default.temporaryDirectory
        let url = root.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ProjectStore.save(PresentationShow(title: "Test", slides: [slide]), to: url)
        let saved = try ProjectStore.load(from: url).slides[0]
        assert(saved.slideTitle == slide.slideTitle)
        assert(saved.text == slide.text)
        let older = try JSONDecoder().decode(PresentationSlide.self,
            from: Data(##"{"text":"Old slide","notes":"Hi","backgroundHex":"#112233"}"##.utf8))
        assert(older.slideTitle.isEmpty)
        assert(older.displayTitle == "Old slide")
        print("PASS: slide title independent of output text, persisted in v5, old-file fallback")
    }
}
