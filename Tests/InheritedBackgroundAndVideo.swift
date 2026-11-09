import Foundation

/// Linux/macOS: swiftc PresentationSlide.swift VideoTakePlanner.swift InheritedBackgroundAndVideo.swift -o /tmp/background-test && /tmp/background-test
@main struct InheritedBackgroundAndVideo {
    static func main() throws {
        let transparent = PresentationSlide(text: "New title")
        precondition(transparent.isVisuallyTransparentBackground)
        precondition(!transparent.inheritsProgramBackground, "Transparent means no background unless opted in")
        let firstOnAir = transparent.preparedForProgram(after: nil)
        precondition(firstOnAir.backgroundHex == "#00000000")

        let dark = PresentationSlide(text: "Old", backgroundHex: "#151515")
        let clearedColor = transparent.preparedForProgram(after: dark)
        precondition(clearedColor.backgroundHex == "#00000000", "Transparent slide clears prior background")
        var retaining = transparent
        retaining.retainPreviousBackground = true
        let inheritedColor = retaining.preparedForProgram(after: dark)
        precondition(inheritedColor.backgroundHex == dark.backgroundHex)
        precondition(transparent.backgroundHex == "#00000000", "Authored slide must remain transparent")
        precondition(!dark.inheritsProgramBackground)
        let explicitBlack = PresentationSlide(text: "Black", backgroundHex: "#000000")
        precondition(!explicitBlack.inheritsProgramBackground)
        precondition(explicitBlack.preparedForProgram(after: dark).backgroundHex == "#000000")
        let alphaZero = PresentationSlide(text: "Alpha", backgroundHex: "#FFFFFF00")
        precondition(alphaZero.isVisuallyTransparentBackground)
        precondition(!alphaZero.inheritsProgramBackground)

        var video = PresentationSlide(text: "Video BG")
        video.backgroundVideoPath = "/tmp/intro.mov"
        video.backgroundVideoAudioEnabled = true
        video.backgroundVideoVolume = 0.42
        precondition(!video.inheritsProgramBackground)
        let sessions = VideoTakePlanner.sessions(for: video, previous: [:])
        let overVideo = retaining.preparedForProgram(after: video)
        precondition(overVideo.backgroundVideoPath == video.backgroundVideoPath)
        precondition(overVideo.backgroundVideoVolume == video.backgroundVideoVolume)
        precondition(overVideo.backgroundVideoAudioEnabled == true)
        let nextSessions = VideoTakePlanner.sessions(for: overVideo, previous: sessions)
        let key = VideoTakePlanner.canonical("/tmp/intro.mov")
        precondition(nextSessions[key] == sessions[key], "Inherited background must keep decoder/playhead")

        let third = retaining.preparedForProgram(after: overVideo)
        precondition(third.backgroundVideoPath == "/tmp/intro.mov")
        let otherSessions = VideoTakePlanner.sessions(for: third, previous: nextSessions)
        precondition(otherSessions[key] == nextSessions[key])

        // Persisted document must retain the editable transparent original.
        let show = PresentationShow(title: "Transparency", slides: [video, transparent])
        let restored = try JSONDecoder().decode(PresentationShow.self, from: JSONEncoder().encode(show))
        precondition(restored.slides[1].backgroundHex == "#00000000")
        precondition(restored.slides[1].backgroundVideoPath == nil)
        precondition(restored.slides[1].retainPreviousBackground == nil)
        let configured = PresentationShow(title: "Persistent", slides: [video, retaining])
        let roundTrip = try JSONDecoder().decode(PresentationShow.self, from: JSONEncoder().encode(configured))
        precondition(roundTrip.slides[1].retainPreviousBackground == true)
        precondition(roundTrip.slides[1].preparedForProgram(after: video).backgroundVideoPath == video.backgroundVideoPath)
        print("PASS: transparent clears, explicit inherited color/video, video continuity and saved setting")
    }
}
