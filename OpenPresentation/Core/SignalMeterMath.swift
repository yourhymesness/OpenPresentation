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


/// Display-facing peak ballistic state, separate from the decoded-PCM polling
/// frequency. Pure Foundation code so 60/120/144 Hz timing can be regression
/// tested even on machines without AppKit or a dedicated audio device.
/// A peak-hold marker rides the leading edge of the moving peak bar on rises,
/// holds briefly after a decline, then falls toward the current bar.
struct AnimatedStereoPeak {
    let left: Double
    let right: Double
    let heldLeft: Double
    let heldRight: Double
    let clipping: Bool
}

final class StereoPeakFollower {
    private var lastDate: Date?
    private var shownLeft: Double = 0
    private var shownRight: Double = 0
    private var heldLeft: Double = 0
    private var heldRight: Double = 0
    private var holdLeftUntil: Date = .distantPast
    private var holdRightUntil: Date = .distantPast
    private var clipUntil: Date = .distantPast

    func advance(to date: Date, signal: StereoSignal) -> AnimatedStereoPeak {
        let elapsed = lastDate.map { min(0.1, max(0, date.timeIntervalSince($0))) }
            ?? (1.0 / 60.0)
        lastDate = date

        // The filled bar follows decoded signal PEAK, not RMS average.
        // Otherwise the held peak line is permanently detached above it.
        shownLeft = MeterBallistics.follow(
            current: shownLeft, target: SignalMeterMath.fraction(signal.peakLeft),
            elapsed: elapsed)
        shownRight = MeterBallistics.follow(
            current: shownRight, target: SignalMeterMath.fraction(signal.peakRight),
            elapsed: elapsed)

        func hold(current: Double, bar: Double, until: inout Date) -> Double {
            guard bar > 0.00001 || current > 0.00001 else { return 0 }
            if bar >= current {
                until = date.addingTimeInterval(0.45)
                return bar
            }
            if date < until { return current }
            // Decay behind the falling signal, never crossing through its bar.
            return max(bar, MeterBallistics.follow(
                current: current, target: bar, elapsed: elapsed, release: 0.25))
        }
        heldLeft = hold(current: heldLeft, bar: shownLeft, until: &holdLeftUntil)
        heldRight = hold(current: heldRight, bar: shownRight, until: &holdRightUntil)

        if signal.peakLeft >= 0.999 || signal.peakRight >= 0.999 {
            clipUntil = date.addingTimeInterval(1.3)
        }
        return AnimatedStereoPeak(
            left: shownLeft, right: shownRight,
            heldLeft: max(shownLeft, heldLeft), heldRight: max(shownRight, heldRight),
            clipping: date < clipUntil)
    }
}

enum SignalMeterMath {
    static func gainStages(preFader: Double, fader: Double, master: Double,
                           envelope: Double) -> (pre: Double, post: Double) {
        let pre = max(0, preFader) * max(0, envelope)
        let post = pre * max(0, fader) * max(0, master)
        return (pre, post)
    }

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
