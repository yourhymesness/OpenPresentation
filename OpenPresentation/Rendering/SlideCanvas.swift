import AppKit
import SwiftUI

/// Avoid repeatedly decoding the same imported image as Program, editor and
/// thumbnail surfaces refresh during an animated workspace change.
private enum MediaImageCache {
    static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 60
        return cache
    }()
    static func image(for data: Data) -> NSImage? {
        // Sample a bounded number of bytes; hashing every frame's entire GIF
        // or high-res PNG would cost more than the cache saves.
        let key = "\(data.count)-\(data.prefix(96).hashValue)-\(data.suffix(96).hashValue)" as NSString
        if let cached = shared.object(forKey: key) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        shared.setObject(image, forKey: key)
        return image
    }
}

enum OutputScaleMode: String, CaseIterable, Identifiable {
    case fit = "Fit"
    case fill = "Fill"
    var id: String { rawValue }
}

extension SlideTextAlignment {
    var swiftUIAlignment: TextAlignment {
        switch self {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

/// When the outgoing and incoming slide share the same continuous video
/// background, keep that one decoder on an unfaded layer while only the text,
/// images, and other content dissolve. Avoids a false video fade-to-zero.
enum SharedBackgroundVideoMode {
    case normal
    case contentWithoutSharedBackground
    case sharedBackgroundOnly
    /// Background and foreground are crossfaded independently so identical
    /// colors never dip in brightness midway through a dissolve.
    case backgroundOnly
    case foregroundOnly
}

/// Shared renderer for thumbnails, Preview, Program and external output.
/// Editor drawing and live drawing use precisely the same layer geometry.
struct SlideCanvas: View {
    let slide: PresentationSlide?
    var isBlackout: Bool = false
    var isCleared: Bool = false
    var scaleMode: OutputScaleMode = .fit
    var constrainTo16x9: Bool = true
    /// Previews and full Program transition frames are flattened against the
    /// audience's black output. A slide's underlying alpha is not modified.
    /// Shared-background video overlays deliberately leave this false.
    var showTransparencyOnBlack: Bool = false
    /// Editor/thumbnail indicator only, never presented to the audience.
    var showTransparencyCheckerboard: Bool = false
    // Only the live Program surface needs active decoding. Thumbnails, the
    // editor and Preview display a placeholder so they don't consume players.
    var playsVideo: Bool = false
    // Only the actual Audience Output window may emit audio; the small
    // Program monitor never does, preventing duplicate sound on one Mac.
    var allowsVideoAudio: Bool = false
    /// Unique renderer scope so multiple simultaneous output windows never steal AVPlayerLayers.
    var outputScope: String = "program"
    /// 0...1 fade of soundtrack across slide transitions; visuals use opacity.
    var transitionAudioGain: Double = 1.0
    /// Used only for uninterrupted shared-background media during a cue crossfade.
    var cueAudioGainOverride: Double? = nil
    private var cueAudioGain: Double {
        cueAudioGainOverride ?? (slide?.resolvedCueAudioGain ?? 1)
    }
    /// Shared media can continue at full volume across slide takes.
    var continuingVideoPaths: Set<String> = []
    var sharedBackgroundMode: SharedBackgroundVideoMode = .normal
    /// A session distinguishes a fresh video take from a cached old decoder.
    var videoSessions: [String: UUID] = [:]

    @ViewBuilder var body: some View {
        if constrainTo16x9 {
            canvas.aspectRatio(16.0 / 9.0, contentMode: .fit)
        } else {
            canvas
        }
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let width = geometry.size.width.isFinite ? min(max(geometry.size.width, 1), 8192) : 1920.0
            let height = geometry.size.height.isFinite ? min(max(geometry.size.height, 1), 8192) : 1080.0
            let fitScale = min(width / 1920.0, height / 1080.0)
            let fillScale = max(width / 1920.0, height / 1080.0)
            let scale = scaleMode == .fit ? fitScale : fillScale
            let canvasWidth = 1920.0 * scale
            let canvasHeight = 1080.0 * scale

            ZStack {
                if showTransparencyCheckerboard && (slide?.isVisuallyTransparentBackground ?? false) {
                    TransparencyCheckerboard()
                } else if showTransparencyOnBlack {
                    Color.black
                } else {
                    Color.clear
                }
                ZStack(alignment: .topLeading) {
                    let backgroundIsShared = slide?.backgroundVideoPath.map {
                        continuingVideoPaths.contains(VideoTakePlanner.canonical($0))
                    } ?? false
                    if sharedBackgroundMode == .normal || sharedBackgroundMode == .backgroundOnly ||
                        (sharedBackgroundMode == .contentWithoutSharedBackground && !backgroundIsShared) {
                        // A transparent source becomes the black *output* backing
                        // during the background pass, so a dissolve into an
                        // empty slide fades to black instead of snapping there.
                        Color(hex: (isCleared || isBlackout ||
                                    (sharedBackgroundMode == .backgroundOnly &&
                                     (slide?.isVisuallyTransparentBackground ?? false)))
                              ? "#000000" : (slide?.backgroundHex ?? "#00000000"))
                            .frame(width: canvasWidth, height: canvasHeight)
                    }

                    if let path = slide?.backgroundVideoPath, !isBlackout && !isCleared,
                       (sharedBackgroundMode == .normal || sharedBackgroundMode == .backgroundOnly ||
                        (sharedBackgroundMode == .sharedBackgroundOnly && backgroundIsShared) ||
                        (sharedBackgroundMode == .contentWithoutSharedBackground && !backgroundIsShared)) {
                        videoFrame(path: path,
                                   behavior: slide?.resolvedBackgroundVideoEndBehavior ?? .loop,
                                   fade: slide?.resolvedBackgroundVideoFadeDuration ?? 0.75,
                                   audible: slide?.backgroundVideoAudioEnabled ?? false,
                                   volume: slide?.resolvedBackgroundVideoVolume ?? 1.0,
                                   contentMode: .fill, width: canvasWidth, height: canvasHeight,
                                   sourceSlot: "background")
                    } else if (sharedBackgroundMode == .normal || sharedBackgroundMode == .backgroundOnly ||
                               sharedBackgroundMode == .contentWithoutSharedBackground) &&
                              !backgroundIsShared && !isCleared && !isBlackout,
                              let data = slide?.backgroundImageData, let image = MediaImageCache.image(for: data) {
                        if playsVideo && AnimatedGIFImage.isGIF(data) {
                            AnimatedGIFImage(data: data)
                                .frame(width: canvasWidth, height: canvasHeight)
                                .clipped()
                        } else {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: canvasWidth, height: canvasHeight)
                                .clipped()
                        }
                    }

                    if sharedBackgroundMode != .sharedBackgroundOnly && sharedBackgroundMode != .backgroundOnly,
                       let slide, !isBlackout && !isCleared {
                        ForEach(slide.layers) { layer in
                            if layer.isVisible {
                                layerView(layer, scale: scale,
                                          canvasWidth: canvasWidth, canvasHeight: canvasHeight)
                            }
                        }
                    }
                    if sharedBackgroundMode != .sharedBackgroundOnly && sharedBackgroundMode != .foregroundOnly && isBlackout {
                        Color.black.frame(width: canvasWidth, height: canvasHeight)
                    }
                }
                .frame(width: canvasWidth, height: canvasHeight)
            }
            .frame(width: width, height: height)
            .clipped()
        }
        .background(Color.clear)
    }

    @ViewBuilder private func layerView(_ layer: SlideLayer, scale: CGFloat,
                                         canvasWidth: CGFloat, canvasHeight: CGFloat) -> some View {
        let boxWidth = max(1, CGFloat(layer.width) * canvasWidth)
        let boxHeight = max(1, CGFloat(layer.height) * canvasHeight)
        let x = CGFloat(layer.centerX) * canvasWidth
        let y = CGFloat(layer.centerY) * canvasHeight
        switch layer.kind {
        case .text:
            Text(layer.text)
                .font(.custom(layer.fontFamily, size: max(5, CGFloat(layer.fontSize) * scale)))
                .foregroundStyle(Color(hex: layer.textColorHex))
                .multilineTextAlignment(layer.textAlignment.swiftUIAlignment)
                .minimumScaleFactor(0.25)
                .lineLimit(nil)
                .frame(width: boxWidth, height: boxHeight, alignment: .center)
                .clipped()
                .position(x: x, y: y)
                .opacity(layer.resolvedOpacity)
        case .shape:
            SlideVectorShape(kind: layer.resolvedShapeKind)
                .fill(Color(hex: layer.resolvedShapeFill))
                .overlay {
                    SlideVectorShape(kind: layer.resolvedShapeKind)
                        .stroke(Color(hex: layer.resolvedShapeStroke),
                                lineWidth: CGFloat(layer.resolvedShapeStrokeWidth) * scale)
                }
                .frame(width: boxWidth, height: boxHeight)
                .position(x: x, y: y)
                .opacity(layer.resolvedOpacity)
        case .image:
            if let data = layer.imageData, let image = MediaImageCache.image(for: data) {
                Group {
                    if playsVideo && AnimatedGIFImage.isGIF(data) {
                        AnimatedGIFImage(data: data, contentMode: layer.resolvedContentMode)
                    } else {
                        switch layer.resolvedContentMode {
                        case .fit:
                            Image(nsImage: image).resizable().scaledToFit()
                        case .fill:
                            Image(nsImage: image).resizable().scaledToFill()
                        case .stretch:
                            Image(nsImage: image).resizable()
                        }
                    }
                }
                .frame(width: boxWidth, height: boxHeight)
                .clipped()
                .position(x: x, y: y)
                .opacity(layer.resolvedOpacity)
            }
        case .video:
            if let path = layer.videoPath {
                videoFrame(path: path, behavior: layer.resolvedVideoEndBehavior,
                           fade: layer.resolvedVideoFadeDuration,
                           audible: layer.videoAudioEnabled ?? false,
                           volume: layer.resolvedVideoVolume,
                           contentMode: layer.resolvedContentMode, width: boxWidth, height: boxHeight,
                           sourceSlot: "layer-\(slide?.layers.prefix(while: { $0.id != layer.id }).filter { $0.kind == .video && $0.videoPath == path }.count ?? 0)")
                    .position(x: x, y: y)
                    .opacity(layer.resolvedOpacity)
            }
        case .audio:
            if let path = layer.audioPath, playsVideo, !isBlackout, !isCleared {
                AudioPlaybackSurface(path: path,
                                     playbackSessionID: videoSessions[VideoTakePlanner.canonical(path)] ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                                     outputScope: outputScope,
                                     audible: allowsVideoAudio,
                                     volume: layer.resolvedAudioVolume * cueAudioGain * (continuingVideoPaths.contains(VideoTakePlanner.canonical(path)) ? 1.0 : transitionAudioGain),
                                     loops: layer.audioLoops ?? false)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private func videoFrame(path: String, behavior: VideoEndBehavior,
                                         fade: Double, audible: Bool, volume: Double,
                                         contentMode: LayerContentMode, width: CGFloat, height: CGFloat,
                                         sourceSlot: String) -> some View {
        if !FileManager.default.fileExists(atPath: path) {
            ZStack {
                Color.black
                Label("Missing video", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .frame(width: width, height: height)
        } else if playsVideo {
            VideoPlaybackSurface(path: path,
                                 playbackSessionID: videoSessions[VideoTakePlanner.canonical(path)] ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                                 behavior: behavior, fadeDuration: fade,
                                 audioEnabled: audible && allowsVideoAudio,
                                 volume: volume, contentMode: contentMode,
                                 outputScope: outputScope, sourceSlot: sourceSlot,
                                 audioGain: cueAudioGain * (continuingVideoPaths.contains(URL(fileURLWithPath: path).standardizedFileURL.path)
                                     ? 1.0 : transitionAudioGain))
                .frame(width: width, height: height)
                .clipped()
        } else {
            ZStack {
                Color(red: 0.08, green: 0.10, blue: 0.14)
                VStack(spacing: 8) {
                    Image(systemName: "film.fill")
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.75))
                .font(.caption)
                .padding(8)
            }
            .frame(width: width, height: height)
            .clipped()
        }
    }
}

/// Neutral transparency pattern, shown only in the editor and slide library.
private struct TransparencyCheckerboard: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 14
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(white: 0.16)))
            for row in 0..<Int(ceil(size.height / tile)) {
                for col in 0..<Int(ceil(size.width / tile)) where (row + col).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(col) * tile, y: CGFloat(row) * tile,
                                      width: tile, height: tile)
                    context.fill(Path(rect), with: .color(Color(white: 0.26)))
                }
            }
        }
        .accessibilityLabel("Transparent background")
    }
}

