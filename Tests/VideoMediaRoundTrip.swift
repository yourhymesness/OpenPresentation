import Foundation

/// Run with:
/// swiftc PresentationSlide.swift ProjectStore.swift VideoMediaRoundTrip.swift -o /tmp/media-test && /tmp/media-test
@main struct VideoMediaRoundTrip {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mockVideo = root.appendingPathComponent("movie.mp4")
        let fakeBytes = Data([0, 1, 2, 3, 4, 5, 6, 7])
        try fakeBytes.write(to: mockVideo)

        var slide = PresentationSlide(text: "Hello", backgroundHex: "#111111")
        slide.backgroundVideoPath = mockVideo.path
        var layer = SlideLayer.makeVideo(path: mockVideo.path, name: "Clip")
        layer.centerX = 0.23
        layer.centerY = 0.77
        layer.videoLoops = false // legacy compatibility remains available
        layer.videoEndBehavior = .softLoop
        layer.videoTakeBehavior = .restartEachTake
        layer.videoFadeDuration = 1.3
        layer.videoAudioEnabled = true
        layer.videoVolume = 0.45
        slide.backgroundVideoEndBehavior = .fadeToBlack
        slide.backgroundVideoTakeBehavior = .continueOnConsecutive
        slide.backgroundVideoFadeDuration = 1.1
        slide.backgroundVideoAudioEnabled = true
        slide.backgroundVideoVolume = 0.65
        slide.layers.append(layer)
        let show = PresentationShow(title: "Video Save Test", slides: [slide])

        let file = root.appendingPathComponent("Show.json")
        try ProjectStore.save(show, to: file)
        let savedString = try String(contentsOf: file, encoding: .utf8)
        assert(savedString.contains("media:"))
        assert(!savedString.contains(mockVideo.path))
        let reloaded = try ProjectStore.load(from: file)
        let actualVideo = reloaded.slides[0].backgroundVideoPath!
        assert(FileManager.default.fileExists(atPath: actualVideo))
        assert(reloaded.slides[0].layers[1].videoPath == actualVideo)
        assert(reloaded.slides[0].layers[1].videoLoops == false)
        assert(reloaded.slides[0].layers[1].resolvedVideoEndBehavior == .softLoop)
        assert(reloaded.slides[0].layers[1].resolvedVideoTakeBehavior == .restartEachTake)
        assert(reloaded.slides[0].layers[1].resolvedVideoFadeDuration == 1.3)
        assert(reloaded.slides[0].layers[1].videoAudioEnabled == true)
        assert(reloaded.slides[0].layers[1].resolvedVideoVolume == 0.45)
        assert(reloaded.slides[0].resolvedBackgroundVideoEndBehavior == .fadeToBlack)
        assert(reloaded.slides[0].resolvedBackgroundVideoTakeBehavior == .continueOnConsecutive)
        assert(reloaded.slides[0].resolvedBackgroundVideoFadeDuration == 1.1)
        assert(reloaded.slides[0].backgroundVideoAudioEnabled == true)
        assert(reloaded.slides[0].resolvedBackgroundVideoVolume == 0.65)
        assert(reloaded.slides[0].layers[1].centerX == 0.23)
        assert(reloaded.slides[0].layers[1].centerY == 0.77)
        let copiedBytes = try Data(contentsOf: URL(fileURLWithPath: actualVideo))
        assert(copiedBytes == fakeBytes)
        try ProjectStore.save(reloaded, to: file) // overwrite: reuse sibling media path
        assert(ProjectStoreTestFiles.count(in: root.appendingPathComponent("Show.media")) == 1)

        let copiedShow = root.appendingPathComponent("Another Show.json")
        try ProjectStore.save(reloaded, to: copiedShow) // Save As: copy companion media
        let again = try ProjectStore.load(from: copiedShow)
        assert(FileManager.default.fileExists(atPath: again.slides[0].backgroundVideoPath!))

        let legacy = PresentationSlide(text: "Legacy Slide")
        let legacyFile = root.appendingPathComponent("legacy.json")
        try ProjectStore.save(PresentationShow(title: "Legacy", slides: [legacy]), to: legacyFile)
        let noVideo = try ProjectStore.load(from: legacyFile)
        assert(noVideo.slides[0].backgroundVideoPath == nil)
        assert(noVideo.slides[0].layers[0].videoPath == nil)
        assert(noVideo.slides[0].resolvedBackgroundVideoEndBehavior == .loop)
        assert(noVideo.slides[0].resolvedBackgroundVideoTakeBehavior == .continueOnConsecutive)
        assert(SlideLayer.makeVideo(path: "unused").resolvedVideoEndBehavior == .loop)

        // A v0.2.2-style layer with videoLoops=false should become hold-last.
        var oldLayerTemplate = SlideLayer.makeVideo(path: "unused.mov", name: "Old Clip")
        oldLayerTemplate.videoLoops = false
        let oldLayerData = try JSONEncoder().encode(oldLayerTemplate)
        var oldLayerDictionary = try JSONSerialization.jsonObject(with: oldLayerData) as! [String: Any]
        for key in ["videoEndBehavior", "videoTakeBehavior", "videoFadeDuration", "videoAudioEnabled", "videoVolume"] {
            oldLayerDictionary.removeValue(forKey: key)
        }
        let oldLayerJSON = try JSONSerialization.data(withJSONObject: oldLayerDictionary)
        let oldLayer = try JSONDecoder().decode(SlideLayer.self, from: oldLayerJSON)
        assert(oldLayer.resolvedVideoEndBehavior == .holdLastFrame)
        assert(oldLayer.videoAudioEnabled == nil)
        assert(oldLayer.resolvedVideoTakeBehavior == .continueOnConsecutive)
        print("PASS: local video media packaged/reloaded, multiple references, loop setting, save-as, old slides")
    }
}
private enum ProjectStoreTestFiles {
    static func count(in dir: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path).count) ?? 0
    }
}
