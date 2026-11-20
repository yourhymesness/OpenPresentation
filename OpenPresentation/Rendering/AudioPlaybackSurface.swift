import AppKit
import AVFoundation
import SwiftUI

/// A silent visual placeholder for a sound-only layer. All output hosts for
/// one take share the same retained audio player, so changing output windows
/// cannot restart its sound or replace its PCM meter tap.
/// Distinct audio files can play concurrently and mix through Core Audio.
struct AudioPlaybackSurface: NSViewRepresentable {
    @ObservedObject var liveAudioMix = LiveAudioMix.shared
    let path: String
    let playbackSessionID: UUID
    var outputScope: String
    var audible: Bool
    var volume: Double
    var loops: Bool
    var preFaderGain: Double = 1
    var faderGain: Double = 1

    func makeNSView(context: Context) -> AudioPlaybackHostView {
        let view = AudioPlaybackHostView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: AudioPlaybackHostView, context: Context) {
        view.configure(path: path, session: playbackSessionID,
                       scope: outputScope, audible: audible,
                       volume: volume * liveAudioMix.effectiveProgramGain,
                       preFaderGain: preFaderGain, faderGain: faderGain, loops: loops)
    }

    static func dismantleNSView(_ view: AudioPlaybackHostView, coordinator: ()) {
        view.unbind()
    }
}

final class AudioPlaybackHostView: NSView {
    private let hostID = UUID()
    private var key: AudioPlaybackPool.Key?

    func configure(path: String, session: UUID, scope: String, audible: Bool,
                   volume: Double, preFaderGain: Double, faderGain: Double,
                   loops: Bool) {
        let next = AudioPlaybackPool.Key(path: URL(fileURLWithPath: path).standardizedFileURL.path,
                                         sessionID: session)
        let newlyAttached = key != next
        if newlyAttached {
            unbind()
            key = next
            AudioPlaybackPool.shared.attach(next, hostID: hostID, scope: scope, loops: loops)
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

        init(path: String, loops: Bool) {
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
        }
    }

    static let shared = AudioPlaybackPool()
    private var entries: [Key: Entry] = [:]
    private var audioOwnerScope = "program"
    private init() {}

    func setAudioOwnerScope(_ scope: String) {
        guard audioOwnerScope != scope else { return }
        audioOwnerScope = scope
        // Only change who may control the retained player; never recreate
        // or seek the stream when an audience window opens or closes.
        for entry in entries.values {
            applyOwnerMix(to: entry)
        }
    }

    func attach(_ key: Key, hostID: UUID, scope: String, loops: Bool) {
        guard FileManager.default.fileExists(atPath: key.path) else { return }
        let entry: Entry
        if let existing = entries[key] {
            entry = existing
        } else {
            entry = Entry(path: key.path, loops: loops)
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
        entry.player.volume = Float(max(0, min(mix.volume, 1)))
        entry.player.isMuted = false
        LiveAudioMeters.shared.configure(entry.meterID,
                                         preFaderGain: mix.preFaderGain, faderGain: mix.faderGain,
                                         nominalPlayerGain: mix.volume)
    }

    func resume(_ key: Key, hostID: UUID) {
        guard let entry = entries[key], entry.hosts.count == 1,
              entry.hosts[hostID] != nil else { return }
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
            entry.player.pause()
            LiveAudioMeters.shared.remove(entry.meterID)
            self.entries.removeValue(forKey: key)
        }
    }

    func refreshAudioRouting() {
        for entry in entries.values { AudioOutputRouting.apply(to: entry.player) }
    }
}
