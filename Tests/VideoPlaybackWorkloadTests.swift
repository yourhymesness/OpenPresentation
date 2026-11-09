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
        print("PASS: playback priority, observation cadence, silent taps, seek cooldown")
    }
}
