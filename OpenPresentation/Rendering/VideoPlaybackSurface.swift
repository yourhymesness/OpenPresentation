import AppKit
import AVFoundation
import SwiftUI
import CoreImage
import CoreVideo

/// A SwiftUI video view is disposable. Its AVPlayer must NOT be: a slide
/// dissolve constructs a temporary incoming canvas and then removes it.
/// Without a retained player, the outgoing/incoming handoff starts video and
/// audio twice (once during the transition and again at completion).
///
/// Video playback is retained per output surface and asset path. A short idle
/// grace period lets a replacement slide claim the same playback clock.
struct VideoPlaybackSurface: NSViewRepresentable {
    @ObservedObject var liveAudioMix = LiveAudioMix.shared
    let path: String
    let playbackSessionID: UUID
    var behavior: VideoEndBehavior = .loop
    var fadeDuration: Double = 0.75
    var audioEnabled: Bool = false
    var volume: Double = 1.0
    var contentMode: LayerContentMode = .fill
    /// Audience and operator monitor have separate decoders. Only Audience
    /// can emit audio, regardless of the checkbox stored in the slide.
    var outputScope: String = "program"
    var sourceSlot: String = "background"
    /// Slide-transition mix level; 1 means unchanged audio.
    var audioGain: Double = 1.0
    var preFaderGain: Double = 1.0
    var faderGain: Double = 1.0

    func makeNSView(context: Context) -> VideoPlaybackHostView {
        let view = VideoPlaybackHostView(frame: .zero)
        view.configure(path: path, session: playbackSessionID, scope: outputScope, sourceSlot: sourceSlot,
                       behavior: behavior, fadeDuration: fadeDuration,
                       audioEnabled: audioEnabled,
                       volume: volume * audioGain * liveAudioMix.effectiveProgramGain,
                       preFaderGain: preFaderGain, faderGain: faderGain,
                       contentMode: contentMode)
        return view
    }

    func updateNSView(_ view: VideoPlaybackHostView, context: Context) {
        view.configure(path: path, session: playbackSessionID, scope: outputScope, sourceSlot: sourceSlot,
                       behavior: behavior, fadeDuration: fadeDuration,
                       audioEnabled: audioEnabled,
                       volume: volume * audioGain * liveAudioMix.effectiveProgramGain,
                       preFaderGain: preFaderGain, faderGain: faderGain,
                       contentMode: contentMode)
    }

    static func dismantleNSView(_ view: VideoPlaybackHostView, coordinator: ()) {
        // Never stop the decoder here. SwiftUI can dismantle the incoming
        // transition canvas while the very same asset is still on Program.
        view.unbind()
    }
}

/// A host is owned by SwiftUI and may be destroyed between slide takes. It
/// temporarily mounts a retained engine view owned by VideoPlaybackPool.
/// Reparenting the SAME AppKit view keeps the existing AVPlayerLayers, queue,
/// playhead and audio stream; there is no seek-to-zero on a same-media take.
final class VideoPlaybackHostView: NSView {
    private var engine: VideoPlaybackNSView?
    private var key: VideoPlaybackPool.Key?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    func configure(path: String, session: UUID, scope: String, sourceSlot: String, behavior: VideoEndBehavior,
                   fadeDuration: Double, audioEnabled: Bool, volume: Double,
                   preFaderGain: Double, faderGain: Double,
                   contentMode: LayerContentMode) {
        let newKey = VideoPlaybackPool.Key(path: URL(fileURLWithPath: path).standardizedFileURL.path,
                                           scope: scope, sessionID: session, sourceSlot: sourceSlot)
        let newlyMounted = key != newKey || engine == nil
        if newlyMounted {
            unbind()
            let retained = VideoPlaybackPool.shared.engine(for: newKey)
            engine = retained
            key = newKey
            // If a dissolve still has two canvas instances, only the newer
            // host displays video. AVPlayer has one active AVPlayerLayer tree.
            addSubview(retained)
            retained.frame = bounds
            retained.autoresizingMask = [.width, .height]
        }
        // An outgoing canvas sometimes receives another SwiftUI update AFTER
        // its view has been reparented to the incoming canvas. Ignore that
        // stale host rather than stealing the video view back.
        guard let engine, engine.superview === self else { return }
        engine.configure(path: newKey.path, behavior: behavior,
                         fadeDuration: fadeDuration, audioEnabled: audioEnabled,
                         volume: volume, preFaderGain: preFaderGain,
                         faderGain: faderGain, contentMode: contentMode,
                         meterScope: scope)
        // A cached audible player must not restart before the new mute state.
        if newlyMounted { VideoPlaybackPool.shared.didAttach(engine, key: newKey) }
        VideoPlaybackPool.shared.applyTransportIntent(to: engine, key: newKey)
        if newlyMounted { VideoPlaybackPool.shared.alignNewSurface(engine, key: newKey) }
    }

