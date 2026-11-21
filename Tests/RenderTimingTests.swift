import Foundation

@main struct RenderTimingTests {
    static func main() {
        var stats = RenderTimingWindow(expectedFramesPerSecond: 30, windowSeconds: 5)
        let base = 100.0
        stats.recordTick(at: base, requested: 2, delivered: 1)
        stats.recordTick(at: base + 1 / 30.0, requested: 2, delivered: 2)
        stats.recordTick(at: base + 3 / 30.0, requested: 2, delivered: 0)
        stats.recordEncode(milliseconds: 1.2, at: base)
        stats.recordEncode(milliseconds: 2.4, at: base + 0.1)
        stats.recordEncode(milliseconds: .nan, at: base + 0.2)
        stats.recordHeartbeat(overshootSeconds: 0.015, at: base + 0.1)
        stats.recordHeartbeat(overshootSeconds: 0.035, at: base + 0.2)
        let summary = stats.summary(at: base + 0.2)
        precondition(summary.ticks == 3)
        precondition(summary.missedTicks == 1, "A missed 30 Hz callback should be counted")
        precondition(summary.requestedFrames == 6 && summary.deliveredFrames == 3)
        precondition(abs(summary.availability - 0.5) < 0.000001)
        precondition(abs(summary.meanEncodeMS - 1.8) < 0.000001)
        precondition(abs(summary.p95EncodeMS - 2.4) < 0.000001)
        precondition(abs(summary.maxHeartbeatOvershootMS - 35) < 0.000001)

        // A wake-from-sleep gap must not be called a massive GPU stall.
        stats.recordTick(at: base + 10, requested: 1, delivered: 1)
        let afterSleep = stats.summary(at: base + 10)
        precondition(afterSleep.ticks == 1 && afterSleep.missedTicks == 0)
        precondition(afterSleep.requestedFrames == 1 && afterSleep.deliveredFrames == 1)
        precondition(afterSleep.p95EncodeMS == 0)
        print("PASS: rolling Metal preview frame diagnostics, timing gaps and resets")
    }
}
