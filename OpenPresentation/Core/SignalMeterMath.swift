import Foundation

/// Portable, signal-derived meter calculations. Linear amplitudes are 0...1
/// for nominal full scale; dBFS conversion is deliberately independent of UI.
struct StereoSignal: Equatable {
    var rmsLeft: Double = 0
    var rmsRight: Double = 0
    var peakLeft: Double = 0
    var peakRight: Double = 0

    static let silent = StereoSignal()

    var isSilent: Bool { rmsLeft == 0 && rmsRight == 0 && peakLeft == 0 && peakRight == 0 }
}

struct MeterSourceContribution {
    var signal: StereoSignal
    var gain: Double
}

enum SignalMeterMath {
    static func decibels(_ amplitude: Double) -> Double {
        guard amplitude.isFinite, amplitude > 0 else { return -.infinity }
        return 20 * log10(amplitude)
    }

    /// The bottom of the UI scale is -60 dBFS. Values above 0 dBFS indicate
    /// potential summed clipping and occupy the maximum height.
    static func fraction(_ amplitude: Double, floorDB: Double = -60) -> Double {
        let db = decibels(amplitude)
        guard db.isFinite else { return 0 }
        return min(1, max(0, (db - floorDB) / -floorDB))
    }

    /// With independently decoded sources we cannot calculate a sample-accurate
    /// device mix. RMS is estimated using uncorrelated signal energy, and peak
    /// uses the conservative sum of source peak amplitudes. Label as estimated.
    static func estimatedMix(_ contributions: [MeterSourceContribution]) -> StereoSignal {
        var lSquared = 0.0, rSquared = 0.0, lPeak = 0.0, rPeak = 0.0
        for source in contributions {
            let gain = source.gain.isFinite ? max(0, source.gain) : 0
            let s = source.signal
            let l = max(0, s.rmsLeft) * gain
            let r = max(0, s.rmsRight) * gain
            lSquared += l * l
            rSquared += r * r
            lPeak += max(0, s.peakLeft) * gain
            rPeak += max(0, s.peakRight) * gain
        }
        return StereoSignal(rmsLeft: sqrt(lSquared), rmsRight: sqrt(rSquared),
                            peakLeft: lPeak, peakRight: rPeak)
    }
}