    override func layout() {
        super.layout()
        if engine?.superview === self { engine?.frame = bounds }
    }

    func unbind() {
        if let engine, let key, engine.superview === self {
            engine.removeFromSuperview()
            VideoPlaybackPool.shared.didDetach(engine, key: key)
        }
        engine = nil
        key = nil
    }
}

/// Keeps each media decoder alive across changes in the SwiftUI view tree.
/// Separate audience/operator scopes avoid double audio and competing layers.
/// A detached decoder pauses immediately; a same-media slide can resume it
/// without resetting its playhead during the brief handoff window.
final class VideoPlaybackPool {
    struct Key: Hashable {
        let path: String
        let scope: String
        let sessionID: UUID
        let sourceSlot: String
        init(path: String, scope: String, sessionID: UUID, sourceSlot: String = "background") {
            self.path = path
            self.scope = scope
            self.sessionID = sessionID
            self.sourceSlot = sourceSlot
        }
    }

    static let shared = VideoPlaybackPool()

    /// Playback commands are shared between the muted Program monitor and the
    /// audible audience output, but are never inherited by another take ID.
    private struct SessionKey: Hashable {
        let path: String
        let sessionID: UUID
    }

    private struct Intent {
        var paused = false
        var seekSeconds: Double? = nil
        var seekRevision = 0
    }

    struct TransportStatus {
        let elapsed: Double
        let duration: Double?
        let isPlaying: Bool
    }

    private var transportIntents: [SessionKey: Intent] = [:]

    private final class Entry {
        let engine: VideoPlaybackNSView
        var generation = 0
        init(engine: VideoPlaybackNSView) { self.engine = engine }
    }

    private var entries: [Key: Entry] = [:]
    private var lastDriftCorrection: [Key: Date] = [:]
    private init() {}

    /// Sample an active audience video engine only; never allocate a new
    /// decoder or seek the audience player for Program preview frames.
    func previewPixelBuffer(path: String, sessionID: UUID, sourceSlot: String) -> CVPixelBuffer? {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        for scope in ["fullscreen", "windowed"] {
            let key = Key(path: canonical, scope: scope,
                          sessionID: sessionID, sourceSlot: sourceSlot)
            guard let engine = entries[key]?.engine,
                  engine.superview != nil, engine.isConfigured else { continue }
            if let buffer = engine.copySharedPreviewPixelBuffer() { return buffer }
        }
        return nil
    }

    func engine(for key: Key) -> VideoPlaybackNSView {
        if let entry = entries[key] { return entry.engine }
        let engine = VideoPlaybackNSView(frame: .zero)
        #if DEBUG
        print("[OpenPresentation Video] New decoder: \(key.scope) · \(URL(fileURLWithPath: key.path).lastPathComponent) · take \(key.sessionID.uuidString.prefix(8))")
        #endif
        entries[key] = Entry(engine: engine)
        return engine
    }

    /// Apply an Audio Settings change to already playing decoders, without
    /// constructing new players or resetting their playheads.
    func refreshAudioRouting() {
        for (_, entry) in entries {
            entry.engine.refreshAudioRouting()
        }
    }

    func transportStatus(path: String, sessionID: UUID) -> TransportStatus? {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        // Prefer the audience player if present; otherwise the operator
        // monitor's muted decoder remains fully controllable for testing.
        let candidates = [Key(path: canonical, scope: "fullscreen", sessionID: sessionID),
                          Key(path: canonical, scope: "windowed", sessionID: sessionID),
                          Key(path: canonical, scope: "program", sessionID: sessionID)]
        for key in candidates {
            // Prefer background, otherwise the first visible occurrence of
            // this file. Distinct occurrences now have independent players.
            if let found = entries.first(where: { $0.key.path == key.path &&
                $0.key.scope == key.scope && $0.key.sessionID == key.sessionID &&
                $0.value.engine.isConfigured && $0.value.engine.superview != nil }) {
                return found.value.engine.transportStatus
            }
        }
        return nil
    }

    /// The operator's Play/Pause state is an explicit user intent, NOT the
    /// instantaneous AVPlayer.rate. Rate can be zero while loading, seeking,
    /// reaching a loop boundary, or waiting for a buffer even though the user
    /// never asked the video to pause.
    func isPaused(path: String, sessionID: UUID) -> Bool {
        let key = SessionKey(path: URL(fileURLWithPath: path).standardizedFileURL.path,
                             sessionID: sessionID)
        return transportIntents[key]?.paused ?? false
    }

    /// Toggle the retained session intent first, then apply it to every video
    /// surface (operator and audience). A player that mounts later receives the
    /// same intent via applyTransportIntent, including during a dissolve.
    @discardableResult
    func togglePaused(path: String, sessionID: UUID) -> Bool {
        let paused = !isPaused(path: path, sessionID: sessionID)
        setPaused(paused, path: path, sessionID: sessionID)
        #if DEBUG
        print("[OpenPresentation Video] Transport: \(paused ? "PAUSE" : "PLAY") · \(URL(fileURLWithPath: path).lastPathComponent) · take \(sessionID.uuidString.prefix(8))")
        #endif
        return paused
    }

