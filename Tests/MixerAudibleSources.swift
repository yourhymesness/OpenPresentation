import Foundation

@main struct MixerAudibleSources {
    static func main() throws {
        var silent = PresentationSlide(text: "Silent")
        precondition(!silent.containsAudioMedia)
        var video = SlideLayer.makeVideo(path: "/tmp/background.mov")
        silent.layers.append(video)
        precondition(!silent.containsAudioMedia, "Video audio disabled by default")
        video.videoAudioEnabled = true
        silent.layers = [video]
        precondition(silent.containsAudioMedia)
        silent.layers[0].isVisible = false
        precondition(!silent.containsAudioMedia)
        silent.layers.append(SlideLayer.makeAudio(path: "/tmp/theme.wav"))
        precondition(silent.containsAudioMedia)
        var background = PresentationSlide(text: "Background")
        background.backgroundVideoPath = "/tmp/loop.mov"
        background.backgroundVideoAudioEnabled = true
        precondition(background.containsAudioMedia)
        let transparency = PresentationSlide(text: "Title only")
        precondition(!transparency.containsAudioMedia)
        precondition(!transparency.preparedForProgram(after: background).containsAudioMedia,
                     "Unconfigured transparent slides clear the previous soundtrack")
        var persistent = transparency
        persistent.retainPreviousBackground = true
        precondition(persistent.preparedForProgram(after: background).containsAudioMedia,
                     "Opted-in retained background audio must not be greyed out")
        print("PASS: video/audio detection, transparent clear, explicit retained-background soundtrack")
    }
}
