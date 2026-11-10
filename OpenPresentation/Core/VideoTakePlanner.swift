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
    case sharedFrames = "Shared 12 FPS"
    case lowLoad = "Low-load"

    var id: String { rawValue }

    func renderMode(visibleVideos: Int, audienceOutputOpen: Bool,
                    pressureDetected: Bool = false) -> ProgramPreviewRenderMode {
        switch self {
        case .fullMotion: return .native
        case .lowLoad: return .placeholder
        case .sharedFrames: return audienceOutputOpen ? .sharedFrames : .native
        case .automatic:
            return audienceOutputOpen && visibleVideos > 0 && pressureDetected
                ? .sharedFrames : .native
        }
    }

    /// "Plays video" means a dedicated local Program AVPlayer is needed.
    func playsVideo(visibleVideos: Int, audienceOutputOpen: Bool,
                    pressureDetected: Bool = false) -> Bool {
        renderMode(visibleVideos: visibleVideos,
                   audienceOutputOpen: audienceOutputOpen,
                   pressureDetected: pressureDetected) == .native
    }
}

enum ProgramPreviewRenderMode {
    case native, sharedFrames, placeholder
}

enum SharedVideoPreviewPolicy {
    static let framesPerSecond: Double = 12
    static let maximumImageDimension: Double = 360
}



/// Pure reactive policy for conserving video decoders on the *operator*
/// Program monitor. It is intentionally independent of Core Animation and
/// audience video playback: only observable problems trigger the fallback.
///
/// Inputs come from the main-runloop heartbeat, macOS memory pressure events,
/// and ProcessInfo thermal state. This is a safeguard, not a reliable real-time
/// hardware decoder utilization monitor. A healthy 8-video slide stays live.
struct ProgramPreviewPerformanceGovernor {
    private(set) var isReduced = false
    private(set) var reason = ""
    private var lagScore = 0.0
    private var lastSample: Date?
    private var healthySince: Date?

    mutating func sample(at now: Date, timerOvershoot: TimeInterval,
                         audienceOutputOpen: Bool, visibleVideos: Int,
                         memoryPressure: Bool = false,
                         seriousThermalPressure: Bool = false) {
        let vulnerable = audienceOutputOpen && visibleVideos > 0
        let delta = lastSample.map { max(0, now.timeIntervalSince($0)) } ?? 0.25
        lastSample = now
        if !vulnerable {
            isReduced = false
            reason = ""
            lagScore = 0
            healthySince = nil
            return
        }

        // Decay measured main-thread stalls over time. Small scheduling
        // variations are ignored; two substantial hiccups within several
        // seconds (or a single severe stall) request reduced preview.
        lagScore *= pow(0.5, min(10, delta) / 4.0)
        let overshoot = max(0, timerOvershoot.isFinite ? timerOvershoot : 0)
        if overshoot > 0.50 {
            lagScore += 3.6
        } else if overshoot > 0.18 {
            lagScore += 1.65
        }
        let pressureReason: String? = {
            if memoryPressure { return "Memory pressure" }
            if seriousThermalPressure { return "Thermal pressure" }
            if lagScore >= 2.6 { return "Interface lag" }
            return nil
        }()
        if let pressureReason {
            healthySince = nil
            if !isReduced {
                isReduced = true
                reason = pressureReason
            } else if reason != pressureReason {
                reason = pressureReason
            }
            return
        }

        if isReduced {
            if healthySince == nil { healthySince = now }
            // Do not toggle repeatedly on a live show. Allow 30 seconds of
            // stable UI timing and normal memory/thermal readings first.
            if let healthySince, now.timeIntervalSince(healthySince) >= 30 {
                isReduced = false
                reason = ""
                lagScore = 0
                self.healthySince = nil
            }
        } else {
            healthySince = nil
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