    func setPaused(_ paused: Bool, path: String, sessionID: UUID) {
        let k = SessionKey(path: URL(fileURLWithPath: path).standardizedFileURL.path,
                           sessionID: sessionID)
        var intent = transportIntents[k] ?? Intent()
        intent.paused = paused
        transportIntents[k] = intent
        for (key, entry) in entries where key.path == k.path && key.sessionID == sessionID {
            entry.engine.setUserPaused(paused, explicitCommand: true)
        }
    }

    func seek(to seconds: Double, path: String, sessionID: UUID) {
        guard seconds.isFinite, seconds >= 0 else { return }
        let k = SessionKey(path: URL(fileURLWithPath: path).standardizedFileURL.path,
                           sessionID: sessionID)
        var intent = transportIntents[k] ?? Intent()
        intent.seekSeconds = seconds
        intent.seekRevision += 1
        transportIntents[k] = intent
        for (key, entry) in entries where key.path == k.path && key.sessionID == sessionID {
            entry.engine.applySeek(seconds, revision: intent.seekRevision)
        }
    }

    func applyTransportIntent(to engine: VideoPlaybackNSView, key: Key) {
        let k = SessionKey(path: key.path, sessionID: key.sessionID)
        guard let intent = transportIntents[k] else { return }
        if let seconds = intent.seekSeconds {
            engine.applySeek(seconds, revision: intent.seekRevision)
        }
        engine.setUserPaused(intent.paused)
    }

    /// Synchronize a newly opened window to an existing session's current
    /// position, instead of replaying its first half second on mount.
    func alignNewSurface(_ engine: VideoPlaybackNSView, key: Key) {
        let master = activeMaster(for: key)
        guard let master else { return }
        let elapsed = master.transportStatus.elapsed
        if elapsed > 0.08 { engine.alignPlayback(to: elapsed) }
    }

    private func activeMaster(for key: Key) -> VideoPlaybackNSView? {
        let preferred = ["fullscreen", "windowed", "program"]
        for scope in preferred where scope != key.scope {
            let otherKey = Key(path: key.path, scope: scope, sessionID: key.sessionID, sourceSlot: key.sourceSlot)
            if let other = entries[otherKey]?.engine, other.superview != nil, other.isConfigured {
                return other
            }
        }
        return nil
    }

    /// Only a lower-priority surface may follow a higher-priority one.
    /// Windowed Output must NEVER seek backwards to a slower Program monitor.
    /// Repeated seeks during a heavy show can keep multiple decoders busy.
    func correctActiveOutputDrift() {
        let now = Date()
        for (key, entry) in entries where entry.engine.superview != nil {
            let candidates = entries.filter { otherKey, other in
                otherKey.path == key.path &&
                otherKey.sessionID == key.sessionID &&
                otherKey.sourceSlot == key.sourceSlot &&
                VideoPlaybackWorkload.rank(otherKey.scope) >
                    VideoPlaybackWorkload.rank(key.scope) &&
                other.engine.superview != nil && other.engine.isConfigured
            }
            guard let leader = candidates.max(by: {
                VideoPlaybackWorkload.rank($0.key.scope) <
                VideoPlaybackWorkload.rank($1.key.scope)
            })?.value.engine else { continue }
            let targetStatus = leader.transportStatus
            let currentStatus = entry.engine.transportStatus
            let sinceLast = now.timeIntervalSince(lastDriftCorrection[key] ?? .distantPast)
            guard VideoPlaybackWorkload.shouldCorrect(
                follower: key.scope,
                leader: candidates.first(where: { $0.value.engine === leader })!.key.scope,
                difference: targetStatus.elapsed - currentStatus.elapsed,
                elapsed: sinceLast,
                bothPlaying: targetStatus.isPlaying && currentStatus.isPlaying)
            else { continue }
            entry.engine.alignPlayback(to: targetStatus.elapsed)
            lastDriftCorrection[key] = now
        }
    }

    func didAttach(_ engine: VideoPlaybackNSView, key: Key) {
        guard let entry = entries[key], entry.engine === engine else { return }
        entry.generation += 1 // cancel a pending eviction
        engine.resumeIfSuspended()
    }

    func didDetach(_ engine: VideoPlaybackNSView, key: Key) {
        guard let entry = entries[key], entry.engine === engine else { return }
        // When a media clip leaves Program, stop its audio immediately. Do
        // not dispose the decoder yet: a new incoming host may claim it.
        engine.suspend()
        entry.generation += 1
        let generation = entry.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak engine] in
            guard let self, let engine, let latest = self.entries[key],
                  latest.engine === engine, latest.generation == generation,
                  engine.superview == nil else { return }
            engine.stop()
            #if DEBUG
            print("[OpenPresentation Video] Released decoder: \(URL(fileURLWithPath: key.path).lastPathComponent)")
            #endif
            self.entries.removeValue(forKey: key)
            self.lastDriftCorrection.removeValue(forKey: key)
            let session = SessionKey(path: key.path, sessionID: key.sessionID)
            if !self.entries.keys.contains(where: { $0.path == session.path && $0.sessionID == session.sessionID }) {
                self.transportIntents.removeValue(forKey: session)
            }
        }
    }
}