/// Vector geometry renders identically on the editor, Program and Audience.
private struct SlideVectorShape: Shape {
    let kind: SlideShapeKind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .rectangle, .square:
            path.addRect(rect)
        case .roundedRectangle:
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: min(rect.width, rect.height) * 0.15,
                                                             height: min(rect.width, rect.height) * 0.15))
        case .ellipse, .circle:
            path.addEllipse(in: rect)
        case .triangle, .equilateralTriangle:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// Identical renderer for the operator's Program monitor and the actual audience
/// window. Timeline dates are shared wall-clock values, so neither surface
/// independently starts its own animation when a slide is taken live.
@MainActor
struct ProgramCanvas: View {
    @ObservedObject var controller: ShowController
    var scaleMode: OutputScaleMode = .fit
    var constrainTo16x9: Bool = true
    var isAudienceOutput: Bool = false
    var outputScope: String = "program"


    private func audioGains(for transition: ProgramTransition, at date: Date) -> (old: Double, new: Double) {
        let progress = transition.progress(at: date)
        switch transition.style {
        case .cut:
            return (0, 1)
        case .dissolve:
            return (1 - progress, progress)
        case .fadeThroughBlack:
            return (max(0, 1 - 2 * progress), max(0, 2 * progress - 1))
        }
    }

