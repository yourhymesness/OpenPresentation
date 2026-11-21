import Foundation

/// Rolling, monotonic-clock measurements for the experimental Metal Program
/// preview. This model is deliberately independent of AppKit and Metal so it
/// can be tested without a GPU or a video device.
struct RenderTimingSummary {
    let ticks: Int
    let missedTicks: Int
    let requestedFrames: Int
    let deliveredFrames: Int
    let meanEncodeMS: Double
    let p95EncodeMS: Double
    let maxHeartbeatOvershootMS: Double

    var availability: Double {
        requestedFrames > 0 ? Double(deliveredFrames) / Double(requestedFrames) : 0
    }
}

struct RenderTimingWindow {
    private struct Tick {
        let time: TimeInterval
        let requested: Int
        let delivered: Int
        let missed: Int
    }
    private struct Measurement {
        let time: TimeInterval
        let ms: Double
    }

    let expectedInterval: TimeInterval
    let windowSeconds: TimeInterval
    private var ticks: [Tick] = []
    private var encodes: [Measurement] = []
    private var heartbeats: [Measurement] = []
    private var previousTick: TimeInterval?

    init(expectedFramesPerSecond: Double = 30, windowSeconds: Double = 10) {
        expectedInterval = 1 / max(1, expectedFramesPerSecond)
        self.windowSeconds = max(1, windowSeconds)
    }

    mutating func recordTick(at time: TimeInterval, requested: Int, delivered: Int) {
        guard time.isFinite else { return }
        // Sleep/wake, first subscription, or a temporary pause should not
        // appear as hundreds of missed video deadlines.
        let gap = previousTick.map { time - $0 } ?? 0
        let missed = gap > expectedInterval * 1.5 && gap < 2
            ? max(0, Int((gap / expectedInterval).rounded(.down)) - 1) : 0
        ticks.append(Tick(time: time, requested: max(0, requested),
                          delivered: min(max(0, delivered), max(0, requested)),
                          missed: missed))
        previousTick = time
        prune(at: time)
    }

    mutating func recordEncode(milliseconds: Double, at time: TimeInterval) {
        guard milliseconds.isFinite && milliseconds >= 0 && time.isFinite else { return }
        encodes.append(Measurement(time: time, ms: milliseconds))
        prune(at: time)
    }

    mutating func recordHeartbeat(overshootSeconds: Double, at time: TimeInterval) {
        guard overshootSeconds.isFinite && time.isFinite else { return }
        heartbeats.append(Measurement(time: time, ms: max(0, overshootSeconds) * 1_000))
        prune(at: time)
    }

    func summary(at time: TimeInterval) -> RenderTimingSummary {
        let cutoff = time - windowSeconds
        let activeTicks = ticks.filter { $0.time >= cutoff && $0.time <= time }
        let activeEncodes = encodes.filter { $0.time >= cutoff && $0.time <= time }.map(\.ms)
        let sortedEncodes = activeEncodes.sorted()
        let p95Index = max(0, Int(ceil(Double(sortedEncodes.count) * 0.95)) - 1)
        let maxHeartbeat = heartbeats.filter { $0.time >= cutoff && $0.time <= time }
            .map(\.ms).max() ?? 0
        return RenderTimingSummary(
            ticks: activeTicks.count,
            missedTicks: activeTicks.reduce(0) { $0 + $1.missed },
            requestedFrames: activeTicks.reduce(0) { $0 + $1.requested },
            deliveredFrames: activeTicks.reduce(0) { $0 + $1.delivered },
            meanEncodeMS: activeEncodes.isEmpty ? 0 : activeEncodes.reduce(0, +) / Double(activeEncodes.count),
            p95EncodeMS: sortedEncodes.isEmpty ? 0 : sortedEncodes[p95Index],
            maxHeartbeatOvershootMS: maxHeartbeat)
    }

    private mutating func prune(at time: TimeInterval) {
        let cutoff = time - windowSeconds
        ticks.removeAll { $0.time < cutoff }
        encodes.removeAll { $0.time < cutoff }
        heartbeats.removeAll { $0.time < cutoff }
    }
}
