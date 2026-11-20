import AppKit
import AVFoundation
import SwiftUI

/// The only audible show transport. It is mounted once by the operator, not
/// by an audience output or the quality-reduced Program video canvas.
/// Opening/closing a video window therefore never touches this player.
/// Distinct audio files can play concurrently and mix through Core Audio.
struct AudioPlaybackSurface: NSViewRepresentable {
    @ObservedObject var liveAudioMix = LiveAudioMix.shared
    let path: String
    let playbackSessionID: UUID
    var sourceSlot: String = "audio"
    var outputScope: String
    var audible: Bool
    var volume: Double
    var loops: Bool
    var videoEndBehavior: VideoEndBehavior? = nil
    var fadeDuration: Double = 0.75
    var preFaderGain: Double = 1
    var faderGain: Double = 1

    func makeNSView(context: Context) -> AudioPlaybackHostView {
        let view = AudioPlaybackHostView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: AudioPlaybackHostView, context: Context) {
        view.configure(path: path, session: playbackSessionID,
                       sourceSlot: sourceSlot, scope: outputScope, audible: audible,
                       volume: volume * liveAudioMix.effectiveProgramGain,
                       preFaderGain: preFaderGain, faderGain: faderGain,
                       loops: loops, videoEndBehavior: videoEndBehavior,
                       fadeDuration: fadeDuration)
    }

    static func dismantleNSView(_ view: AudioPlaybackHostView, coordinator: ()) {
        view.unbind()
    }
}

final class AudioPlaybackHostView: NSView {
    private let hostID = UUID()
    private var key: AudioPlaybackPool.Key?

    func configure(path: String, session: UUID, sourceSlot: String,
                   scope: String, audible: Bool,
                   volume: Double, preFaderGain: Double, faderGain: Double,
                   loops: Bool, videoEndBehavior: VideoEndBehavior?,
                   fadeDuration: Double) {
        let next = AudioPlaybackPool.Key(path: URL(fileURLWithPath: path).standardizedFileURL.path,
                                         sessionID: session, sourceSlot: sourceSlot)
        let newlyAttached = key != next
        if newlyAttached {
            unbind()
            key = next
            AudioPlaybackPool.shared.attach(next, hostID: hostID, scope: scope,
                                            loops: loops, videoEndBehavior: videoEndBehavior,
                                            fadeDuration: fadeDuration)
        }
        AudioPlaybackPool.shared.configure(next, hostID: hostID, scope: scope,
                                           audible: audible, volume: volume,
                                           preFaderGain: preFaderGain, faderGain: faderGain)
        if newlyAttached { AudioPlaybackPool.shared.resume(next, hostID: hostID) }
    }

    func unbind() {
        if let key { AudioPlaybackPool.shared.detach(key, hostID: hostID) }
        key = nil
    }
}

/// Audio is retained outside ephemeral SwiftUI slide views. Every output
/// shares one player per media take; only the active output's mix request is
/// applied. Metering and the AVPlayerLooper survive output window changes.
@MainActor
final class AudioPlaybackPool {
    struct Key: Hashable {
        let path: String
        let sessionID: UUID
        let sourceSlot: String
    }

    private struct HostMix {
        let scope: String
        let audible: Bool
        let volume: Double
        let preFaderGain: Double
        let faderGain: Double
    }

    @MainActor
    private final class Entry {
        let player: AVPlayer
        let looper: AVPlayerLooper?
        let meterID: UUID?
        var hosts: [UUID: HostMix] = [:]
        var evictionGeneration = 0
        var endFadeGain = 1.0
        var onFadeChanged: (() -> Void)?
        private var timeObserver: Any?

