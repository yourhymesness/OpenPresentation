import Foundation

@main struct RefreshAdaptivePeakMeterTests {
    static func main() {
        for hz in [60.0, 120.0, 144.0] {
            let meter = StereoPeakFollower()
            let base = Date(timeIntervalSinceReferenceDate: 10_000)
            let impulse = StereoSignal(rmsLeft: 0.06, rmsRight: 0.04,
                                       peakLeft: 0.9, peakRight: 0.7)
            var f = meter.advance(to: base, signal: .silent)
            for n in 1...Int(hz) {
                f = meter.advance(to: base.addingTimeInterval(Double(n)/hz),
                                  signal: impulse)
                precondition(f.heldLeft >= f.left - 1e-9 &&
                             f.heldRight >= f.right - 1e-9,
                             "Peak hold must never drop below the moving bar")
            }
            let target = SignalMeterMath.fraction(0.9)
            precondition(abs(f.left - target) < 0.0002,
                         "Level must converge regardless of actual screen cadence")
            // A new rise pushes the white line up WITH the filled peak bar.
            precondition(abs(f.heldLeft - f.left) < 0.0002)
            let endRise = f.left
            let firstFall = meter.advance(
                to: base.addingTimeInterval(1 + 1/hz), signal: .silent)
            precondition(firstFall.left < endRise)
            precondition(firstFall.heldLeft >= firstFall.left)
            // After the short hold, both return to silence.
            for n in 2...Int(3*hz) {
                f = meter.advance(to: base.addingTimeInterval(1 + Double(n)/hz),
                                  signal: .silent)
            }
            precondition(f.left < 0.002 && f.heldLeft < 0.005)
            precondition(MeterBallistics.peakPosition(height: 300,
                fraction: f.heldLeft) <= 299)
        }

        let clipMeter = StereoPeakFollower()
        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        let clipping = StereoSignal(peakLeft: 1.02, peakRight: 0.2)
        precondition(clipMeter.advance(to: now, signal: clipping).clipping)
        precondition(clipMeter.advance(to: now.addingTimeInterval(0.1),
                                       signal: .silent).clipping)
        precondition(!clipMeter.advance(to: now.addingTimeInterval(2),
                                        signal: .silent).clipping)
        print("PASS: display-cadence peak ballistics, rising marker, hold, decay and clipping")
    }
}
