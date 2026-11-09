import AVFoundation
import AudioToolbox
import MediaToolbox
import SwiftUI
import os

/// A small, non-blocking accumulation buffer owned by each AVAudioMix tap.
/// Never dispatch to the main queue or allocate objects in the audio callback.
private final class PCMAccumulator {
    private struct Accumulated {
        var format = AudioStreamBasicDescription()
        var leftSquare = 0.0
        var rightSquare = 0.0
        var leftPeak = 0.0
        var rightPeak = 0.0
        var frames = 0
    }
    private let lock = OSAllocatedUnfairLock(initialState: Accumulated())

    func prepare(_ format: AudioStreamBasicDescription) {
        lock.withLock { state in state.format = format }
    }

    /// The audio render thread must not block on a UI poll. If the short lock
    /// cannot be acquired, skip this packet rather than risk a playback glitch.
    func capture(_ rawBuffers: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard frames > 0 else { return }
        // The Swift lock closure is @Sendable. Pass the short-lived pointer as
        // a plain address and reconstruct it inside the synchronous closure.
        // No pointer escapes this audio callback.
        let bufferAddress = UInt(bitPattern: UnsafeMutableRawPointer(rawBuffers))
        _ = lock.withLockIfAvailable { state in
            let rawBuffers = UnsafeMutableRawPointer(bitPattern: bufferAddress)!
                .assumingMemoryBound(to: AudioBufferList.self)
            let format = state.format
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { return }
            let floatPCM = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            let integerPCM = (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
            guard (floatPCM && (format.mBitsPerChannel == 32 || format.mBitsPerChannel == 64)) ||
                  (integerPCM && (format.mBitsPerChannel == 16 || format.mBitsPerChannel == 32)) else { return }
            let bytesPerSample = Int(format.mBitsPerChannel) / 8
            let buffers = UnsafeMutableAudioBufferListPointer(rawBuffers)
            let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            guard !buffers.isEmpty else { return }

            // A tap usually delivers planar float32. Interleaved float/int PCM
            // is also handled; mono is mirrored into both display channels.
            func sample(_ pointer: UnsafeMutableRawPointer, _ index: Int) -> Double {
                switch (floatPCM, format.mBitsPerChannel) {
                case (true, 32): return Double(pointer.assumingMemoryBound(to: Float.self)[index])
                case (true, 64): return pointer.assumingMemoryBound(to: Double.self)[index]
                case (false, 16): return Double(pointer.assumingMemoryBound(to: Int16.self)[index]) / 32768
                case (false, 32): return Double(pointer.assumingMemoryBound(to: Int32.self)[index]) / 2147483648
                default: return 0
                }
            }

            if nonInterleaved {
                guard let leftData = buffers[0].mData else { return }
                let rightBuffer = buffers.count > 1 ? buffers[1] : buffers[0]
                guard let rightData = rightBuffer.mData else { return }
                let count = min(frames, Int(buffers[0].mDataByteSize) / bytesPerSample,
                                Int(rightBuffer.mDataByteSize) / bytesPerSample)
                guard count > 0 else { return }
                for frame in 0..<count {
                    let left = sample(leftData, frame), right = sample(rightData, frame)
                    guard left.isFinite, right.isFinite else { continue }
                    state.leftSquare += left * left
                    state.rightSquare += right * right
                    state.leftPeak = max(state.leftPeak, abs(left))
                    state.rightPeak = max(state.rightPeak, abs(right))
                    state.frames += 1
                }
            } else {
                let b = buffers[0]
                guard let pointer = b.mData else { return }
                let channels = max(1, Int(format.mChannelsPerFrame))
                let count = min(frames, Int(b.mDataByteSize) / (bytesPerSample * channels))
                guard count > 0 else { return }
                for frame in 0..<count {
                    let index = frame * channels
                    let left = sample(pointer, index)
                    let right = sample(pointer, index + (channels > 1 ? 1 : 0))
                    guard left.isFinite, right.isFinite else { continue }
                    state.leftSquare += left * left
                    state.rightSquare += right * right
                    state.leftPeak = max(state.leftPeak, abs(left))
                    state.rightPeak = max(state.rightPeak, abs(right))
                    state.frames += 1
                }
            }
        }
    }

    func drain() -> StereoSignal {
        lock.withLock { state in
            guard state.frames > 0 else { return .silent }
            let result = StereoSignal(rmsLeft: sqrt(state.leftSquare / Double(state.frames)),
                                      rmsRight: sqrt(state.rightSquare / Double(state.frames)),
                                      peakLeft: state.leftPeak, peakRight: state.rightPeak)
            state.leftSquare = 0
            state.rightSquare = 0
            state.leftPeak = 0
            state.rightPeak = 0
            state.frames = 0
            return result
        }
    }
}

/// Observes the PCM of local file-based AVPlayerItems without changing samples.
/// Audio taps are not supported for HLS streams. The player pools retain their
/// playback sessions, and the tap's finalize callback owns its accumulator.
private enum LocalPCMMonitor {
    static func install(on item: AVPlayerItem) -> [PCMAccumulator] {
        let tracks = item.asset.tracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return [] }
        var parameters: [AVAudioMixInputParameters] = []
        var result: [PCMAccumulator] = []
        for track in tracks {
            let accumulator = PCMAccumulator()
            let retained = Unmanaged.passRetained(accumulator).toOpaque()
            var callbacks = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: retained,
                init: { _, info, out in out.pointee = info },
                finalize: { tap in
                    let info = MTAudioProcessingTapGetStorage(tap)
                    Unmanaged<PCMAccumulator>.fromOpaque(info).release()
                },
                prepare: { tap, _, format in
                    let info = MTAudioProcessingTapGetStorage(tap)
                    Unmanaged<PCMAccumulator>.fromOpaque(info).takeUnretainedValue().prepare(format.pointee)
                },
                unprepare: { _ in },
                process: { tap, requestedFrames, _, buffers, framesOut, flagsOut in
                    let status = MTAudioProcessingTapGetSourceAudio(tap, requestedFrames,
                                                                    buffers, flagsOut, nil, framesOut)
                    guard status == noErr, framesOut.pointee > 0 else { return }
                    let info = MTAudioProcessingTapGetStorage(tap)
                    Unmanaged<PCMAccumulator>.fromOpaque(info).takeUnretainedValue()
                        .capture(buffers, frames: Int(framesOut.pointee))
                }
            )
            var tap: MTAudioProcessingTap?
            let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                    kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
            if status != noErr || tap == nil {
                // Creation failures do not invoke finalize on an uncreated tap.
                Unmanaged<PCMAccumulator>.fromOpaque(retained).release()
                continue
            }
            let input = AVMutableAudioMixInputParameters(track: track)
            input.audioTapProcessor = tap
            parameters.append(input)
            result.append(accumulator)
        }
        if !parameters.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = parameters
            item.audioMix = mix
        }
        return result
    }
}

