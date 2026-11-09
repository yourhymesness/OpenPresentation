import Foundation

@main
struct SlideAudioCueAndTransitionDefaults {
    static func main() throws {
        var outgoing = PresentationSlide(text: "Intro")
        outgoing.slideTitle = "Opening Video"
        outgoing.cueAudioGain = 0.23
        outgoing.cueAudioMuted = false
        outgoing.autoAdvanceSeconds = 8.0
        var incoming = PresentationSlide(text: "Keynote")
        incoming.slideTitle = "Keynote with Loud Music"
        incoming.cueAudioGain = 0.82
        incoming.cueAudioMuted = true
        incoming.transitionSecondsOverride = 1.75
        let show = PresentationShow(title: "Demo", slides: [outgoing, incoming],
                                    globalTransitionSeconds: 0.9)
        let data = try JSONEncoder().encode(show)
        let decoded = try JSONDecoder().decode(PresentationShow.self, from: data)
        precondition(decoded.globalTransitionSeconds == 0.9)
        precondition(decoded.slides[0].cueAudioGain == 0.23)
        precondition(decoded.slides[0].resolvedCueAudioGain == 0.23)
        precondition(decoded.slides[0].transitionSecondsOverride == nil)
        precondition(decoded.slides[1].cueAudioGain == 0.82)
        precondition(decoded.slides[1].cueAudioMuted)
        precondition(decoded.slides[1].resolvedCueAudioGain == 0)
        precondition(decoded.slides[1].transitionSecondsOverride == 1.75)
        precondition(decoded.slides[0].autoAdvanceSeconds == 8.0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Audio Cue.json")
        try ProjectStore.save(show, to: file)
        let disk = try ProjectStore.load(from: file)
        precondition(disk.globalTransitionSeconds == 0.9)
        precondition(disk.slides[0].cueAudioGain == 0.23)
        precondition(disk.slides[1].cueAudioGain == 0.82)
        precondition(disk.slides[1].transitionSecondsOverride == 1.75)
        let legacyJSON = """
        {"formatVersion":5,"title":"Legacy","slides":[{"id":"00000000-0000-0000-0000-000000000123","layers":[],"backgroundHex":"#00000000"}]}
        """.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(PresentationShow.self, from: legacyJSON)
        precondition(legacy.globalTransitionSeconds == 0.65)
        precondition(legacy.slides[0].cueAudioGain == 1)
        precondition(legacy.slides[0].cueAudioMuted == false)
        precondition(legacy.slides[0].transitionSecondsOverride == nil)
        print("PASS: per-slide audio gain/mute, global and overridden transitions, JSON and disk round-trips, legacy defaults")
    }
}