        init(path: String, loops: Bool, videoEndBehavior: VideoEndBehavior?,
             fadeDuration: Double) {
            let url = URL(fileURLWithPath: path)
            let item = AVPlayerItem(url: url)
            if loops {
                let queue = AVQueuePlayer()
                queue.actionAtItemEnd = .advance
                self.player = queue
                self.meterID = LiveAudioMeters.shared.attach(item: item, to: queue, scope: "program")
                self.looper = AVPlayerLooper(player: queue, templateItem: item)
            } else {
                let oneShot = AVPlayer(playerItem: item)
                oneShot.actionAtItemEnd = .pause
                self.player = oneShot
                self.meterID = LiveAudioMeters.shared.attach(item: item, to: oneShot, scope: "program")
                self.looper = nil
            }
            AudioOutputRouting.apply(to: player)
            player.isMuted = true
            player.volume = 0 // fail closed until the first configure()

            if videoEndBehavior == .fadeOut || videoEndBehavior == .fadeToBlack {
                timeObserver = player.addPeriodicTimeObserver(
                    forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
                ) { [weak self] time in
                    guard let self, time.isNumeric else { return }
                    let duration = self.player.currentItem?.duration.seconds ?? 0
                    guard duration.isFinite && duration > 0 else { return }
                    let effective = min(max(fadeDuration, 0.2), duration * 0.4)
                    let remaining = max(0, duration - time.seconds)
                    let fade = max(0, min(1, remaining / max(0.01, effective)))
                    if abs(self.endFadeGain - fade) > 0.005 {
                        self.endFadeGain = fade
                        self.onFadeChanged?()
                    }
                }
            }
        }

        func teardown() {
            if let timeObserver {
                player.removeTimeObserver(timeObserver)
                self.timeObserver = nil
            }
            player.pause()
        }
    }

    static let shared = AudioPlaybackPool()
    private var entries: [Key: Entry] = [:]
    // The show has one continuous audio bus, independent of video windows.
    private let audioOwnerScope = "program"
    private init() {}

    func attach(_ key: Key, hostID: UUID, scope: String, loops: Bool,
                videoEndBehavior: VideoEndBehavior?, fadeDuration: Double) {
        guard FileManager.default.fileExists(atPath: key.path) else { return }
        let entry: Entry
        if let existing = entries[key] {
            entry = existing
        } else {
            entry = Entry(path: key.path, loops: loops,
                          videoEndBehavior: videoEndBehavior, fadeDuration: fadeDuration)
            entry.onFadeChanged = { [weak self, weak entry] in
                guard let self, let entry else { return }
                self.applyOwnerMix(to: entry)
            }
            entries[key] = entry
        }
        entry.evictionGeneration += 1
        entry.hosts[hostID] = HostMix(scope: scope, audible: false, volume: 0,
                                      preFaderGain: 1, faderGain: 1)
        // The host resumes playback after the new audio state is installed.
    }

    func configure(_ key: Key, hostID: UUID, scope: String, audible: Bool, volume: Double,
                   preFaderGain: Double, faderGain: Double) {
        guard let entry = entries[key], entry.hosts[hostID] != nil else { return }
        entry.hosts[hostID] = HostMix(scope: scope, audible: audible, volume: volume,
                                      preFaderGain: preFaderGain, faderGain: faderGain)
        applyOwnerMix(to: entry)
    }

    private func applyOwnerMix(to entry: Entry) {
        // Transition canvases may briefly mount two hosts for the same take.
        // Use the stronger current-owner request, never an inactive scope.
        guard let mix = entry.hosts.values.filter({ $0.scope == audioOwnerScope && $0.audible })
            .max(by: { $0.volume < $1.volume }) else {
            entry.player.isMuted = true
            entry.player.volume = 0
            return
        }
        entry.player.volume = Float(max(0, min(mix.volume * entry.endFadeGain, 1)))
        entry.player.isMuted = false
        LiveAudioMeters.shared.configure(entry.meterID,
                                         preFaderGain: mix.preFaderGain, faderGain: mix.faderGain,
                                         nominalPlayerGain: mix.volume)
    }

    func resume(_ key: Key, hostID: UUID) {
        guard let entry = entries[key], entry.hosts.count == 1,
              entry.hosts[hostID] != nil else { return }
        guard !VideoPlaybackPool.shared.isPaused(path: key.path,
                                                 sessionID: key.sessionID) else { return }
        entry.player.play()
    }

