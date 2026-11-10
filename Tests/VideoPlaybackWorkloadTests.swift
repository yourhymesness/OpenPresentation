import Foundation

@main struct VideoPlaybackWorkloadTests {
    static func main() {
        precondition(VideoPlaybackWorkload.rank("fullscreen") >
                     VideoPlaybackWorkload.rank("windowed"))
        precondition(VideoPlaybackWorkload.rank("windowed") >
                     VideoPlaybackWorkload.rank("program"))
        precondition(VideoPlaybackWorkload.observerInterval("program") >
                     VideoPlaybackWorkload.observerInterval("windowed"))
        precondition(VideoPlaybackWorkload.observerInterval("windowed") >
                     VideoPlaybackWorkload.observerInterval("fullscreen"))
        precondition(!VideoPlaybackWorkload.shouldMeter(scope: "program", audible: true))
        precondition(!VideoPlaybackWorkload.shouldMeter(scope: "windowed", audible: false))
        precondition(VideoPlaybackWorkload.shouldMeter(scope: "fullscreen", audible: true))
        precondition(!VideoPlaybackWorkload.shouldCorrect(
            follower: "windowed", leader: "program",
            difference: 2, elapsed: 10, bothPlaying: true))
        precondition(VideoPlaybackWorkload.shouldCorrect(
            follower: "program", leader: "windowed",
            difference: 1.0, elapsed: 10, bothPlaying: true))
        precondition(!VideoPlaybackWorkload.shouldCorrect(
            follower: "program", leader: "windowed",
            difference: 1, elapsed: 1.0, bothPlaying: true))
        precondition(!VideoPlaybackWorkload.shouldCorrect(
            follower: "program", leader: "windowed",
            difference: 1, elapsed: 10, bothPlaying: false))
        precondition(!VideoPlaybackWorkload.shouldCorrect(
            follower: "windowed", leader: "fullscreen",
            difference: 0.5, elapsed: 10, bothPlaying: true))
        let heavy = PresentationSlide(text: "Eight videos")
        var videoSlide = heavy
        for index in 0..<8 {
            videoSlide.layers.append(SlideLayer(name: "Video \(index)", kind: .video,
                                                 videoPath: "/tmp/v\(index).mov"))
        }
        precondition(VideoPlaybackWorkload.visibleVideoCount(videoSlide) == 8)
        precondition(ProgramPreviewQuality.automatic.playsVideo(
            visibleVideos: 3, audienceOutputOpen: true))
        precondition(!ProgramPreviewQuality.automatic.playsVideo(
            visibleVideos: 8, audienceOutputOpen: true))
        precondition(ProgramPreviewQuality.automatic.playsVideo(
            visibleVideos: 8, audienceOutputOpen: false))
        precondition(ProgramPreviewQuality.fullMotion.playsVideo(
            visibleVideos: 8, audienceOutputOpen: true))
        precondition(!ProgramPreviewQuality.lowLoad.playsVideo(
            visibleVideos: 1, audienceOutputOpen: false))
        print("PASS: playback priority, observation cadence, audio taps, seek cooldown and operator preview policy")
    }
}
