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

/// A continuing video is one visual stream across consecutive slide takes.
/// Its parent slide contents may dissolve, but the retained AVPlayer layer
/// must remain fully visible instead of fading out and snapping back in.
enum VideoTransitionOpacityPolicy {
    static func opacity(for path: String, continuingPaths: Set<String>,
                        transitionOpacity: Double) -> Double {
        if continuingPaths.contains(VideoTakePlanner.canonical(path)) { return 1 }
        return transitionOpacity.isFinite ? min(max(transitionOpacity, 0), 1) : 0
    }
}

/// A continuing Video Layer must live outside *both* fading slide canvases.
/// These anchors let Program composite the content below the video, the one
/// persistent video, then the content above it, preserving authored z-order.
struct ContinuingVideoLayerAnchor: Identifiable {
    let id: String
    let fromIndex: Int
    let toIndex: Int
    /// Moving/resizing a continuous video needs two fading placements, not
    /// the single opaque placement used for identical layer geometry.
    let placementChanged: Bool
}

enum ContinuingVideoLayerPlan {
    static func anchors(from outgoing: PresentationSlide?, to incoming: PresentationSlide?,
                        continuingPaths: Set<String>) -> [ContinuingVideoLayerAnchor] {
        guard let outgoing, let incoming, !continuingPaths.isEmpty else { return [] }

        // Match by decoder identity (path + source slot), not layer UUID:
        // duplicating a slide creates new layer IDs but keeps the same video.
        func videoIndices(in slide: PresentationSlide) -> [(key: String, index: Int, layer: SlideLayer)] {
            var occurrences: [String: Int] = [:]
            var result: [(key: String, index: Int, layer: SlideLayer)] = []
            for (index, layer) in slide.layers.enumerated() where layer.kind == .video {
                guard let path = layer.videoPath, !path.isEmpty else { continue }
                let canonical = VideoTakePlanner.canonical(path)
                let occurrence = occurrences[canonical, default: 0]
                occurrences[canonical] = occurrence + 1
                guard layer.isVisible, continuingPaths.contains(canonical) else { continue }
                result.append(("\(canonical)|layer-\(occurrence)", index, layer))
            }
            return result
        }

        let oldIndices = Dictionary(uniqueKeysWithValues:
            videoIndices(in: outgoing).map { ($0.key, (index: $0.index, layer: $0.layer)) })
        let matched = videoIndices(in: incoming).compactMap { item -> ContinuingVideoLayerAnchor? in
            guard let old = oldIndices[item.key] else { return nil }
            let was = old.layer
            let now = item.layer
            let changed = was.centerX != now.centerX || was.centerY != now.centerY ||
                was.width != now.width || was.height != now.height ||
                was.resolvedContentMode != now.resolvedContentMode ||
                was.resolvedOpacity != now.resolvedOpacity
            return ContinuingVideoLayerAnchor(id: item.key, fromIndex: old.index,
                                              toIndex: item.index, placementChanged: changed)
        }
        // A reordering of two independent continuing videos cannot be mapped
        // into common depth bands. Keep the ordinary dissolve in that case.
        guard zip(matched, matched.dropFirst()).allSatisfy({ pair in
            pair.0.fromIndex < pair.1.fromIndex
        }) else {
            return []
        }
        return matched
    }
}

/// Pure scheduling rules: visual playback always stays at the source frame
/// rate (AVPlayerLayer), while lightweight end/loop observers may poll slower.
/// Fullscreen is authoritative, then Windowed, then the Program monitor.
enum ProgramPreviewQuality: String, CaseIterable, Identifiable {
    case automatic = "Auto"
    case fullMotion = "Full Video"
    case sharedFrames = "Shared 12 FPS"
    case metalFrames = "Metal 30 FPS · Test"
    case lowLoad = "Low-load"

    var id: String { rawValue }

