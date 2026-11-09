import Foundation

@main struct MediaLayersV219 {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mp3 = root.appendingPathComponent("sound.mp3")
        try Data([11, 22, 33]).write(to: mp3)
        var audio = SlideLayer.makeAudio(path: mp3.path, name: "Entrance Cue")
        audio.audioLoops = true
        audio.audioVolume = 0.33
        var slide = PresentationSlide(text: "Testing")
        slide.layers.append(audio)
        slide.layers.append(SlideLayer.makeImage(Data("GIF89a".utf8), width: 0.3, height: 0.3))
        let saved = root.appendingPathComponent("Test.json")
        try ProjectStore.save(PresentationShow(title: "Media Test", slides: [slide]), to: saved)
        let show = try ProjectStore.load(from: saved)
        assert(show.formatVersion == 5)
        let loaded = show.slides[0].layers[1]
        assert(loaded.kind == .audio && loaded.audioLoops == true)
        assert(loaded.resolvedAudioVolume == 0.33)
        let packaged = try Data(contentsOf: URL(fileURLWithPath: loaded.audioPath!))
        assert(packaged == Data([11, 22, 33]))
        assert(show.slides[0].layers[2].imageData == Data("GIF89a".utf8))
        let session = VideoTakePlanner.sessions(for: show.slides[0], previous: [:])
        assert(session[VideoTakePlanner.canonical(loaded.audioPath!)] != nil)
        let continued = VideoTakePlanner.sessions(for: show.slides[0], previous: session)
        assert(continued == session)
        // Existing v5 files omitted the audio-only fields; they must decode.
        let encoded = try JSONEncoder().encode(SlideLayer.makeText("Legacy"))
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "audioPath")
        legacy.removeValue(forKey: "audioLoops")
        legacy.removeValue(forKey: "audioVolume")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let old = try JSONDecoder().decode(SlideLayer.self, from: legacyData)
        assert(old.audioPath == nil && old.audioLoops == nil)
        print("PASS: audio file packaged, GIF bytes preserved, audio session continuity, old layers decode")
    }
}