/// Video end behavior engine. Uses AVPlayerLayer/Core Animation, not custom Metal.
/// Soft Loop uses two players and overlapping alpha/audio fades. Video duration
/// is read from AVPlayerItem once available; a short/invalid file falls back to
/// replay rather than assuming a duration and risking an out-of-bounds time.
final class VideoPlaybackNSView: NSView {
    private let videoA = AVPlayerLayer()
    private let videoB = AVPlayerLayer()
    private let blackOverlay = CALayer()

    private var pathInUse: String?
    private var endBehavior: VideoEndBehavior = .loop
    private var fadeSeconds: Double = 0.75
    private var audioIsEnabled = false
    private var baseVolume: Float = 1
    private var meterPrimaryID: UUID?
    private var meterStandbyID: UUID?
    private var meterPreFaderGain: Double = 1
    private var meterFaderGain: Double = 1
    private var meterNominalVolume: Double = 1
    private var audibleVolume: Float { audioIsEnabled ? baseVolume : 0 }
    private var meterScope: String = "program"
    private func updateVideoAudioTracks() {
        for player in [primary, standby].compactMap({ $0 }) {
            let items: [AVPlayerItem] = (player as? AVQueuePlayer)?.items()
                ?? (player.currentItem.map { [$0] } ?? [])
            for item in items {
                for track in item.tracks where track.assetTrack?.mediaType == .audio {
                    if track.isEnabled != audioIsEnabled {
                        track.isEnabled = audioIsEnabled
                    }
                }
            }
        }
    }

    private func attachMeterIfNeeded() {
        guard VideoPlaybackWorkload.shouldMeter(scope: meterScope, audible: audioIsEnabled)
        else { return }
        if meterPrimaryID == nil, let player = primary, let item = player.currentItem {
            meterPrimaryID = LiveAudioMeters.shared.attach(item: item, to: player, scope: meterScope)
        }
        if meterStandbyID == nil, let player = standby, let item = player.currentItem {
            meterStandbyID = LiveAudioMeters.shared.attach(item: item, to: player, scope: meterScope)
        }
        updateMeterParameters()
    }


    private var loopQueue: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var primary: AVPlayer?
    private var standby: AVPlayer?
    private var primaryIsA = true
    private var blendStarted = false
    private var timeObserverToken: Any?
    private weak var timeObserverPlayer: AVPlayer?
    private var endNotification: NSObjectProtocol?
    private weak var previewAttachedItem: AVPlayerItem?
    private var previewVideoOutput: AVPlayerItemVideoOutput?
    private var lastKnownDuration = 0.0
    private var userPaused = false
    private var lastAppliedSeekRevision = -1

    var isConfigured: Bool { primary != nil }
    var transportStatus: VideoPlaybackPool.TransportStatus {
        let rawElapsed = primary?.currentTime().seconds ?? 0
        let elapsed = rawElapsed.isFinite && rawElapsed >= 0 ? rawElapsed : 0
        let rawDuration = primary?.currentItem?.duration.seconds ?? lastKnownDuration
        let duration = rawDuration.isFinite && rawDuration > 0 ? rawDuration : nil
        return .init(elapsed: elapsed, duration: duration,
                     isPlaying: !userPaused && !suspended && (primary?.rate ?? 0) > 0)
    }

    func setUserPaused(_ paused: Bool, explicitCommand: Bool = false) {
        // Explicit Play at the end of a one-shot clip can restart it, but
        // routine SwiftUI configure updates must never do so automatically.
        let alreadyAtRequestedState = userPaused == paused
        userPaused = paused
        if paused {
            // Reassert pause when a view reconfigures or a decoder remounts.
            // Calling pause() repeatedly is safe; returning early could leave
            // an AVQueuePlayer running after a buffering/loop boundary.
            primary?.pause()
            standby?.pause()
            return
        } else if !suspended {
            // A normal repeated unpaused configuration must not call play()
            // continuously; it would otherwise disrupt buffering and fades.
            if alreadyAtRequestedState && !explicitCommand { return }
            let endedOneShot: Bool = {
                guard endBehavior != .loop && endBehavior != .softLoop,
                      let player = primary,
                      let duration = player.currentItem?.duration.seconds,
                      duration.isFinite && duration > 0 else { return false }
                return player.currentTime().seconds >= duration - 0.08
            }()
            if alreadyAtRequestedState && !endedOneShot { return }
            if endedOneShot { seek(to: 0) }
            primary?.play()
            if blendStarted { standby?.play() }
        }
    }

