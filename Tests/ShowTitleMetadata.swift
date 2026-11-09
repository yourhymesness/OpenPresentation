import Foundation

/// Run on macOS/Linux with:
/// swiftc PresentationSlide.swift ProjectStore.swift ShowTitleMetadata.swift -o /tmp/title-test && /tmp/title-test
@main struct ShowTitleMetadata {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("Actual File Name.json")
        let named = PresentationShow(title: "Production Title", slides: [PresentationSlide(text: "Opening")])
        try ProjectStore.save(named, to: file)
        let reopened = try ProjectStore.load(from: file)
        precondition(reopened.title == "Production Title")
        precondition(reopened.slides.count == 1)
        let raw = try String(contentsOf: file, encoding: .utf8)
        precondition(raw.contains("\"title\" : \"Production Title\""))

        // A legacy show without title metadata must decode, not crash.
        let document = Data(#"{"formatVersion":1,"slides":[{"text":"Legacy slide"}]}"#.utf8)
        let legacyFile = root.appendingPathComponent("Legacy Concert.json")
        try document.write(to: legacyFile)
        let legacy = try ProjectStore.load(from: legacyFile)
        precondition(legacy.title.isEmpty)
        precondition(legacy.slides.first?.text == "Legacy slide")

        // A blank title is also permitted, allowing the opener to fall back
        // to legacyFile.deletingPathExtension().lastPathComponent.
        let empty = try JSONDecoder().decode(PresentationShow.self, from:
            Data(#"{"formatVersion":5,"title":"","slides":[]}"#.utf8))
        precondition(empty.title.isEmpty)
        print("PASS: persisted show title, missing-title compatibility, and blank-title fallback input")
    }
}
