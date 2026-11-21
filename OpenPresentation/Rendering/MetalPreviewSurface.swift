import AppKit
import AVFoundation
import CoreImage
import MetalKit
import SwiftUI

/// v0.5.0 experimental renderer. It draws audience-decoded frames into a
/// Metal-backed Program preview, without replacing the live audience output
/// or allocating any additional AVPlayers. This is a per-layer prototype,
/// not yet the shared multi-output compositor planned for v0.5.1.
struct MetalVideoPreviewSurface: NSViewRepresentable {
    let path: String
    let playbackSessionID: UUID
    let sourceSlot: String
    let contentMode: LayerContentMode

    func makeNSView(context: Context) -> MetalVideoSnapshotView {
        let view = MetalVideoSnapshotView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.configure(path: path, sessionID: playbackSessionID,
                       sourceSlot: sourceSlot, mode: contentMode)
        return view
    }

    func updateNSView(_ view: MetalVideoSnapshotView, context: Context) {
        view.configure(path: path, sessionID: playbackSessionID,
                       sourceSlot: sourceSlot, mode: contentMode)
    }

    static func dismantleNSView(_ view: MetalVideoSnapshotView, coordinator: ()) {
        view.unsubscribe()
    }
}

struct MetalPreviewStreamKey: Hashable {
    let path: String
    let sessionID: UUID
    let sourceSlot: String
}

@MainActor
final class MetalPreviewDiagnostics: ObservableObject {
    static let shared = MetalPreviewDiagnostics()
    @Published private(set) var latest = RenderTimingWindow().summary(at: 0)
    private(set) var lastMetalTick: TimeInterval = 0

    private var timing = RenderTimingWindow(expectedFramesPerSecond: 30)
    private var lastPublication: TimeInterval = 0
    private init() {}

    func recordTick(at now: TimeInterval, requested: Int, delivered: Int) {
        timing.recordTick(at: now, requested: requested, delivered: delivered)
        lastMetalTick = now
        publishIfNeeded(at: now)
    }

    func recordEncode(milliseconds: Double, at now: TimeInterval) {
        timing.recordEncode(milliseconds: milliseconds, at: now)
        publishIfNeeded(at: now)
    }

    func recordHeartbeat(overshootSeconds: Double, at now: TimeInterval) {
        timing.recordHeartbeat(overshootSeconds: overshootSeconds, at: now)
        publishIfNeeded(at: now)
    }

    private func publishIfNeeded(at now: TimeInterval) {
        guard now - lastPublication >= 1 else { return }
        lastPublication = now
        latest = timing.summary(at: now)
    }
}

struct MetalPreviewDiagnosticsPanel: View {
    @ObservedObject private var diagnostics = MetalPreviewDiagnostics.shared

    var body: some View {
        let stats = diagnostics.latest
        let running = ProcessInfo.processInfo.systemUptime - diagnostics.lastMetalTick < 2
        VStack(alignment: .leading, spacing: 7) {
            Text("Metal Program Preview · 10-second window")
                .font(.headline)
            if !running {
                Text("Select Metal 30 FPS and open an audience output to collect frames.")
                    .foregroundStyle(.secondary)
            }
            metric("Frame sample ticks", "\(running ? stats.ticks : 0)")
            metric("Missed sample deadlines", "\(running ? stats.missedTicks : 0)")
            metric("Decoded frame availability", stats.requestedFrames > 0 && running
                   ? String(format: "%.1f%%", stats.availability * 100) : "—")
            metric("Metal encode time (mean / P95)", stats.meanEncodeMS > 0 && running
                   ? String(format: "%.2f / %.2f ms", stats.meanEncodeMS, stats.p95EncodeMS) : "—")
            metric("Operator heartbeat overshoot (max)",
                   String(format: "%.0f ms", stats.maxHeartbeatOvershootMS))
            Divider()
            Text("Frame availability and CPU command-encoding time are measured here; these are not GPU utilization, actual scan-out, or hardware decode-drop counters. Audience output uses the original renderer.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption.monospacedDigit())
        .padding(14)
        .frame(width: 335, alignment: .leading)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 8)
            Text(value).fontWeight(.semibold)
        }
    }
}