    /// Internal decoder alignment. Does not alter the user's shared seek
    /// intent; transport commands still apply to every output together.
    func alignPlayback(to seconds: Double) {
        guard isConfigured, seconds.isFinite, seconds >= 0 else { return }
        let current = transportStatus.elapsed
        guard abs(current - seconds) > 0.12 else { return }
        seek(to: seconds)
    }

    func applySeek(_ seconds: Double, revision: Int) {
        guard isConfigured, lastAppliedSeekRevision != revision else { return }
        lastAppliedSeekRevision = revision
        seek(to: seconds)
    }

    private func seek(to seconds: Double) {
        guard let player = primary else { return }
        let rawDuration = player.currentItem?.duration.seconds ?? lastKnownDuration
        let lastTime = rawDuration.isFinite && rawDuration > 0 ? max(0, rawDuration - 0.05) : seconds
        let clipped = min(max(0, seconds), lastTime)
        // Scrubbing breaks a soft-loop dissolve and cancels end-of-file fades.
        standby?.pause()
        standby?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        blendStarted = false
        setAlphas(primary: 1, standby: 0, black: 0)
        player.volume = audibleVolume
        standby?.volume = 0
        let target = CMTime(seconds: clipped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        if !userPaused && !suspended { player.play() }
    }

    override func makeBackingLayer() -> CALayer { CALayer() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installLayers()
    }

    private func installLayers() {
        wantsLayer = true
        layer?.masksToBounds = true
        // Alpha-bearing HEVC and ProRes must composite over lower slide layers.
        // Transparent video frames must not be replaced with opaque black.
        videoA.isOpaque = false
        videoB.isOpaque = false
        videoA.backgroundColor = NSColor.clear.cgColor
        videoB.backgroundColor = NSColor.clear.cgColor
        videoA.opacity = 1
        videoB.opacity = 0
        blackOverlay.backgroundColor = NSColor.black.cgColor
        blackOverlay.opacity = 0
        layer?.addSublayer(videoA)
        layer?.addSublayer(videoB)
        layer?.addSublayer(blackOverlay)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for videoLayer in [videoA, videoB, blackOverlay] {
            videoLayer.frame = bounds
        }
        CATransaction.commit()
    }

    private var foreground: AVPlayerLayer { primaryIsA ? videoA : videoB }
    private var background: AVPlayerLayer { primaryIsA ? videoB : videoA }

    func configure(path: String, behavior: VideoEndBehavior, fadeDuration: Double,
                   audioEnabled: Bool, volume: Double, preFaderGain: Double,
                   faderGain: Double, contentMode: LayerContentMode, meterScope: String) {
        let gravity: AVLayerVideoGravity
        switch contentMode {
        case .fit: gravity = .resizeAspect
        case .fill: gravity = .resizeAspectFill
        case .stretch: gravity = .resize
        }
        videoA.videoGravity = gravity
        videoB.videoGravity = gravity
        let adjustedFade = min(max(fadeDuration, 0.2), 3.0)
        let adjustedVolume = Float(min(max(volume, 0), 1))

        let requiresRestart = pathInUse != path || endBehavior != behavior || primary == nil
        fadeSeconds = adjustedFade
        audioIsEnabled = audioEnabled
        baseVolume = adjustedVolume
        meterPreFaderGain = preFaderGain
        meterFaderGain = faderGain
        meterNominalVolume = volume
        self.meterScope = meterScope
        updateMeterParameters()
        if !requiresRestart {
            // Update mix without restarting/rewinding a player. A source that
            // is already in its end fade or soft-loop crossfade must retain
            // its per-frame envelope until the periodic observer refreshes it.
            primary?.isMuted = !audioIsEnabled
            standby?.isMuted = !audioIsEnabled
            updateVideoAudioTracks()
            if audioIsEnabled { attachMeterIfNeeded() }
            if behavior == .loop || behavior == .holdLastFrame {
                primary?.volume = audibleVolume
            }
            if behavior == .softLoop && !blendStarted {
                primary?.volume = audibleVolume
                standby?.volume = 0
            }
            return
        }

        stop()
        guard FileManager.default.fileExists(atPath: path) else { return }
        pathInUse = path
        endBehavior = behavior
        primaryIsA = true
        setAlphas(primary: 1, standby: 0, black: 0)
        let url = URL(fileURLWithPath: path)

        if behavior == .loop {
            let queue = AVQueuePlayer()
            AudioOutputRouting.apply(to: queue)
            queue.actionAtItemEnd = .advance
            queue.isMuted = !audioIsEnabled
            queue.volume = audibleVolume
            let item = AVPlayerItem(url: url)
            meterPrimaryID = VideoPlaybackWorkload.shouldMeter(scope: meterScope, audible: audioIsEnabled)
                ? LiveAudioMeters.shared.attach(item: item, to: queue, scope: meterScope) : nil
            updateMeterParameters()
            looper = AVPlayerLooper(player: queue, templateItem: item)
            loopQueue = queue
            primary = queue
            videoA.player = queue
            updateVideoAudioTracks()
            queue.play()
            return
        }

        let (player, primaryMeter) = makePlayer(url: url)
        meterPrimaryID = primaryMeter
        player.actionAtItemEnd = .pause
        primary = player
        videoA.player = player
        if behavior == .softLoop {
            // Keep another decoder ready at frame zero for the overlapping
            // dissolve into the beginning of the same source video.
            let (alternate, standbyMeter) = makePlayer(url: url)
            meterStandbyID = standbyMeter
            alternate.actionAtItemEnd = .pause
            alternate.volume = 0
            standby = alternate
            videoB.player = alternate
        }
        updateMeterParameters()
        updateVideoAudioTracks()
        observePrimary(player)
        player.play()
    }

    /// Return an acquired decoded buffer from the live audience AVPlayerItem.
    /// CI downscaling is dispatched to a serial render queue so large slides
    /// never perform repeated GPU readback on the operator's main thread.
    func copySharedPreviewPixelBuffer() -> CVPixelBuffer? {
        guard !suspended, let item = primary?.currentItem else { return nil }
        if previewAttachedItem !== item || previewVideoOutput == nil {
            releaseSharedPreviewOutput()
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ])
            item.add(output)
            previewAttachedItem = item
            previewVideoOutput = output
        }
        guard let output = previewVideoOutput else { return nil }
        let time = item.currentTime()
        guard time.isNumeric, output.hasNewPixelBuffer(forItemTime: time) else {
            return nil
        }
        return output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
    }

    private func releaseSharedPreviewOutput() {
        if let attached = previewAttachedItem, let output = previewVideoOutput {
            attached.remove(output)
        }
        previewAttachedItem = nil
        previewVideoOutput = nil
    }

    func refreshAudioRouting() {
        if let primary { AudioOutputRouting.apply(to: primary) }
        if let standby { AudioOutputRouting.apply(to: standby) }
    }

    private func makePlayer(url: URL) -> (AVPlayer, UUID?) {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let meter = VideoPlaybackWorkload.shouldMeter(scope: meterScope, audible: audioIsEnabled)
            ? LiveAudioMeters.shared.attach(item: item, to: player, scope: meterScope) : nil
        AudioOutputRouting.apply(to: player)
        player.isMuted = !audioIsEnabled
        player.volume = audibleVolume
        return (player, meter)
    }

    /// Tap values are measured before AVPlayer volume. These nominal gains
    /// let the mixer account for per-slide gain and master gain. AVPlayer's
    /// current volume is also inspected to follow video end fades/soft loops.
    private func updateMeterParameters() {
        LiveAudioMeters.shared.configure(meterPrimaryID,
                                         preFaderGain: meterPreFaderGain,
                                         faderGain: meterFaderGain,
                                         nominalPlayerGain: meterNominalVolume)
        LiveAudioMeters.shared.configure(meterStandbyID,
                                         preFaderGain: meterPreFaderGain,
                                         faderGain: meterFaderGain,
                                         nominalPlayerGain: meterNominalVolume)
    }

    /// Call only on main; both AVPlayer's periodic handler and end notification
    /// are registered for the main queue. Always unhook before changing players.
    private func observePrimary(_ player: AVPlayer) {
        cancelObservers()
        timeObserverPlayer = player
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: VideoPlaybackWorkload.observerInterval(meterScope),
                                preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] time in
            guard let self, let player, self.primary === player else { return }
            self.updatePlayback(at: time)
        }
        if let item = player.currentItem {
            endNotification = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self, weak player] _ in
                guard let self, let player, self.primary === player else { return }
                if self.endBehavior == .softLoop {
                    self.rotateSoftLoop()
                } else if self.endBehavior == .fadeOut {
                    self.setAlphas(primary: 0, standby: 0, black: 0)
                } else if self.endBehavior == .fadeToBlack {
                    self.setAlphas(primary: 1, standby: 0, black: 1)
                }
                // Hold Last Frame intentionally does nothing: the player is
                // paused with its item still attached to AVPlayerLayer.
            }
        }
    }

    private func cancelObservers() {
        if let token = timeObserverToken, let observing = timeObserverPlayer {
            observing.removeTimeObserver(token)
        }
        timeObserverToken = nil
        timeObserverPlayer = nil
        if let observer = endNotification {
            NotificationCenter.default.removeObserver(observer)
        }
        endNotification = nil
    }

    private func updatePlayback(at time: CMTime) {
        // A delayed periodic callback can still arrive after Pause. It must
        // never start the standby player for a soft loop or advance a fade.
        guard !userPaused && !suspended,
              let player = primary,
              time.isNumeric else { return }
        let elapsed = time.seconds
        guard elapsed.isFinite, elapsed >= 0 else { return }
        // Item tracks may only become available after playback starts.
        // Reapply until AVFoundation exposes the audio track list.
        if !audioIsEnabled { updateVideoAudioTracks() }
        let reportedDuration = player.currentItem?.duration.seconds ?? 0
        let duration = reportedDuration.isFinite && reportedDuration > 0
            ? reportedDuration : lastKnownDuration
        guard duration.isFinite, duration > 0.05 else { return }
        lastKnownDuration = duration
        let remaining = max(0, duration - elapsed)
        let effectiveFade = min(fadeSeconds, duration * 0.40)
        let progress = min(max((effectiveFade - remaining) / max(effectiveFade, 0.01), 0), 1)

        switch endBehavior {
        case .loop, .holdLastFrame:
            break
        case .fadeOut:
            setAlphas(primary: Float(1 - progress), standby: 0, black: 0)
            primary?.volume = audibleVolume * Float(1 - progress)
        case .fadeToBlack:
            setAlphas(primary: 1, standby: 0, black: Float(progress))
            primary?.volume = audibleVolume * Float(1 - progress)
        case .softLoop:
            if remaining <= effectiveFade && !blendStarted {
                blendStarted = true
                standby?.isMuted = !audioIsEnabled
                standby?.volume = 0
                standby?.play()
            }
            if blendStarted {
                setAlphas(primary: Float(1 - progress), standby: Float(progress), black: 0)
                primary?.volume = audibleVolume * Float(1 - progress)
                standby?.volume = audibleVolume * Float(progress)
            }
            // Periodic callbacks need not fire exactly at the endpoint. The
            // AVPlayerItem end notification also serves as a fallback.
            if remaining < 0.05 && blendStarted { rotateSoftLoop() }
        }
    }

    private func rotateSoftLoop() {
        guard endBehavior == .softLoop,
              let outgoing = primary, let incoming = standby else { return }
        // If the clip was too short for an overlap, start the standby now.
        if !blendStarted && !userPaused && !suspended { incoming.play() }
        cancelObservers()
        outgoing.pause()
        outgoing.volume = 0
        outgoing.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        primary = incoming
        standby = outgoing
        swap(&meterPrimaryID, &meterStandbyID)
        primaryIsA.toggle()
        blendStarted = false
        setAlphas(primary: 1, standby: 0, black: 0)
        incoming.volume = audibleVolume
        incoming.isMuted = !audioIsEnabled
        updateVideoAudioTracks()
        // Keep the just-rewound former primary preloaded for next time.
        lastKnownDuration = 0
        observePrimary(incoming)
    }

    private func setAlphas(primary alpha: Float, standby beta: Float, black: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        foreground.opacity = alpha
        background.opacity = beta
        blackOverlay.opacity = black
        CATransaction.commit()
    }

    private var suspended = false

    func suspend() {
        guard !suspended else { return }
        suspended = true
        primary?.pause()
        standby?.pause()
    }

    func resumeIfSuspended() {
        guard suspended else { return }
        suspended = false
        // Ended one-shot clips must remain on their last/faded frame.
        if endBehavior != .loop && endBehavior != .softLoop,
           let item = primary?.currentItem {
            let duration = item.duration.seconds
            let current = item.currentTime().seconds
            if duration.isFinite && duration > 0 && current.isFinite &&
                current >= duration - 0.08 { return }
        }
        guard !userPaused else { return }
        primary?.play()
        if blendStarted { standby?.play() }
    }

    func stop() {
        releaseSharedPreviewOutput()
        suspended = false
        userPaused = false
        lastAppliedSeekRevision = -1
        cancelObservers()
        loopQueue?.pause()
        primary?.pause()
        standby?.pause()
        videoA.player = nil
        videoB.player = nil
        LiveAudioMeters.shared.remove(meterPrimaryID)
        LiveAudioMeters.shared.remove(meterStandbyID)
        meterPrimaryID = nil
        meterStandbyID = nil
        looper = nil
        loopQueue?.removeAllItems()
        loopQueue = nil
        primary = nil
        standby = nil
        pathInUse = nil
        blendStarted = false
        lastKnownDuration = 0
        primaryIsA = true
        setAlphas(primary: 1, standby: 0, black: 0)
    }

    deinit {
        // SwiftUI calls dismantleNSView before release, which clears all
        // AVPlayer observation tokens. Do not remove a KVO-style observer here
        // from an arbitrary deallocation context.
        primary?.pause()
        standby?.pause()
    }
}


