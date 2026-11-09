import AppKit
import AVFoundation
import SwiftUI

/// A silent visual placeholder for a sound-only layer. Every physical output
/// gets its own player, but only the designated audience output is audible.
/// Distinct audio files can play concurrently and mix through Core Audio.
struct AudioPlaybackSurface: NSViewRepresentable {
    @ObservedObject var liveAudioMix = LiveAudioMix.shared
    let path: String
    let playbackSessionID: UUID
    var outputScope: String
    var audible: Bool
    var volume: Double
    var loops: Bool

    func makeNSView(context: Context) -> AudioPlaybackHostView {
        let view = AudioPlaybackHostView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: AudioPlaybackHostView, context: Context) {
        view.configure(path: path, session: playbackSessionID,
                       scope: outputScope, audible: audible,
                       volume: volume * liveAudioMix.effectiveProgramGain,
                       programGain: volume, loops: loops)
    }

    static func dismantleNSView(_ view: AudioPlaybackHostView, coordinator: ()) {
        view.unbind()
    }
}

final class AudioPlaybackHostView: NSView {
    private let hostID = UUID()
    private var key: AudioPlaybackPool.Key?

    func configure(path: String, session: UUID, scope: String, audible: Bool,
                   volume: Double, programGain: Double, loops: Bool) {
        let next = AudioPlaybackPool.Key(path: URL(fileURLWithPath: path).standardizedFileURL.path,
                                         scope: scope, sessionID: session)
        if key != next {
            unbind()
            key = next
            AudioPlaybackPool.shared.attach(next, hostID: hostID, loops: loops)
        }
        AudioPlaybackPool.shared.configure(next, audible: audible, volume: volume,
                                           programGain: programGain)
    }

    func unbind() {
        if let key { AudioPlaybackPool.shared.detach(key, hostID: hostID) }
        key = nil
    }
}

/// Audio is retained outside ephemeral SwiftUI slide views. A change from one
/// slide to another using the same audio path keeps its playing position.
@MainActor
final class AudioPlaybackPool {
    struct Key: Hashable {
        let path: String
        let scope: String
        let sessionID: UUID
    }

    private final class Entry {
        let player: AVPlayer
        let looper: AVPlayerLooper?
        let meterID: UUID?
        var hosts = Set<UUID>()
        var evictionGeneration = 0

        init(path: String, scope: String, loops: Bool) {
            let url = URL(fileURLWithPath: path)
            let item = AVPlayerItem(url: url)
            if loops {
                let queue = AVQueuePlayer()
                queue.actionAtItemEnd = .advance
                self.player = queue
                self.meterID = LiveAudioMeters.shared.attach(item: item, to: queue, scope: scope)
                self.looper = AVPlayerLooper(player: queue, templateItem: item)
            } else {
                let oneShot = AVPlayer(playerItem: item)
                oneShot.actionAtItemEnd = .pause
                self.player = oneShot
                self.meterID = LiveAudioMeters.shared.attach(item: item, to: oneShot, scope: scope)
                self.looper = nil
            }
            AudioOutputRouting.apply(to: player)
            player.isMuted = true
            player.play()
        }
    }

    static let shared = AudioPlaybackPool()
    private var entries: [Key: Entry] = [:]
    private init() {}

    func attach(_ key: Key, hostID: UUID, loops: Bool) {
        guard FileManager.default.fileExists(atPath: key.path) else { return }
        let entry: Entry
        if let existing = entries[key] {
            entry = existing
        } else {
            entry = Entry(path: key.path, scope: key.scope, loops: loops)
            entries[key] = entry
            // On another monitor, follow the same position where possible.
            if let master = entries.first(where: { $0.key != key &&
                $0.key.path == key.path && $0.key.sessionID == key.sessionID &&
                !$0.value.hosts.isEmpty })?.value {
                let time = master.player.currentTime()
                if time.isNumeric && CMTimeGetSeconds(time) > 0.1 { entry.player.seek(to: time) }
            }
        }
        entry.evictionGeneration += 1
        entry.hosts.insert(hostID)
        entry.player.play()
    }

    func configure(_ key: Key, audible: Bool, volume: Double, programGain: Double) {
        guard let entry = entries[key] else { return }
        entry.player.isMuted = !audible
        entry.player.volume = Float(max(0, min(volume, 1)))
        LiveAudioMeters.shared.configure(entry.meterID, programGain: programGain,
                                          nominalPlayerGain: volume)
    }

    func detach(_ key: Key, hostID: UUID) {
        guard let entry = entries[key] else { return }
        entry.hosts.remove(hostID)
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
