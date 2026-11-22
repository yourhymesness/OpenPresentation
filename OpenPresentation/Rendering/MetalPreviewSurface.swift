import AppKit
import AVFoundation
import CoreImage
import CoreVideo
import MetalKit
import SwiftUI

/// Metal video surface backed by audience-decoded frames, without allocating
/// additional AVPlayers. Normally used for the operator Program preview; an
/// opt-in audience experiment may also use it for video layers. This is still
/// a per-layer renderer, not a shared full-frame output compositor.
struct MetalVideoPreviewSurface: NSViewRepresentable {
    let path: String
    let playbackSessionID: UUID
    let sourceSlot: String
    let contentMode: LayerContentMode
    var transitionOpacity: Double = 1.0

    func makeNSView(context: Context) -> MetalVideoSnapshotView {
        let view = MetalVideoSnapshotView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.configure(path: path, sessionID: playbackSessionID,
                       sourceSlot: sourceSlot, mode: contentMode,
                       transitionOpacity: transitionOpacity)
        return view
    }

    func updateNSView(_ view: MetalVideoSnapshotView, context: Context) {
        view.configure(path: path, sessionID: playbackSessionID,
                       sourceSlot: sourceSlot, mode: contentMode,
                       transitionOpacity: transitionOpacity)
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
    private var configuredFPS = 30
    private var lastPublication: TimeInterval = 0
    private init() {}

    func configure(frameRate: Int) {
        guard configuredFPS != frameRate else { return }
        configuredFPS = frameRate
        timing = RenderTimingWindow(expectedFramesPerSecond: Double(frameRate))
        lastPublication = 0
    }

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
    @AppStorage("experimentalMetalAudienceVideo") private var experimentalMetalAudienceVideo = false
    @AppStorage("metalTargetFPS") private var metalTargetFPS = MetalVideoFrameRate.standard.rawValue

    var body: some View {
        let stats = diagnostics.latest
        let running = ProcessInfo.processInfo.systemUptime - diagnostics.lastMetalTick < 2
        VStack(alignment: .leading, spacing: 7) {
            Text("Metal Video Layers · \(MetalVideoFrameRate.validated(metalTargetFPS)) FPS target · 10-second window")
                .font(.headline)
            if !running {
                Text("Open an audience output and enable Metal Program preview or " +
                     "experimental audience video rendering to collect frames.")
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
            Text("Frame availability and CPU command-encoding time are measured here; " +
                 "these are not GPU utilization, actual scan-out, or hardware " +
                 "decode-drop counters. " +
                 (experimentalMetalAudienceVideo
                  ? "Audience video-layer Metal rendering is experimental."
                  : "Audience output uses the original renderer."))
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

/// All experimental video layers use the same GPU device, command queue and
/// Core Image context. During a dissolve the outgoing and incoming surfaces
/// therefore do not each construct their own expensive CI rendering context.
/// This is shared GPU infrastructure, not yet a single-pass slide compositor.
@MainActor
private final class MetalVideoRenderResources {
    static let shared = MetalVideoRenderResources()
    let device: MTLDevice?
    let queue: MTLCommandQueue?
    let imageContext: CIContext?
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        queue = device?.makeCommandQueue()
        imageContext = device.map {
            CIContext(mtlDevice: $0, options: [.cacheIntermediates: false])
        }
    }
}

/// The Metal view owns neither AVPlayer nor audio. One shared sampler
/// provides live CVPixelBuffers to visible layers of the same take.
@MainActor
final class MetalVideoSnapshotView: MTKView, MTKViewDelegate {
    let identity = UUID()
    private(set) var streamKey: MetalPreviewStreamKey?
    private var contentMode: LayerContentMode = .fill
    private var latestBuffer: CVPixelBuffer?
    private let startupPoster = CALayer()
    private var hasLiveFrame = false
    override init(frame frameRect: NSRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: MetalVideoRenderResources.shared.device ?? device)
        setupMetal()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        self.device = MetalVideoRenderResources.shared.device
        setupMetal()
    }

    private func setupMetal() {
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false // Core Image writes directly to drawable.texture.
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        startupPoster.opacity = 0
        startupPoster.contentsGravity = .resizeAspectFill
        layer?.addSublayer(startupPoster)
        isPaused = true
        enableSetNeedsDisplay = false
        delegate = self
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        startupPoster.frame = bounds
        CATransaction.commit()
    }

    func configure(path: String, sessionID: UUID, sourceSlot: String, mode: LayerContentMode,
                   transitionOpacity: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = Float(min(max(transitionOpacity, 0), 1))
        CATransaction.commit()
        contentMode = mode
        switch mode {
        case .fit: startupPoster.contentsGravity = .resizeAspect
        case .fill: startupPoster.contentsGravity = .resizeAspectFill
        case .stretch: startupPoster.contentsGravity = .resize
        }
        let key = MetalPreviewStreamKey(path: URL(fileURLWithPath: path).standardizedFileURL.path,
                                        sessionID: sessionID, sourceSlot: sourceSlot)
        guard streamKey != key else { return }
        unsubscribe()
        streamKey = key
        latestBuffer = nil
        hasLiveFrame = false
        let cached = VideoFirstFrameCache.shared.frame(for: key.path) { [weak self] frame in
            guard let self, self.streamKey == key, !self.hasLiveFrame else { return }
            self.showStartupPoster(frame)
        }
        showStartupPoster(cached)
        MetalVideoPreviewHub.shared.subscribe(self)
    }

    private func showStartupPoster(_ frame: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        startupPoster.contents = frame
        startupPoster.opacity = frame == nil ? 0 : 1
        CATransaction.commit()
    }

    private func dismissStartupPoster() {
        guard startupPoster.opacity > 0 else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = startupPoster.presentation()?.opacity ?? startupPoster.opacity
        fade.toValue = 0
        fade.duration = 0.12
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        startupPoster.opacity = 0
        CATransaction.commit()
        startupPoster.add(fade, forKey: "first-metal-video-frame")
    }

    func receive(_ buffer: CVPixelBuffer) {
        latestBuffer = buffer
        draw()
    }

    func unsubscribe() {
        MetalVideoPreviewHub.shared.unsubscribe(identity)
        streamKey = nil
        latestBuffer = nil
        hasLiveFrame = false
        startupPoster.removeAllAnimations()
        showStartupPoster(nil)
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
        let resources = MetalVideoRenderResources.shared
        guard let buffer = latestBuffer, let drawable = currentDrawable,
              let commandBuffer = resources.queue?.makeCommandBuffer(),
              let imageContext = resources.imageContext else { return }
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
                            bounds: target, colorSpace: resources.colorSpace)
        commandBuffer.present(drawable)
        if !hasLiveFrame {
            let presentedKey = streamKey
            commandBuffer.addCompletedHandler { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.streamKey == presentedKey else { return }
                    self.hasLiveFrame = true
                    self.dismissStartupPoster()
                }
            }
        }
        commandBuffer.commit()
        MetalPreviewDiagnostics.shared.recordEncode(
            milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000,
            at: ProcessInfo.processInfo.systemUptime)
    }
}

/// Uses display refresh notifications rather than a main-run-loop Timer.
/// CVDisplayLink invokes its callback off-main, so at most one sample request
/// is queued for the main actor at once. Stale notifications are discarded
/// instead of piling up when SwiftUI or Core Image temporarily blocks main.
private final class MetalPreviewDisplayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var link: CVDisplayLink?
    private let tick: () -> Void