    func detach(_ key: Key, hostID: UUID) {
        guard let entry = entries[key] else { return }
        entry.hosts.removeValue(forKey: hostID)
        applyOwnerMix(to: entry)
        guard entry.hosts.isEmpty else { return }
        entry.player.pause()
        entry.evictionGeneration += 1
        let current = entry.evictionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak entry] in
            guard let self, let entry, entry.hosts.isEmpty,
                  entry.evictionGeneration == current else { return }
            entry.teardown()
            LiveAudioMeters.shared.remove(entry.meterID)
            self.entries.removeValue(forKey: key)
        }
    }

    func refreshAudioRouting() {
        for entry in entries.values { AudioOutputRouting.apply(to: entry.player) }
    }

    func playbackTime(path: String, sessionID: UUID, sourceSlot: String) -> Double? {
        let key = Key(path: URL(fileURLWithPath: path).standardizedFileURL.path,
                      sessionID: sessionID, sourceSlot: sourceSlot)
        guard let entry = entries[key], !entry.hosts.isEmpty else { return nil }
        let seconds = entry.player.currentTime().seconds
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    func setPaused(_ paused: Bool, path: String, sessionID: UUID) {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        for (key, entry) in entries where key.path == canonical && key.sessionID == sessionID {
            if paused { entry.player.pause() }
            else if !entry.hosts.isEmpty { entry.player.play() }
        }
    }

    func seek(to seconds: Double, path: String, sessionID: UUID) {
        guard seconds.isFinite && seconds >= 0 else { return }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        for (key, entry) in entries where key.path == canonical && key.sessionID == sessionID {
            entry.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }
}

/// One long-lived sound-only view, mounted by the operator scene rather than
/// any slide canvas. Output window lifecycle and preview FPS changes cannot
/// dispose its AVPlayers or PCM meter taps.
@MainActor
struct ProgramAudioBusView: View {
    @ObservedObject var controller: ShowController

    private func cues(at date: Date) -> [ProgramAudioCue] {
        if let transition = controller.activeTransition {
            let p = transition.progress(at: date)
            let gains: (Double, Double)
            switch transition.style {
            case .cut: gains = (0, 1)
            case .dissolve: gains = (1 - p, p)
            case .fadeThroughBlack: gains = (max(0, 1 - 2 * p), max(0, 2 * p - 1))
            }
            let before = transition.from.isBlackout || transition.from.isCleared ? [] :
                ProgramAudioCuePlan.cues(slide: transition.from.slide,
                                         sessions: transition.from.videoSessions,
                                         transitionGain: gains.0)
            let after = transition.to.isBlackout || transition.to.isCleared ? [] :
                ProgramAudioCuePlan.cues(slide: transition.to.slide,
                                         sessions: transition.to.videoSessions,
                                         transitionGain: gains.1)
            return ProgramAudioCuePlan.merged(before + after)
        }
        guard !controller.isBlackout && !controller.isCleared else { return [] }
        return ProgramAudioCuePlan.cues(slide: controller.liveSlide,
                                        sessions: controller.liveVideoSessions)
    }

    var body: some View {
        TimelineView(.animation(paused: controller.activeTransition == nil)) { timeline in
            ZStack {
                ForEach(cues(at: timeline.date)) { cue in
                    AudioPlaybackSurface(path: cue.path, playbackSessionID: cue.sessionID,
                                         sourceSlot: cue.sourceSlot, outputScope: "program",
                                         audible: true, volume: cue.volume,
                                         loops: cue.loops,
                                         videoEndBehavior: cue.videoEndBehavior,
                                         fadeDuration: cue.fadeDuration,
                                         preFaderGain: cue.preFaderGain,
                                         faderGain: cue.faderGain)
                        .frame(width: 1, height: 1)
                }
            }
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
        }
    }
}
