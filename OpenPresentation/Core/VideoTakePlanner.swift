import Foundation

/// The decoder cache may retain a player briefly for a SwiftUI transition,
/// but a new video *take* must never accidentally reclaim an older playhead.
/// A token is created only on a deliberate Take Live, not on view creation.
/// All output windows receive the same token for a take; their audience/monitor
/// pool keys still remain separate so sound isn't duplicated.
enum VideoTakePlanner {
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The same asset appearing twice on one slide uses one playback instance
    /// per output. Independent duplicate instances are a future enhancement.
    static func behaviors(in slide: PresentationSlide?) -> [String: VideoTakeBehavior] {
        guard let slide else { return [:] }
        var result: [String: VideoTakeBehavior] = [:]
        func insert(_ path: String, _ behavior: VideoTakeBehavior) {
            let key = canonical(path)
            // Restart wins if multiple visible layers reference one video and
            // disagree about the per-take policy.
            if result[key] == .restartEachTake { return }
            result[key] = behavior
        }
        if let path = slide.backgroundVideoPath, !path.isEmpty {
            insert(path, slide.resolvedBackgroundVideoTakeBehavior)
        }
        for layer in slide.layers where layer.isVisible {
            if layer.kind == .video, let path = layer.videoPath, !path.isEmpty {
                insert(path, layer.resolvedVideoTakeBehavior)
            } else if layer.kind == .audio, let path = layer.audioPath, !path.isEmpty {
                // An audio-only file also receives a session token and survives
                // directly adjacent slide takes when that same audio is present.
                insert(path, .continueOnConsecutive)
            }
        }
        return result
    }

    /// Preserve a session only when the *immediately previous live slide*
    /// contained that video AND the incoming slide elects to continue it.
    static func sessions(for incoming: PresentationSlide,
                         previous: [String: UUID]) -> [String: UUID] {
        var result: [String: UUID] = [:]
        for (path, behavior) in behaviors(in: incoming) {
            if behavior == .continueOnConsecutive, let existing = previous[path] {
                result[path] = existing
            } else {
                result[path] = UUID()
            }
        }
        return result
    }
}

/// Pure scheduling rules: visual playback always stays at the source frame
/// rate (AVPlayerLayer), while lightweight end/loop observers may poll slower.
/// Fullscreen is authoritative, then Windowed, then the silent Program monitor.
enum ProgramPreviewQuality: String, CaseIterable, Identifiable {
    case automatic = "Auto"
    case fullMotion = "Full Video"
    case lowLoad = "Low-load"

    var id: String { rawValue }

    func playsVideo(visibleVideos: Int, audienceOutputOpen: Bool) -> Bool {
        switch self {
        case .fullMotion: return true
        case .lowLoad: return false
        case .automatic:
            // Keep preview fidelity for ordinary shows. Under an unusually
            // heavy slide, stop duplicate silent Program decoders to protect
            // audience playback, while leaving audience renderers untouched.
            return !audienceOutputOpen || visibleVideos < 4
        }
    }
}

enum VideoPlaybackWorkload {
    static func visibleVideoCount(_ slide: PresentationSlide?) -> Int {
        guard let slide else { return 0 }
        let background = (slide.backgroundVideoPath?.isEmpty == false) ? 1 : 0
        let layers = slide.layers.filter {
            $0.kind == .video && $0.isVisible && $0.videoPath?.isEmpty == false
        }.count
        return background + layers
    }

    static func rank(_ scope: String) -> Int {
        switch scope {
        case "fullscreen": return 3
        case "windowed": return 2
        case "program": return 1
        default: return 0
        }
    }

    static func observerInterval(_ scope: String) -> Double {
        switch scope {
        case "fullscreen": return 1.0 / 30.0
        case "windowed": return 1.0 / 20.0
        default: return 1.0 / 10.0
        }
    }

    static func shouldMeter(scope: String, audible: Bool) -> Bool {
        audible && (scope == "fullscreen" || scope == "windowed")
    }

    static func shouldCorrect(follower: String, leader: String,
                              difference: Double, elapsed: Double,
                              bothPlaying: Bool) -> Bool {
        guard rank(leader) > rank(follower), bothPlaying,
              difference.isFinite, elapsed.isFinite else { return false }
        // Operators may intentionally seek frequently. A relaxed drift
        // threshold and cooldown prevent the decoder from thrashing.
        let threshold = follower == "program" ? 0.9 : 0.65
        return abs(difference) > threshold && elapsed >= 3.0
    }
}