    init(tick: @escaping () -> Void) { self.tick = tick }

    func start() -> Bool {
        var created: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&created) == kCVReturnSuccess,
              let created else { return false }
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context in
            guard let context else { return kCVReturnError }
            let clock = Unmanaged<MetalPreviewDisplayClock>.fromOpaque(context).takeUnretainedValue()
            clock.enqueue()
            return kCVReturnSuccess
        }
        guard CVDisplayLinkSetOutputCallback(created, callback,
                  Unmanaged.passUnretained(self).toOpaque()) == kCVReturnSuccess,
              CVDisplayLinkStart(created) == kCVReturnSuccess else { return false }
        link = created
        return true
    }

    private func enqueue() {
        lock.lock()
        let shouldQueue = !pending
        if shouldQueue { pending = true }
        lock.unlock()
        guard shouldQueue else { return }
        DispatchQueue.main.async { [self] in
            lock.lock()
            pending = false
            lock.unlock()
            tick()
        }
    }

    func stop() {
        if let link { CVDisplayLinkStop(link) }
        link = nil
    }

    deinit { stop() }
}

/// Samples each unique audience source at the requested Metal video rate.
/// A shared compositor is still needed to encode all layers in one pass.
@MainActor
final class MetalVideoPreviewHub {
    static let shared = MetalVideoPreviewHub()
    private final class WeakView {
        weak var view: MetalVideoSnapshotView?
        init(_ view: MetalVideoSnapshotView) { self.view = view }
    }
    private var previews: [UUID: WeakView] = [:]
    private var displayClock: MetalPreviewDisplayClock?
    private var timer: Timer?
    private var lastSampleTime: TimeInterval = 0
    private init() {}

    func subscribe(_ view: MetalVideoSnapshotView) {
        previews[view.identity] = WeakView(view)
        if displayClock == nil && timer == nil {
            let clock = MetalPreviewDisplayClock { [weak self] in
                MainActor.assumeIsolated { self?.sampleIfDue() }
            }
            if clock.start() {
                displayClock = clock
                return
            }
            // Headless displays and some remote desktop sessions cannot
            // create CVDisplayLink. Keep the original timing path available.
            let next = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampleIfDue() }
            }
            next.tolerance = 0.005
            RunLoop.main.add(next, forMode: .common)
            timer = next
        }
    }

    func unsubscribe(_ id: UUID) {
        previews.removeValue(forKey: id)
        if previews.isEmpty { stopClock() }
    }

    private func stopClock() {
        displayClock?.stop()
        displayClock = nil
        timer?.invalidate()
        timer = nil
        lastSampleTime = 0
    }

    private func sampleIfDue() {
        let now = ProcessInfo.processInfo.systemUptime
        let fps = MetalVideoFrameRate.validated(UserDefaults.standard.integer(forKey: "metalTargetFPS"))
        MetalPreviewDiagnostics.shared.configure(frameRate: fps)
        // Small slack accommodates 59.94 Hz and display-link scheduling jitter.
        guard lastSampleTime == 0 || now - lastSampleTime >= (1.0 / Double(fps)) * 0.90 else { return }
        lastSampleTime = now
        sample()
    }

    private func sample() {
        previews = previews.filter { $0.value.view?.streamKey != nil }
        guard !previews.isEmpty else { stopClock(); return }
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