/// Moving 12 FPS preview backed by real audience-decoded video frames.
/// Neither this view nor its hub creates an AVPlayer.
struct SharedVideoPreviewSurface: NSViewRepresentable {
    let path: String
    let playbackSessionID: UUID
    let sourceSlot: String
    let contentMode: LayerContentMode

    func makeNSView(context: Context) -> SharedVideoSnapshotView {
        let view = SharedVideoSnapshotView(frame: .zero)
        view.configure(path: path, sessionID: playbackSessionID,
                       sourceSlot: sourceSlot, mode: contentMode)
        return view
    }

    func updateNSView(_ view: SharedVideoSnapshotView, context: Context) {
        view.configure(path: path, sessionID: playbackSessionID,
                       sourceSlot: sourceSlot, mode: contentMode)
    }

    static func dismantleNSView(_ view: SharedVideoSnapshotView, coordinator: ()) {
        view.unsubscribe()
    }
}

private struct SharedVideoStreamKey: Hashable {
    let path: String
    let sessionID: UUID
    let sourceSlot: String
}

final class SharedVideoSnapshotView: NSView {
    fileprivate let identity = UUID()
    fileprivate private(set) var streamKey: SharedVideoStreamKey?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
    }

    func configure(path: String, sessionID: UUID,
                   sourceSlot: String, mode: LayerContentMode) {
        switch mode {
        case .fit: layer?.contentsGravity = .resizeAspect
        case .fill: layer?.contentsGravity = .resizeAspectFill
        case .stretch: layer?.contentsGravity = .resize
        }
        let key = SharedVideoStreamKey(
            path: URL(fileURLWithPath: path).standardizedFileURL.path,
            sessionID: sessionID, sourceSlot: sourceSlot)
        guard streamKey != key else { return }
        unsubscribe()
        streamKey = key
        layer?.contents = nil
        SharedVideoPreviewHub.shared.subscribe(self)
    }

    fileprivate func present(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }

    func unsubscribe() {
        SharedVideoPreviewHub.shared.unsubscribe(identity)
        streamKey = nil
        layer?.contents = nil
    }
}

