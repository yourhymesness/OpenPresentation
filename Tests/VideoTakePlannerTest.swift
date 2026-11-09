import Foundation

@main struct VideoTakePlannerTest {
    static func main() throws {
        let path = "/tmp/shared-background.mov"
        let canonical = VideoTakePlanner.canonical(path)
        var video = PresentationSlide(text: "A")
        video.backgroundVideoPath = path
        let first = VideoTakePlanner.sessions(for: video, previous: [:])
        assert(first.count == 1)
        // Same file on adjacent slide => preserve decoder/playhead.
        var second = PresentationSlide(text: "B")
        second.backgroundVideoPath = path
        let next = VideoTakePlanner.sessions(for: second, previous: first)
        assert(next[canonical] == first[canonical])
        // Gap slide without video invalidates continuity.
        let gap = VideoTakePlanner.sessions(for: PresentationSlide(text: "No video"), previous: next)
        assert(gap.isEmpty)
        let returnSession = VideoTakePlanner.sessions(for: video, previous: gap)
        assert(returnSession[canonical] != next[canonical])
        // Even during the old decoder's two-second grace period, this token is fresh.
        assert(returnSession[canonical] != first[canonical])
        // Explicit Restart Every Take skips continuity even for the next slide.
        second.backgroundVideoTakeBehavior = .restartEachTake
        let forced = VideoTakePlanner.sessions(for: second, previous: first)
        assert(forced[canonical] != first[canonical])
        // Different media files get new sessions.
        let different = PresentationSlide(text: "Other")
        var other = different
        other.backgroundVideoPath = "/tmp/other.mov"
        let otherTokens = VideoTakePlanner.sessions(for: other, previous: first)
        assert(otherTokens[canonical] == nil && otherTokens.count == 1)
        // Foreground video layer participates in the same continuity rule.
        var foreground = PresentationSlide(text: "Foreground")
        foreground.layers.append(.makeVideo(path: path))
        let foreTokens = VideoTakePlanner.sessions(for: foreground, previous: first)
        assert(foreTokens[canonical] == first[canonical])
        foreground.layers[1].isVisible = false
        assert(VideoTakePlanner.sessions(for: foreground, previous: first).isEmpty)
        // Older JSON that omitted settings uses the safe default.
        assert(foreground.resolvedBackgroundVideoTakeBehavior == .continueOnConsecutive)
        assert(SlideLayer.makeVideo(path: path).resolvedVideoTakeBehavior == .continueOnConsecutive)
        print("PASS: adjacent media continuity, gap restart, forced restart, foreground media")
    }
}