    func renderMode(visibleVideos: Int, audienceOutputOpen: Bool,
                    pressureDetected: Bool = false) -> ProgramPreviewRenderMode {
        switch self {
        case .fullMotion: return .native
        // When the Program monitor is the only show display, it must be a
        // playable rehearsal surface, including soundtrack audio from video.
        case .lowLoad: return audienceOutputOpen ? .placeholder : .native
        case .sharedFrames: return audienceOutputOpen ? .sharedFrames : .native
        // The prototype consumes already-decoded audience frames. Without an
        // audience decoder, use the existing full-motion rehearsal renderer.
        case .metalFrames: return audienceOutputOpen ? .metalFrames : .native
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
    case native, sharedFrames, metalFrames, placeholder
}

/// Preview/audience Metal video sampling budget. The native AVFoundation path
/// follows its source and display timing independently of this preference.
enum MetalVideoFrameRate: Int, CaseIterable, Identifiable {
    case cinematic = 24
    case standard = 30
    case smooth = 60

    var id: Int { rawValue }

    static func validated(_ value: Int) -> Int {
        Self(rawValue: value)?.rawValue ?? Self.standard.rawValue
    }
}

enum SharedVideoPreviewPolicy {
    static let framesPerSecond: Double = 12
    static let maximumImageDimension: Double = 360
}

/// A persistent audio bus owns one stream per media take, independent of
/// which video output windows happen to be open. These descriptors are pure
/// show data so audio rendering does not depend on SwiftUI canvas lifetimes.
struct ProgramAudioCue: Identifiable {
    let path: String
    let sessionID: UUID
    let sourceSlot: String
    let loops: Bool
    let videoEndBehavior: VideoEndBehavior?
    let fadeDuration: Double
    var volume: Double
    var preFaderGain: Double
    var faderGain: Double

    var id: String { "\(path)|\(sessionID.uuidString)|\(sourceSlot)" }
}

enum ProgramAudioCuePlan {
    private static let fallbackSession = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    static func cues(slide: PresentationSlide?, sessions: [String: UUID],
                     transitionGain: Double = 1) -> [ProgramAudioCue] {
        guard let slide else { return [] }
        let fader = slide.resolvedCueAudioGain
        var result: [ProgramAudioCue] = []

        func add(path: String, slot: String, gain: Double, loops: Bool,
                 behavior: VideoEndBehavior? = nil, fade: Double = 0.75) {
            guard !path.isEmpty else { return }
            let canonical = VideoTakePlanner.canonical(path)
            result.append(ProgramAudioCue(path: canonical,
                                           sessionID: sessions[canonical] ?? fallbackSession,
                                           sourceSlot: slot, loops: loops,
                                           videoEndBehavior: behavior, fadeDuration: fade,
                                           volume: gain * fader * transitionGain,
                                           preFaderGain: gain * transitionGain,
                                           faderGain: fader))
        }

        if slide.backgroundVideoAudioEnabled == true, let path = slide.backgroundVideoPath {
            let behavior = slide.resolvedBackgroundVideoEndBehavior
            add(path: path, slot: "background", gain: slide.resolvedBackgroundVideoVolume,
                loops: behavior == .loop || behavior == .softLoop,
                behavior: behavior, fade: slide.resolvedBackgroundVideoFadeDuration)
        }
        var pathOccurrences: [String: Int] = [:]
        for layer in slide.layers {
            switch layer.kind {
            case .video:
                guard let path = layer.videoPath else { continue }
                let occurrence = pathOccurrences[path, default: 0]
                pathOccurrences[path] = occurrence + 1
                guard layer.isVisible, layer.videoAudioEnabled == true else { continue }
                let behavior = layer.resolvedVideoEndBehavior
                add(path: path, slot: "layer-\(occurrence)",
                    gain: layer.resolvedVideoVolume,
                    loops: behavior == .loop || behavior == .softLoop,
                    behavior: behavior, fade: layer.resolvedVideoFadeDuration)
            case .audio:
                guard layer.isVisible, let path = layer.audioPath else { continue }
                // Preserve consecutive-slide audio continuation even when
                // the authored layer UUID changes between slides.
                add(path: path, slot: "audio",
                    gain: layer.resolvedAudioVolume, loops: layer.audioLoops ?? false)
            default: break
            }
        }
        return result
    }

    /// A continued media session appearing in both transition frames must
    /// stay one audio stream. Add its fade-weighted gain, not its players.
    static func merged(_ cues: [ProgramAudioCue]) -> [ProgramAudioCue] {
        var byID: [String: ProgramAudioCue] = [:]
        for cue in cues {
            if var existing = byID[cue.id] {
                existing.volume += cue.volume
                existing.preFaderGain += cue.preFaderGain
                existing.faderGain = existing.preFaderGain > 0
                    ? min(1, existing.volume / existing.preFaderGain) : 0
                byID[cue.id] = existing
            } else {
                byID[cue.id] = cue
            }
        }
        return byID.values.sorted(by: { $0.id < $1.id })
    }
}

/// A new output created mid-slide needs a seek before it may become audible.
/// At the beginning of a take, both players can safely start at zero.
enum VideoAudioHandoffPolicy {
    static func needsAlignment(followerElapsed: Double, leaderElapsed: Double) -> Bool {
        leaderElapsed.isFinite && followerElapsed.isFinite &&
            leaderElapsed > 0.08 && abs(leaderElapsed - followerElapsed) > 0.12
    }
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
        audible && (scope == "fullscreen" || scope == "windowed" || scope == "program")
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