/// One 12 Hz timer across all visible Program surfaces; each unique stream
/// sampled once per tick. Direct CALayer updates avoid invalidating SwiftUI.
private final class SharedVideoPreviewHub {
    static let shared = SharedVideoPreviewHub()
    static let context = CIContext(options: [.cacheIntermediates: false])

    private final class WeakView {
        weak var view: SharedVideoSnapshotView?
        init(_ view: SharedVideoSnapshotView) { self.view = view }
    }
    private var previews: [UUID: WeakView] = [:]
    private var timer: Timer?
    private var conversionInFlight = false
    private let conversionQueue = DispatchQueue(
        label: "com.openpresentation.shared-preview-frames",
        qos: .userInitiated)
    private init() {}

    func subscribe(_ view: SharedVideoSnapshotView) {
        previews[view.identity] = WeakView(view)
        if timer == nil {
            let newTimer = Timer(timeInterval: 1 / SharedVideoPreviewPolicy.framesPerSecond,
                                 repeats: true) { [weak self] _ in self?.sample() }
            newTimer.tolerance = 0.01
            RunLoop.main.add(newTimer, forMode: .common)
            timer = newTimer
        }
    }

    func unsubscribe(_ id: UUID) {
        previews.removeValue(forKey: id)
        if previews.isEmpty { timer?.invalidate(); timer = nil }
    }

