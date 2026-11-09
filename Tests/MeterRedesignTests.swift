import Foundation

@main struct MeterRedesignTests {
    static func main() {
        let a = SignalMeterMath.gainStages(preFader: 0.8, fader: 0.25,
                                           master: 0.5, envelope: 1)
        precondition(abs(a.pre - 0.8) < 0.0001)
        precondition(abs(a.post - 0.1) < 0.0001)
        let mutedCue = SignalMeterMath.gainStages(preFader: 0.8, fader: 0,
                                                 master: 1, envelope: 1)
        precondition(mutedCue.pre == 0.8 && mutedCue.post == 0)
        let faded = SignalMeterMath.gainStages(preFader: 0.8, fader: 1,
                                              master: 1, envelope: 0.5)
        precondition(abs(faded.pre - 0.4) < 0.0001)
        precondition(MeterBallistics.follow(current: 0.1, target: 0.9,
                                           elapsed: 0.016) > 0.1)
        precondition(MeterBallistics.follow(current: 0.9, target: 0.1,
                                           elapsed: 0.016) < 0.9)
        precondition(MeterBallistics.peakPosition(height: 200, fraction: 1) == 1)
        precondition(MeterBallistics.peakPosition(height: 200, fraction: 0) == 199)
        print("PASS: pre/post fader gains, 60fps meter ballistics and peak alignment")
    }
}