/// Main-actor UI snapshot of active audible players. AVPlayer applies the
/// volume after the PCM tap, so we multiply actual sample levels by the gains.
/// Multiple AVPlayers mix outside this app; the summed display is an estimate,
/// NOT a sample-synchronous hardware capture or an output-device loopback.
@MainActor
final class LiveAudioMeters: ObservableObject {
    static let shared = LiveAudioMeters()
    @Published private(set) var program: StereoSignal = .silent
    @Published private(set) var master: StereoSignal = .silent

    private final class Source {
        weak var player: AVPlayer?
        let scope: String
        let taps: [PCMAccumulator]
        var programGain: Double
        var nominalPlayerGain: Double

        init(player: AVPlayer, scope: String, taps: [PCMAccumulator],
             programGain: Double, nominalPlayerGain: Double) {
            self.player = player
            self.scope = scope
            self.taps = taps
            self.programGain = programGain
            self.nominalPlayerGain = nominalPlayerGain
        }
    }
    private var sources: [UUID: Source] = [:]

    /// Must be called before an AVPlayerLooper copies a template item.
    func attach(item: AVPlayerItem, to player: AVPlayer, scope: String) -> UUID? {
        let taps = LocalPCMMonitor.install(on: item)
        guard !taps.isEmpty else { return nil }
        let id = UUID()
        sources[id] = Source(player: player, scope: scope, taps: taps,
                             programGain: 1, nominalPlayerGain: 1)
        return id
    }

    func configure(_ id: UUID?, programGain: Double, nominalPlayerGain: Double) {
        guard let id, let source = sources[id] else { return }
        source.programGain = min(1, max(0, programGain))
        source.nominalPlayerGain = min(1, max(0, nominalPlayerGain))
    }

    func remove(_ id: UUID?) {
        guard let id else { return }
        sources.removeValue(forKey: id)
    }

    func poll() {
        var beforeMaster: [MeterSourceContribution] = []
        var atMaster: [MeterSourceContribution] = []
        let masterGain = LiveAudioMix.shared.effectiveProgramGain
        var staleIDs: [UUID] = []
        for (id, source) in sources {
            guard let player = source.player else {
                staleIDs.append(id)
                continue
            }
            // Drain every accumulator even while muted, so stale audio does
            // not illuminate the meters after unmuting or switching outputs.
            for tap in source.taps {
                let signal = tap.drain()
                guard !signal.isSilent,
                      !player.isMuted, player.rate > 0,
                      source.scope == "fullscreen" || source.scope == "windowed" else { continue }
                let currentGain = max(0, Double(player.volume))
                let envelope = source.nominalPlayerGain > 0.00001
                    ? min(1, currentGain / source.nominalPlayerGain)
                    : 1
                let programGain = source.programGain * envelope
                beforeMaster.append(MeterSourceContribution(signal: signal, gain: programGain))
                atMaster.append(MeterSourceContribution(signal: signal, gain: programGain * masterGain))
            }
        }
        for id in staleIDs { sources.removeValue(forKey: id) }
        program = SignalMeterMath.estimatedMix(beforeMaster)
        master = SignalMeterMath.estimatedMix(atMaster)
    }
}
