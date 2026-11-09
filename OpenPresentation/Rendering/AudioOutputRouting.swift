import AVFoundation
import CoreAudio
import Foundation

/// Enumerates Core Audio *output* endpoints (not microphone/input devices).
/// Device UIDs remain stable across application launches. The empty UID means
/// "follow the macOS system default" and is intentionally the default.
struct AudioOutputDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

enum AudioOutputRouting {
    static let preferenceKey = "audioOutputDeviceUID"

    static func availableDevices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        // Core Audio's system-object constant is imported as Int32 by this SDK,
        // while the AudioObjectGetPropertyData* functions require AudioObjectID (UInt32).
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &bytes) == noErr,
              bytes >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioDeviceID>.size)
        let success = ids.withUnsafeMutableBytes { rawBuffer in
            AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &bytes,
                                       rawBuffer.baseAddress!) == noErr
        }
        guard success else { return [] }
        return ids.compactMap { id in
            // Audio streams in the OUTPUT scope distinguish speakers/USB/HDMI
            // playback endpoints from input-only microphones.
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            var outputBytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &outputBytes) == noErr,
                  outputBytes > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  !uid.isEmpty else { return nil }
            let name = stringProperty(id, kAudioObjectPropertyName) ?? "Audio Device"
            return AudioOutputDevice(id: uid, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func stringProperty(_ device: AudioDeviceID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var bytes = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, &value) == noErr else {
            return nil
        }
        // Core Audio returns a CF object with a retained ownership contract.
        return value?.takeRetainedValue() as String?
    }

    static func effectiveUID() -> String? {
        let saved = UserDefaults.standard.string(forKey: preferenceKey) ?? ""
        guard !saved.isEmpty else { return nil }
        // A disconnected dock must never leave the app trying a dead route.
        return availableDevices().contains(where: { $0.id == saved }) ? saved : nil
    }

    static func apply(to player: AVPlayer) {
        let target = effectiveUID()
        if player.audioOutputDeviceUniqueID != target {
            player.audioOutputDeviceUniqueID = target
        }
    }
}