    private func sample() {
        previews = previews.filter { $0.value.view?.streamKey != nil }
        guard !previews.isEmpty else {
            timer?.invalidate()
            timer = nil
            return
        }
        // When conversion takes longer than 83 ms, drop preview ticks rather
        // than queuing unbounded work that could interfere with audience video.
        guard !conversionInFlight else { return }
        let keys = Set(previews.values.compactMap { $0.view?.streamKey })
        let buffers: [(SharedVideoStreamKey, CVPixelBuffer)] = keys.compactMap { key in
            guard let buffer = VideoPlaybackPool.shared.previewPixelBuffer(
                path: key.path, sessionID: key.sessionID,
                sourceSlot: key.sourceSlot) else { return nil }
            return (key, buffer)
        }
        guard !buffers.isEmpty else { return }
        conversionInFlight = true
        conversionQueue.async { [weak self] in
            // CIContext is reused on this one serial queue. Each CVPixelBuffer
            // remains retained until the corresponding downscaled CGImage has
            // been produced, without touching any live AVPlayer transport.
            let images: [(SharedVideoStreamKey, CGImage)] = buffers.compactMap { key, buffer in
                let image = CIImage(cvPixelBuffer: buffer)
                guard image.extent.width > 0, image.extent.height > 0 else {
                    return nil
                }
                let scale = min(1, CGFloat(SharedVideoPreviewPolicy.maximumImageDimension) /
                               max(image.extent.width, image.extent.height))
                let small = image.transformed(
                    by: CGAffineTransform(scaleX: scale, y: scale))
                guard let rendered = SharedVideoPreviewHub.context.createCGImage(
                    small, from: small.extent) else { return nil }
                return (key, rendered)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.conversionInFlight = false
                for (key, frame) in images {
                    // A slide transition may have replaced the preview while
                    // a frame was being downscaled. Never display stale media.
                    for entry in self.previews.values {
                        guard let view = entry.view, view.streamKey == key else { continue }
                        view.present(frame)
                    }
                }
            }
        }

    }
}
