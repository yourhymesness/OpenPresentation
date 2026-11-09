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

/// Smooth meter ballistics at display refresh cadence, independent from
/// AVFoundation's decoded-sample polling cadence.
enum MeterBallistics {
    static func follow(current: Double, target: Double, elapsed: Double,
                       attack: Double = 0.030, release: Double = 0.240) -> Double {
        guard current.isFinite, target.isFinite else { return 0 }
        let dt = min(0.1, max(0, elapsed.isFinite ? elapsed : 0))
        let tau = target > current ? attack : release
        let alpha = 1 - exp(-dt / max(0.001, tau))
        return max(0, min(1, current + (target - current) * alpha))
    }
    static func peakPosition(height: Double, fraction: Double) -> Double {
        guard height.isFinite, height > 2 else { return 0 }
        return min(height - 1, max(1, height * (1 - max(0, min(1, fraction)))))
    }
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