/// The Metal view owns neither AVPlayer nor audio. A shared 30 Hz sampler
/// provides live CVPixelBuffers to any visible layers that use the same take.
@MainActor
final class MetalVideoSnapshotView: MTKView, MTKViewDelegate {
    let identity = UUID()
    private(set) var streamKey: MetalPreviewStreamKey?
    private var contentMode: LayerContentMode = .fill
    private var latestBuffer: CVPixelBuffer?
    private var commandQueue: MTLCommandQueue?
    private var imageContext: CIContext?
    private let workingColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device ?? MTLCreateSystemDefaultDevice())
        setupMetal()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        self.device = MTLCreateSystemDefaultDevice()
        setupMetal()
    }

    private func setupMetal() {
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false // Core Image writes directly to drawable.texture.
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        isPaused = true
        enableSetNeedsDisplay = false
        delegate = self
        if let device {
            commandQueue = device.makeCommandQueue()
            imageContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
    }

    func configure(path: String, sessionID: UUID, sourceSlot: String, mode: LayerContentMode) {
        contentMode = mode
        let key = MetalPreviewStreamKey(path: URL(fileURLWithPath: path).standardizedFileURL.path,
                                        sessionID: sessionID, sourceSlot: sourceSlot)
        guard streamKey != key else { return }
        unsubscribe()
        streamKey = key
        latestBuffer = nil
        MetalVideoPreviewHub.shared.subscribe(self)
    }

    func receive(_ buffer: CVPixelBuffer) {
        latestBuffer = buffer
        draw()
    }

    func unsubscribe() {
        MetalVideoPreviewHub.shared.unsubscribe(identity)
        streamKey = nil
        latestBuffer = nil
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        // Explicit preview draws normally arrive on RunLoop.main. Do not
        // assume MetalKit will never request a draw on another thread.
        if Thread.isMainThread {
            MainActor.assumeIsolated { drawCurrentFrame() }
        } else {
            Task { @MainActor [weak self] in self?.drawCurrentFrame() }
        }
    }

    private func drawCurrentFrame() {
        guard let buffer = latestBuffer, let drawable = currentDrawable,
              let commandQueue, let commandBuffer = commandQueue.makeCommandBuffer(),
              let imageContext else { return }
        let started = ProcessInfo.processInfo.systemUptime
        let source = CIImage(cvPixelBuffer: buffer)
        let target = CGRect(x: 0, y: 0, width: drawableSize.width, height: drawableSize.height)
        guard source.extent.width > 0, source.extent.height > 0,
              target.width > 0, target.height > 0 else { return }

        let sx = target.width / source.extent.width
        let sy = target.height / source.extent.height
        let scaleX: CGFloat
        let scaleY: CGFloat
        switch contentMode {
        case .fit: scaleX = min(sx, sy); scaleY = scaleX
        case .fill: scaleX = max(sx, sy); scaleY = scaleX
        case .stretch: scaleX = sx; scaleY = sy
        }
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let centered = scaled.transformed(by: CGAffineTransform(
            translationX: target.midX - scaled.extent.midX,
            y: target.midY - scaled.extent.midY))
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: target)
        let frame = centered.composited(over: black).cropped(to: target)
        imageContext.render(frame, to: drawable.texture, commandBuffer: commandBuffer,
                            bounds: target, colorSpace: workingColorSpace)
        commandBuffer.present(drawable)
        commandBuffer.commit()
        MetalPreviewDiagnostics.shared.recordEncode(
            milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000,
            at: ProcessInfo.processInfo.systemUptime)
    }
}

/// A single 30 Hz timer reads each unique live audience source once. This
/// benchmark does not perform CPU pixel readbacks or create independent
/// Program AVPlayers; the tested Metal view consumes the existing buffers.
@MainActor
final class MetalVideoPreviewHub {
    static let shared = MetalVideoPreviewHub()
    private final class WeakView {
        weak var view: MetalVideoSnapshotView?
        init(_ view: MetalVideoSnapshotView) { self.view = view }
    }
    private var previews: [UUID: WeakView] = [:]
    private var timer: Timer?
    private init() {}

    func subscribe(_ view: MetalVideoSnapshotView) {
        previews[view.identity] = WeakView(view)
        if timer == nil {
            let next = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            next.tolerance = 0.005
            RunLoop.main.add(next, forMode: .common)
            timer = next
        }
    }

    func unsubscribe(_ id: UUID) {
        previews.removeValue(forKey: id)
        if previews.isEmpty { timer?.invalidate(); timer = nil }
    }

    private func sample() {
        previews = previews.filter { $0.value.view?.streamKey != nil }
        guard !previews.isEmpty else { timer?.invalidate(); timer = nil; return }
        let keys = Set(previews.values.compactMap { $0.view?.streamKey })
        var buffers: [MetalPreviewStreamKey: CVPixelBuffer] = [:]
        for key in keys {
            if let pixelBuffer = VideoPlaybackPool.shared.previewPixelBuffer(
                path: key.path, sessionID: key.sessionID, sourceSlot: key.sourceSlot) {
                buffers[key] = pixelBuffer
            }
        }
        MetalPreviewDiagnostics.shared.recordTick(
            at: ProcessInfo.processInfo.systemUptime,
            requested: keys.count, delivered: buffers.count)
        for recipient in previews.values {
            guard let view = recipient.view, let key = view.streamKey,
                  let buffer = buffers[key] else { continue }
            view.receive(buffer)
        }
    }
}
