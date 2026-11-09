import Foundation

@main struct AudioMeterMathTests {
    static func main() {
        func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.0001) {
            precondition(abs(a - b) <= tolerance, "Expected \(a) ≈ \(b)")
        }
        near(SignalMeterMath.decibels(1), 0)
        near(SignalMeterMath.decibels(0.5), -6.0206)
        precondition(SignalMeterMath.decibels(0) == -.infinity)
        near(SignalMeterMath.fraction(1), 1)
        near(SignalMeterMath.fraction(pow(10, -60.0 / 20.0)), 0)
        near(SignalMeterMath.fraction(0), 0)
        near(SignalMeterMath.fraction(4), 1)
        let pure = StereoSignal(rmsLeft: 0.35, rmsRight: 0.1, peakLeft: 0.7, peakRight: 0.4)
        let solo = SignalMeterMath.estimatedMix([.init(signal: pure, gain: 0.5)])
        near(solo.rmsLeft, 0.175)
        near(solo.peakRight, 0.2)
        let pair = SignalMeterMath.estimatedMix([.init(signal: pure, gain: 1), .init(signal: pure, gain: 1)])
        near(pair.rmsLeft, sqrt(2) * pure.rmsLeft)
        near(pair.peakLeft, 1.4)
        let muted = SignalMeterMath.estimatedMix([.init(signal: pure, gain: 0)])
        precondition(muted.isSilent)
        let ignored = SignalMeterMath.estimatedMix([.init(signal: pure, gain: .nan)])
        precondition(ignored.isSilent)
        print("Audio meter math tests passed")
    }
}
