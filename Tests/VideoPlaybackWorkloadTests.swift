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
        precondition(ProgramPreviewQuality.automatic.playsVideo(
            visibleVideos: 8, audienceOutputOpen: true))
        precondition(!ProgramPreviewQuality.automatic.playsVideo(
            visibleVideos: 8, audienceOutputOpen: true, pressureDetected: true))
        precondition(ProgramPreviewQuality.automatic.playsVideo(
            visibleVideos: 8, audienceOutputOpen: false))
        precondition(ProgramPreviewQuality.fullMotion.playsVideo(
            visibleVideos: 8, audienceOutputOpen: true))
        precondition(!ProgramPreviewQuality.lowLoad.playsVideo(
            visibleVideos: 1, audienceOutputOpen: false))
        var governor = ProgramPreviewPerformanceGovernor()
        let zero = Date(timeIntervalSince1970: 10000)
        for i in 0..<40 {
            governor.sample(at: zero.addingTimeInterval(Double(i) * 0.25),
                            timerOvershoot: 0.015, audienceOutputOpen: true,
                            visibleVideos: 8)
        }
        precondition(!governor.isReduced, "Video count alone must not reduce the preview")
        let lag1 = zero.addingTimeInterval(10.25)
        governor.sample(at: lag1, timerOvershoot: 0.11, audienceOutputOpen: true,
                        visibleVideos: 8)
        precondition(!governor.isReduced, "A single moderate hiccup should not trip Auto")
        governor.sample(at: lag1.addingTimeInterval(0.25), timerOvershoot: 0.12,
                        audienceOutputOpen: true, visibleVideos: 8)
        precondition(governor.isReduced && governor.reason == "Interface lag")
        governor.sample(at: lag1.addingTimeInterval(1), timerOvershoot: 0,
                        audienceOutputOpen: true, visibleVideos: 8)
        precondition(governor.isReduced, "Must not thrash after a stall")
        for i in 1...132 {
            governor.sample(at: lag1.addingTimeInterval(1 + Double(i) * 0.25),
                            timerOvershoot: 0, audienceOutputOpen: true, visibleVideos: 8)
        }
        precondition(!governor.isReduced, "Preview should return after stable recovery")
        governor.sample(at: lag1.addingTimeInterval(35), timerOvershoot: 0,
                        audienceOutputOpen: true, visibleVideos: 8,
                        memoryPressure: true)
        precondition(governor.isReduced && governor.reason == "Memory pressure")
        governor.sample(at: lag1.addingTimeInterval(35.25), timerOvershoot: 0,
                        audienceOutputOpen: false, visibleVideos: 8)
        precondition(!governor.isReduced, "Closing audience output restores preview")
        governor.sample(at: lag1.addingTimeInterval(36), timerOvershoot: 0,
                        audienceOutputOpen: true, visibleVideos: 8,
                        seriousThermalPressure: true)
        precondition(governor.isReduced && governor.reason == "Thermal pressure")
        print("PASS: playback priority, meter gating, adaptive preview, recovery and manual overrides")
    }
}