    var body: some View {
        TimelineView(.animation(paused: controller.activeTransition == nil)) { timeline in
            ZStack {
                // Physical displays show black for transparency. The slide
                // canvas itself retains alpha for future keyed output.
                Color.black
                if let transition = controller.activeTransition {
                    let alpha = transition.opacities(at: timeline.date)
                    let gains = audioGains(for: transition, at: timeline.date)
                    let continuing = Set(transition.to.videoSessions.compactMap { path, session in
                        transition.from.videoSessions[path] == session ? path : nil
                    })
                    let sharedBackground: String? = {
                        guard !transition.from.isBlackout, !transition.from.isCleared,
                              !transition.to.isBlackout, !transition.to.isCleared,
                              let outgoing = transition.from.slide?.backgroundVideoPath,
                              let incoming = transition.to.slide?.backgroundVideoPath,
                              VideoTakePlanner.canonical(outgoing) == VideoTakePlanner.canonical(incoming),
                              continuing.contains(VideoTakePlanner.canonical(incoming)) else { return nil }
                        return incoming
                    }()
                    // Keep a continuous background video visible at full
                    // opacity while the foreground slides dissolve above it.
                    if sharedBackground != nil {
                        SlideCanvas(slide: transition.to.slide,
                                    scaleMode: scaleMode,
                                    constrainTo16x9: constrainTo16x9,
                                    // Shared video is already drawn under this overlay.
                                    playsVideo: true,
                                    allowsVideoAudio: isAudienceOutput,
                                    outputScope: outputScope,
                                    cueAudioGainOverride: (transition.from.slide?.resolvedCueAudioGain ?? 1) * (1 - transition.progress(at: timeline.date))
                                        + (transition.to.slide?.resolvedCueAudioGain ?? 1) * transition.progress(at: timeline.date),
                                    continuingVideoPaths: continuing,
                                    sharedBackgroundMode: .sharedBackgroundOnly,
                                    videoSessions: transition.to.videoSessions)
                    }
                    if transition.style == .dissolve && sharedBackground == nil {
                        // A full-frame (outgoing: 1-p, incoming: p) crossfade
                        // over black lowers brightness even for identical opaque
                        // backgrounds: 1 - p*(1-p). Keep the outgoing background
                        // solid and dissolve the destination over it instead.
                        SlideCanvas(slide: transition.from.slide,
                                    isBlackout: transition.from.isBlackout,
                                    isCleared: transition.from.isCleared,
                                    scaleMode: scaleMode,
                                    constrainTo16x9: constrainTo16x9,
                                    playsVideo: true,
                                    allowsVideoAudio: isAudienceOutput,
                                    outputScope: outputScope,
                                    transitionAudioGain: gains.old,
                                    continuingVideoPaths: continuing,
                                    sharedBackgroundMode: .backgroundOnly,
                                    videoSessions: transition.from.videoSessions)
                        SlideCanvas(slide: transition.to.slide,
                                    isBlackout: transition.to.isBlackout,
                                    isCleared: transition.to.isCleared,
                                    scaleMode: scaleMode,
                                    constrainTo16x9: constrainTo16x9,
                                    playsVideo: true,
                                    allowsVideoAudio: isAudienceOutput,
                                    outputScope: outputScope,
                                    transitionAudioGain: gains.new,
                                    continuingVideoPaths: continuing,
                                    sharedBackgroundMode: .backgroundOnly,
                                    videoSessions: transition.to.videoSessions)
                            .opacity(transition.progress(at: timeline.date))
                        SlideCanvas(slide: transition.from.slide,
                                    isBlackout: transition.from.isBlackout,
                                    isCleared: transition.from.isCleared,
                                    scaleMode: scaleMode,
                                    constrainTo16x9: constrainTo16x9,
                                    playsVideo: true,
                                    allowsVideoAudio: isAudienceOutput,
                                    outputScope: outputScope,
                                    transitionAudioGain: gains.old,
                                    continuingVideoPaths: continuing,
                                    sharedBackgroundMode: .foregroundOnly,
                                    videoSessions: transition.from.videoSessions)
                            .opacity(alpha.outgoing)
                        SlideCanvas(slide: transition.to.slide,
                                    isBlackout: transition.to.isBlackout,
                                    isCleared: transition.to.isCleared,
                                    scaleMode: scaleMode,
                                    constrainTo16x9: constrainTo16x9,
                                    playsVideo: true,
                                    allowsVideoAudio: isAudienceOutput,
                                    outputScope: outputScope,
                                    transitionAudioGain: gains.new,
                                    continuingVideoPaths: continuing,
                                    sharedBackgroundMode: .foregroundOnly,
                                    videoSessions: transition.to.videoSessions)
                            .opacity(alpha.incoming)
                    } else {
                    SlideCanvas(slide: transition.from.slide,
                                isBlackout: transition.from.isBlackout,
                                isCleared: transition.from.isCleared,
                                scaleMode: scaleMode,
                                constrainTo16x9: constrainTo16x9,
                                showTransparencyOnBlack: sharedBackground == nil,
                                playsVideo: true,
                                allowsVideoAudio: isAudienceOutput,
                                outputScope: outputScope,
                                transitionAudioGain: gains.old,
                                continuingVideoPaths: continuing,
                                sharedBackgroundMode: sharedBackground == nil ? .normal : .contentWithoutSharedBackground,
                                videoSessions: transition.from.videoSessions)
                        .opacity(sharedBackground == nil ? alpha.outgoing : (1 - transition.progress(at: timeline.date)))
                    SlideCanvas(slide: transition.to.slide,
                                isBlackout: transition.to.isBlackout,
                                isCleared: transition.to.isCleared,
                                scaleMode: scaleMode,
                                constrainTo16x9: constrainTo16x9,
                                showTransparencyOnBlack: sharedBackground == nil,
                                playsVideo: true,
                                allowsVideoAudio: isAudienceOutput,
                                outputScope: outputScope,
                                transitionAudioGain: gains.new,
                                continuingVideoPaths: continuing,
                                sharedBackgroundMode: sharedBackground == nil ? .normal : .contentWithoutSharedBackground,
                                videoSessions: transition.to.videoSessions)
                        .opacity(alpha.incoming)
                    }
                } else {
                    SlideCanvas(slide: controller.liveSlide,
                                isBlackout: controller.isBlackout,
                                isCleared: controller.isCleared,
                                scaleMode: scaleMode,
                                constrainTo16x9: constrainTo16x9,
                                showTransparencyOnBlack: true,
                                playsVideo: true,
                                allowsVideoAudio: isAudienceOutput,
                                outputScope: outputScope,
                                videoSessions: controller.liveVideoSessions)
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .transaction { transaction in
                // Only timeline-calculated alpha should animate; prevent
                // SwiftUI from interpolating text font/layout geometry during
                // a Program transition or relayout.
                transaction.disablesAnimations = true
            }
        }
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        // Accept #RRGGBB and #RRGGBBAA (red/green/blue/alpha),
        // preserving transparency in new blank slides.
        guard (cleaned.count == 6 || cleaned.count == 8),
              let raw = UInt64(cleaned, radix: 16) else {
            self = Color.clear
            return
        }
        let rgb = cleaned.count == 8 ? raw >> 8 : raw
        let alpha = cleaned.count == 8 ? Double(raw & 0xFF) / 255 : 1.0
        self = Color(.sRGB,
                     red: Double((rgb >> 16) & 0xFF) / 255,
                     green: Double((rgb >> 8) & 0xFF) / 255,
                     blue: Double(rgb & 0xFF) / 255,
                     opacity: alpha)
    }
}
