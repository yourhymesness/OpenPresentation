import Foundation

/// Width/height of a presentation's authored coordinate space. Layers keep
/// normalized coordinates so older 1920x1080 shows remain geometrically intact.
struct ShowCanvasSize: Equatable, Hashable, Codable {
    static let fullHD = ShowCanvasSize(width: 1920, height: 1080)
    static let minimum = 64
    static let maximum = 8192
    var width: Int
    var height: Int

    init(width: Int, height: Int) {
        self.width = min(Self.maximum, max(Self.minimum, width))
        self.height = min(Self.maximum, max(Self.minimum, height))
    }

    var ratio: Double { Double(width) / Double(height) }
    var sizeLabel: String { "\(width) × \(height)" }
    var ratioLabel: String {
        let divisor = Self.gcd(width, height)
        return "\(width / divisor):\(height / divisor)"
    }
    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = a, y = b
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }
    // Decode through the clamping initializer even for hand-edited JSON.
    private enum CodingKeys: String, CodingKey { case width, height }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(width: try container.decode(Int.self, forKey: .width),
                  height: try container.decode(Int.self, forKey: .height))
    }
}

/// Curated video formats, plus custom pixels for unusual LED walls and signs.
enum ShowCanvasPreset: String, CaseIterable, Identifiable {
    case fullHD, hd, ultraHD, portraitHD, portrait4K, squareHD, square4K
    case wide2560, wide3072, wide3840, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fullHD: return "Full HD · 1920 × 1080 (16:9)"
        case .hd: return "HD · 1280 × 720 (16:9)"
        case .ultraHD: return "4K · 3840 × 2160 (16:9)"
        case .portraitHD: return "Portrait · 1080 × 1920 (9:16)"
        case .portrait4K: return "Portrait 4K · 2160 × 3840 (9:16)"
        case .squareHD: return "Square · 1080 × 1080 (1:1)"
        case .square4K: return "Square 4K · 2160 × 2160 (1:1)"
        case .wide2560: return "LED Wide · 2560 × 720"
        case .wide3072: return "LED Wide · 3072 × 768"
        case .wide3840: return "Ultra Wide · 3840 × 1080"
        case .custom: return "Custom dimensions…"
        }
    }
    var size: ShowCanvasSize? {
        switch self {
        case .fullHD: return .fullHD
        case .hd: return ShowCanvasSize(width: 1280, height: 720)
        case .ultraHD: return ShowCanvasSize(width: 3840, height: 2160)
        case .portraitHD: return ShowCanvasSize(width: 1080, height: 1920)
        case .portrait4K: return ShowCanvasSize(width: 2160, height: 3840)
        case .squareHD: return ShowCanvasSize(width: 1080, height: 1080)
        case .square4K: return ShowCanvasSize(width: 2160, height: 2160)
        case .wide2560: return ShowCanvasSize(width: 2560, height: 720)
        case .wide3072: return ShowCanvasSize(width: 3072, height: 768)
        case .wide3840: return ShowCanvasSize(width: 3840, height: 1080)
        case .custom: return nil
        }
    }
}

/// Every foreground element has the same position, size and stacking model.
/// Coordinates are normalized to the current show's canvas; layers are
/// ordered back-to-front, so the last layer is visually on top.
/// What happens when a finite video reaches its end.
/// Soft loop overlaps the outgoing and incoming video by `videoFadeDuration`.
enum VideoEndBehavior: String, Codable, CaseIterable, Identifiable {
    case loop = "Loop"
    case softLoop = "Soft Loop"
    case holdLastFrame = "Hold Last Frame"
    case fadeOut = "Fade Out"
    case fadeToBlack = "Fade to Black"

    var id: String { rawValue }
    var usesFadeTime: Bool { self == .softLoop || self == .fadeOut || self == .fadeToBlack }
}

/// What a video should do when the operator takes another slide.
/// This is independent from what happens at the END of the video file.
enum VideoTakeBehavior: String, Codable, CaseIterable, Identifiable {
    /// Normal presentation behavior: uninterrupted only across directly adjacent
    /// slides that both reference the same video file.
    case continueOnConsecutive = "Continue on Consecutive Slides"
    /// Always create a new playback instance when this slide is taken.
    case restartEachTake = "Restart on Every Take"

    var id: String { rawValue }
}

/// How the pixels within an image/video frame are mapped into its rectangle.
/// Stored on the layer so that Preview and Program render identically.
enum LayerContentMode: String, Codable, CaseIterable {
    case fit, fill, stretch
}

enum LayerScalePreset: String, CaseIterable {
    case fit = "Scale to Fit Slide"
    case fill = "Scale to Fill Slide (Crop)"
    case stretch = "Stretch to Fill Slide"
    case original = "Original Pixel Size"
}

enum SlideLayerKind: String, Codable {
    case text
    case image
    case video
    case audio
    case shape
}

/// Vector shapes remain resolution-independent in Preview and Program.
enum SlideShapeKind: String, Codable, CaseIterable, Identifiable {
    case rectangle = "Rectangle"
    case roundedRectangle = "Rounded Rectangle"
    case ellipse = "Ellipse"
    case triangle = "Triangle"
    case square = "Square"
    case circle = "Circle"
    case equilateralTriangle = "Equilateral Triangle"
    var id: String { rawValue }

    /// Pixel width / pixel height for constrained shapes. The standard
    /// Rectangle / Ellipse / Triangle still allow unconstrained frames.
    var intrinsicPixelAspect: Double? {
        switch self {
        case .square, .circle: return 1
        case .equilateralTriangle: return 2 / sqrt(3)
        default: return nil
        }
    }
}

enum LayerOrderAction: String, CaseIterable {
    case forward = "Bring Forward"
    case backward = "Send Backward"
    case front = "Bring to Front"
    case back = "Send to Back"
}

/// Array order is back-to-front; the inspector displays it in reverse.
enum LayerOrdering {
    static func apply(_ action: LayerOrderAction, id: UUID, layers: inout [SlideLayer]) {
        guard let from = layers.firstIndex(where: { $0.id == id }), !layers[from].isLocked else { return }
        let to: Int
        switch action {
        case .front: to = layers.count - 1
        case .back: to = 0
        case .forward: to = min(layers.count - 1, from + 1)
        case .backward: to = max(0, from - 1)
        }
        guard from != to else { return }
        let element = layers.remove(at: from)
        layers.insert(element, at: to)
    }

    /// Drop on a row to place the dragged layer at that row's stacking level.
    static func drag(_ id: UUID, onto targetID: UUID, layers: inout [SlideLayer]) {
        guard id != targetID,
              let from = layers.firstIndex(where: { $0.id == id }),
              let to = layers.firstIndex(where: { $0.id == targetID }),
              !layers[from].isLocked else { return }
        let element = layers.remove(at: from)
        let targetIndex = layers.firstIndex(where: { $0.id == targetID }) ?? layers.count
        // Hovering over an upper row puts the dragged row above it, and
        // hovering over a lower row puts the dragged row below it.
        layers.insert(element, at: from < to ? min(layers.count, targetIndex + 1) : targetIndex)
    }
}

enum SlideTextAlignment: String, Codable, CaseIterable, Identifiable {
    case left = "Left"
    case center = "Center"
    case right = "Right"
    var id: String { rawValue }
}

struct SlideLayer: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var kind: SlideLayerKind
    var isVisible: Bool = true
    var isLocked: Bool = false
    // nil preserves opacity = 100% for older show files.
    var opacity: Double? = nil
    /// A logical editor group; members retain individual geometry and render order.
    var groupID: UUID? = nil
    var resolvedOpacity: Double { min(1, max(0, opacity ?? 1)) }

    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var width: Double = 0.72
    var height: Double = 0.38

    // Optional so all earlier v5 shows remain decodable without migration.
    var contentMode: LayerContentMode? = nil
    var mediaPixelWidth: Double? = nil
    var mediaPixelHeight: Double? = nil
    /// Optional for backward compatibility with older v5 shows. A value of
    /// false allows independent X/Y resizing of text, shapes and media.
    var aspectRatioLocked: Bool? = nil
    /// Images/video preserve their frame ratio by default. Option-drag can
    /// temporarily override the lock; a user may also disable it in Inspector.
    /// Fixed-proportion shapes default to maintaining the correct geometry.
    var resolvedAspectRatioLocked: Bool {
        aspectRatioLocked ?? (kind == .image || kind == .video ||
            (kind == .shape && resolvedShapeKind.intrinsicPixelAspect != nil))
    }

    /// Temporarily unlock a constrained frame while dragging. A stretched
    /// image/video must also map its actual pixels into the new rectangle,
    /// otherwise Fit would just letterbox inside the distorted bounds.
    mutating func applyResizeModifier(freeStretch: Bool) {
        if freeStretch && (kind == .image || kind == .video) {
            contentMode = .stretch
        }
    }

    /// Changing shape type in the inspector makes Circle/Square/Equilateral
    /// geometrically correct even if the original was an arbitrary rectangle.
    /// Preserve the center and fit the converted shape within the slide.
    mutating func selectShape(_ shape: SlideShapeKind, canvasSize: ShowCanvasSize = .fullHD) {
        shapeKind = shape
        guard kind == .shape, let aspect = shape.intrinsicPixelAspect else { return }
        aspectRatioLocked = true
        let maxW = max(0.0001, 2 * min(centerX, 1 - centerX))
        let maxH = max(0.0001, 2 * min(centerY, 1 - centerY))
        let pixelW = min(width * Double(canvasSize.width), height * Double(canvasSize.height) * aspect,
                         maxW * Double(canvasSize.width), maxH * Double(canvasSize.height) * aspect)
        width = pixelW / Double(canvasSize.width)
        height = pixelW / aspect / Double(canvasSize.height)
    }

    var resolvedContentMode: LayerContentMode { contentMode ?? .fit }

    // Fit and Original use asset pixel dimensions when known. Otherwise they
    // use the active authored canvas, including for non-16:9 shows.
    mutating func applyScalePreset(_ preset: LayerScalePreset, pixelSize: CGSize? = nil,
                                   canvasSize: ShowCanvasSize = .fullHD) {
        if let pixelSize, pixelSize.width > 0, pixelSize.height > 0 {
            mediaPixelWidth = Double(pixelSize.width)
            mediaPixelHeight = Double(pixelSize.height)
        }
        let pixelsW = max(1, pixelSize?.width ?? mediaPixelWidth ?? Double(canvasSize.width))
        let pixelsH = max(1, pixelSize?.height ?? mediaPixelHeight ?? Double(canvasSize.height))
        let nativeW = Double(pixelsW) / Double(canvasSize.width)
        let nativeH = Double(pixelsH) / Double(canvasSize.height)
        switch preset {
        case .fit:
            if kind == .text {
                width = 0.9; height = 0.8
            } else {
                let factor = min(1 / nativeW, 1 / nativeH)
                width = nativeW * factor
                height = nativeH * factor
                contentMode = .fit
            }
        case .fill:
            width = 1; height = 1
            if kind != .text { contentMode = .fill }
        case .stretch:
            width = 1; height = 1
            if kind != .text { contentMode = .stretch }
        case .original:
            if kind == .text {
                width = 0.72; height = 0.38
            } else {
                width = nativeW; height = nativeH
                contentMode = .fit
            }
        }
        centerX = 0.5
        centerY = 0.5
    }

    // Only the fields appropriate to the kind are used by the renderer.
    var text: String = ""
    var fontFamily: String = "Helvetica Neue"
    var fontSize: Double = 112
    var textColorHex: String = "#FFFFFF"
    var textAlignment: SlideTextAlignment = .center
    // Optional so older v5 show files still decode with synthesized Codable.
    var shapeKind: SlideShapeKind? = nil
    var shapeFillHex: String? = nil
    var shapeStrokeHex: String? = nil
    var shapeStrokeWidth: Double? = nil
    var resolvedShapeKind: SlideShapeKind { shapeKind ?? .rectangle }
    var resolvedShapeFill: String { shapeFillHex ?? "#4F90D9" }
    var resolvedShapeStroke: String { shapeStrokeHex ?? "#FFFFFF" }
    var resolvedShapeStrokeWidth: Double { min(48, max(0, shapeStrokeWidth ?? 0)) }
    var imageData: Data? = nil
    // Video paths are local while editing. When a show is saved, ProjectStore
    // copies video files into a companion .media directory and records paths
    // relative to that directory in the JSON.
    var videoPath: String? = nil
    // Standalone audio layers have no visual pixels on the audience canvas.
    // Optional fields preserve compatibility with existing version-5 shows.
    var audioPath: String? = nil
    var audioLoops: Bool? = nil
    var audioVolume: Double? = nil
    var resolvedAudioVolume: Double { min(max(audioVolume ?? 1.0, 0), 1.0) }
    // nil means loop (preserves decoding of older shows without this field).
    var videoLoops: Bool? = nil
    // Optional for v0.2.2 project compatibility. When not present, videoLoops
    // selects Loop / Hold Last Frame, just as the old checkbox did.
    var videoEndBehavior: VideoEndBehavior? = nil
    var videoTakeBehavior: VideoTakeBehavior? = nil
    var videoFadeDuration: Double? = nil // seconds; 0.2...3.0 in UI
    var videoAudioEnabled: Bool? = nil // defaults to off for show safety
    var videoVolume: Double? = nil // 0...1; 1.0 by default

    var resolvedVideoTakeBehavior: VideoTakeBehavior { videoTakeBehavior ?? .continueOnConsecutive }
    var resolvedVideoEndBehavior: VideoEndBehavior {
        videoEndBehavior ?? ((videoLoops ?? true) ? .loop : .holdLastFrame)
    }
    var resolvedVideoFadeDuration: Double { min(max(videoFadeDuration ?? 0.75, 0.2), 3.0) }
    var resolvedVideoVolume: Double { min(max(videoVolume ?? 1.0, 0), 1.0) }

    static func makeText(_ text: String = "New Text Box", name: String = "Text Box",
                         color: String = "#FFFFFF", fontSize: Double = 100) -> SlideLayer {
        SlideLayer(name: name, kind: .text, width: 0.72, height: 0.38,
                   text: text, fontSize: fontSize, textColorHex: color)
    }

    static func makeImage(_ data: Data, width: Double, height: Double, name: String = "Image") -> SlideLayer {
        SlideLayer(name: name, kind: .image, width: width, height: height, imageData: data)
    }

    static func makeShape(_ kind: SlideShapeKind, canvasSize: ShowCanvasSize = .fullHD) -> SlideLayer {
        let size: (width: Double, height: Double)
        switch kind {
        case .square, .circle:
            let side = min(280.0, Double(min(canvasSize.width, canvasSize.height)) * 0.8)
            size = (side / Double(canvasSize.width), side / Double(canvasSize.height))
        case .equilateralTriangle:
            let side = min(320.0, Double(canvasSize.width) * 0.8,
                           Double(canvasSize.height) * 0.8 * 2 / sqrt(3))
            size = (side / Double(canvasSize.width), (side * sqrt(3) / 2) / Double(canvasSize.height))
        default:
            size = (0.30, 0.28)
        }
        return SlideLayer(name: kind.rawValue, kind: .shape,
                          width: size.width, height: size.height,
                          aspectRatioLocked: kind.intrinsicPixelAspect != nil ? true : nil,
                          shapeKind: kind, shapeFillHex: "#4F90D9",
                          shapeStrokeHex: "#FFFFFF", shapeStrokeWidth: 0)
    }

    static func makeAudio(path: String, name: String = "Audio") -> SlideLayer {
        SlideLayer(name: name, kind: .audio, width: 0.25, height: 0.15,
                   audioPath: path, audioLoops: false, audioVolume: 1.0)
    }

    static func makeVideo(path: String, name: String = "Video") -> SlideLayer {
        SlideLayer(name: name, kind: .video, width: 0.46, height: 0.46,
                   videoPath: path, videoLoops: true,
                   videoEndBehavior: .loop, videoTakeBehavior: .continueOnConsecutive, videoFadeDuration: 0.75,
                   videoAudioEnabled: false, videoVolume: 1.0)
    }
}

/// Old v0.1.4 JSON stored images separately from text. Only used for migration.
private struct LegacyImageLayer: Decodable {
    var id: UUID
    var imageData: Data
    var centerX: Double
    var centerY: Double
    var width: Double
    var height: Double
}

struct PresentationSlide: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var backgroundHex: String = "#00000000"
    /// Explicit opt-in for carrying a previous on-air background. Transparent
    /// by itself now means clear to black on the audience display.
    var retainPreviousBackground: Bool? = nil
    var backgroundImageData: Data? = nil
    var backgroundVideoPath: String? = nil
    var backgroundVideoEndBehavior: VideoEndBehavior? = nil
    var backgroundVideoTakeBehavior: VideoTakeBehavior? = nil
    var backgroundVideoFadeDuration: Double? = nil
    var backgroundVideoAudioEnabled: Bool? = nil
    var backgroundVideoVolume: Double? = nil

    /// Transparency is a visual property, not an instruction to reuse media.
    /// A transparent slide without opt-in is composited over the output's black
    /// backing. This keeps blank backgrounds deterministic across slide takes.
    var isVisuallyTransparentBackground: Bool {
        guard backgroundImageData == nil, backgroundVideoPath == nil else { return false }
        let color = backgroundHex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "").uppercased()
        return color.isEmpty || color == "TRANSPARENT" ||
            (color.count == 8 && color.hasSuffix("00"))
    }

    var inheritsProgramBackground: Bool {
        retainPreviousBackground == true && isVisuallyTransparentBackground
    }

    /// Produce a render-only copy; never overwrite the authored slide or its
    /// saved transparency. An inherited video keeps its source path and options.
    func preparedForProgram(after previous: PresentationSlide?) -> PresentationSlide {
        guard inheritsProgramBackground, let previous else { return self }
        var result = self
        result.backgroundHex = previous.backgroundHex
        result.backgroundImageData = previous.backgroundImageData
        result.backgroundVideoPath = previous.backgroundVideoPath
        result.backgroundVideoEndBehavior = previous.backgroundVideoEndBehavior
        result.backgroundVideoTakeBehavior = previous.backgroundVideoTakeBehavior
        result.backgroundVideoFadeDuration = previous.backgroundVideoFadeDuration
        result.backgroundVideoAudioEnabled = previous.backgroundVideoAudioEnabled
        result.backgroundVideoVolume = previous.backgroundVideoVolume
        return result
    }

    /// A slide's saved metadata (notes/title/collection/timing) does not
    /// change its on-air appearance. Compare only rendered pixels and audio
    /// when deciding whether a same-slide retake needs a transition.
    /// Compare render-ready snapshots so inherited transparent backgrounds
    /// don't falsely register as changes.
    func hasSameProgramContent(as other: PresentationSlide) -> Bool {
        backgroundHex == other.backgroundHex &&
        backgroundImageData == other.backgroundImageData &&
        backgroundVideoPath == other.backgroundVideoPath &&
        backgroundVideoEndBehavior == other.backgroundVideoEndBehavior &&
        backgroundVideoTakeBehavior == other.backgroundVideoTakeBehavior &&
        backgroundVideoFadeDuration == other.backgroundVideoFadeDuration &&
        backgroundVideoAudioEnabled == other.backgroundVideoAudioEnabled &&
        backgroundVideoVolume == other.backgroundVideoVolume &&
        layers == other.layers &&
        resolvedCueAudioGain == other.resolvedCueAudioGain
    }

    var resolvedBackgroundVideoTakeBehavior: VideoTakeBehavior { backgroundVideoTakeBehavior ?? .continueOnConsecutive }
    var resolvedBackgroundVideoEndBehavior: VideoEndBehavior { backgroundVideoEndBehavior ?? .loop }
    var resolvedBackgroundVideoFadeDuration: Double {
        min(max(backgroundVideoFadeDuration ?? 0.75, 0.2), 3.0)
    }
    var resolvedBackgroundVideoVolume: Double {
        min(max(backgroundVideoVolume ?? 1.0, 0), 1.0)
    }
    var layers: [SlideLayer] = []
    /// Operator-only title, independent of rendered slide text. Empty for
    /// older shows, which continue to fall back to their first text layer.
    var slideTitle: String = ""
    /// Operator-only show notes, never drawn in Program.
    var notes: String = ""
    /// Optional dwell time before advancing this slide. Nil = manual.
    var autoAdvanceSeconds: Double? = nil
    /// An active Auto Transition sequence advances untimed slides after 10 s.
    /// An explicit per-slide dwell overrides that default.
    var resolvedAutoAdvanceSeconds: Double {
        guard let autoAdvanceSeconds, autoAdvanceSeconds.isFinite,
              autoAdvanceSeconds >= 0.5 else { return 10 }
        return autoAdvanceSeconds
    }

    /// Override the show's default transition duration for this destination slide.
    /// Nil inherits the show's default; Cut is still instantaneous.
    var transitionSecondsOverride: Double? = nil
    /// Per-slide audio cue gain and mute. Snapshot during a take, unlike global faders.
    var cueAudioGain: Double = 1.0
    var cueAudioMuted: Bool = false
    var resolvedCueAudioGain: Double {
        cueAudioMuted ? 0 : (cueAudioGain.isFinite ? min(max(cueAudioGain, 0), 1) : 1)
    }

    /// Used only for the operator's mixer availability indication, not for
    /// measuring signal. A muted channel still contains audio media.
    /// Inherited Program backgrounds are resolved before this property is read.
    var containsAudioMedia: Bool {
        let backgroundAudio = backgroundVideoAudioEnabled == true &&
            (backgroundVideoPath?.isEmpty == false)
        let layerAudio = layers.contains { layer in
            guard layer.isVisible else { return false }
            switch layer.kind {
            case .audio:
                return layer.audioPath?.isEmpty == false
            case .video:
                return layer.videoAudioEnabled == true && layer.videoPath?.isEmpty == false
            default:
                return false
            }
        }
        return backgroundAudio || layerAudio
    }

    /// Optional collection membership; nil means Unfiled.
    var collectionID: UUID? = nil

    /// Full slide copy for the Blind library. Keeps all media and settings,
    /// but regenerates slide, layer, and group identities so edits to either
    /// copy never affect the other.
    func duplicatedForLibrary() -> PresentationSlide {
        var copy = self
        copy.id = UUID()
        var groups: [UUID: UUID] = [:]
        for i in copy.layers.indices {
            copy.layers[i].id = UUID()
            if let originalGroup = copy.layers[i].groupID {
                if groups[originalGroup] == nil { groups[originalGroup] = UUID() }
                copy.layers[i].groupID = groups[originalGroup]
            }
        }
        return copy
    }

    /// Render-only draft for the Blind font browser. The original slide and
    /// its stored font remain unchanged until the operator clicks Apply.
    /// Output and Program continue using their immutable saved/taken slides.
    func previewingFont(_ family: String?, onLayer layerID: UUID?) -> PresentationSlide {
        guard let family, !family.isEmpty, let layerID,
              let index = layers.firstIndex(where: { $0.id == layerID && $0.kind == .text })
        else { return self }
        var copy = self
        copy.layers[index].fontFamily = family
        return copy
    }

    var displayTitle: String {
        let saved = slideTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !saved.isEmpty { return saved }
        let firstText = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return firstText.isEmpty ? "Untitled slide" : firstText
    }

    /// Display label for the slide library, not a distinct rendered text element.
    var text: String {
        let title = layers.first(where: { $0.kind == .text })?.text ?? ""
        return title.isEmpty ? "Untitled slide" : title
    }

    init(id: UUID = UUID(), text: String, backgroundHex: String = "#00000000",
         foregroundHex: String = "#FFFFFF", fontSize: Double = 112,
         backgroundImageData: Data? = nil) {
        self.id = id
        self.backgroundHex = backgroundHex
        self.backgroundImageData = backgroundImageData
        if !text.isEmpty {
            layers = [.makeText(text, name: "Main Text", color: foregroundHex, fontSize: fontSize)]
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, backgroundHex, retainPreviousBackground, backgroundImageData, backgroundVideoPath, layers, notes, slideTitle, autoAdvanceSeconds, transitionSecondsOverride, cueAudioGain, cueAudioMuted, collectionID
        case backgroundVideoEndBehavior, backgroundVideoTakeBehavior, backgroundVideoFadeDuration
        case backgroundVideoAudioEnabled, backgroundVideoVolume
        // Pre-v0.1.5 slide structure:
        case text, foregroundHex, fontSize, imageLayers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        backgroundHex = try c.decodeIfPresent(String.self, forKey: .backgroundHex) ?? "#15263D"
        retainPreviousBackground = try c.decodeIfPresent(Bool.self, forKey: .retainPreviousBackground)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        autoAdvanceSeconds = try c.decodeIfPresent(Double.self, forKey: .autoAdvanceSeconds)
        transitionSecondsOverride = try c.decodeIfPresent(Double.self, forKey: .transitionSecondsOverride)
        cueAudioGain = try c.decodeIfPresent(Double.self, forKey: .cueAudioGain) ?? 1.0
        cueAudioMuted = try c.decodeIfPresent(Bool.self, forKey: .cueAudioMuted) ?? false
        collectionID = try c.decodeIfPresent(UUID.self, forKey: .collectionID)
        slideTitle = try c.decodeIfPresent(String.self, forKey: .slideTitle) ?? ""
        backgroundImageData = try c.decodeIfPresent(Data.self, forKey: .backgroundImageData)
        backgroundVideoPath = try c.decodeIfPresent(String.self, forKey: .backgroundVideoPath)
        backgroundVideoEndBehavior = try c.decodeIfPresent(VideoEndBehavior.self, forKey: .backgroundVideoEndBehavior)
        backgroundVideoTakeBehavior = try c.decodeIfPresent(VideoTakeBehavior.self, forKey: .backgroundVideoTakeBehavior)
        backgroundVideoFadeDuration = try c.decodeIfPresent(Double.self, forKey: .backgroundVideoFadeDuration)
        backgroundVideoAudioEnabled = try c.decodeIfPresent(Bool.self, forKey: .backgroundVideoAudioEnabled)
        backgroundVideoVolume = try c.decodeIfPresent(Double.self, forKey: .backgroundVideoVolume)

        if let modernLayers = try c.decodeIfPresent([SlideLayer].self, forKey: .layers) {
            layers = modernLayers
        } else {
            // Reconstruct old centered slide text as an editable text-box layer,
            // and preserve positions and stacking of older image objects.
            let oldText = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            let color = try c.decodeIfPresent(String.self, forKey: .foregroundHex) ?? "#FFFFFF"
            let size = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 112
            layers = oldText.isEmpty ? [] : [.makeText(oldText, name: "Main Text", color: color, fontSize: size)]
            let images = try c.decodeIfPresent([LegacyImageLayer].self, forKey: .imageLayers) ?? []
            for old in images {
                var image = SlideLayer.makeImage(old.imageData, width: old.width, height: old.height)
                image.id = old.id
                image.centerX = old.centerX
                image.centerY = old.centerY
                layers.append(image)
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(backgroundHex, forKey: .backgroundHex)
        try c.encodeIfPresent(retainPreviousBackground, forKey: .retainPreviousBackground)
        try c.encodeIfPresent(backgroundImageData, forKey: .backgroundImageData)
        try c.encodeIfPresent(backgroundVideoPath, forKey: .backgroundVideoPath)
        try c.encodeIfPresent(backgroundVideoEndBehavior, forKey: .backgroundVideoEndBehavior)
        try c.encodeIfPresent(backgroundVideoTakeBehavior, forKey: .backgroundVideoTakeBehavior)
        try c.encodeIfPresent(backgroundVideoFadeDuration, forKey: .backgroundVideoFadeDuration)
        try c.encodeIfPresent(backgroundVideoAudioEnabled, forKey: .backgroundVideoAudioEnabled)
        try c.encodeIfPresent(backgroundVideoVolume, forKey: .backgroundVideoVolume)
        try c.encode(layers, forKey: .layers)
        try c.encode(notes, forKey: .notes)
        try c.encodeIfPresent(autoAdvanceSeconds, forKey: .autoAdvanceSeconds)
        try c.encodeIfPresent(transitionSecondsOverride, forKey: .transitionSecondsOverride)
        try c.encode(cueAudioGain, forKey: .cueAudioGain)
        try c.encode(cueAudioMuted, forKey: .cueAudioMuted)
        try c.encodeIfPresent(collectionID, forKey: .collectionID)
        try c.encode(slideTitle, forKey: .slideTitle)
    }
}

struct SlideCollection: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
}

struct PresentationShow: Codable {
    var formatVersion: Int = 6
    var title: String
    var slides: [PresentationSlide]
    /// The source composition size, independent of the physical display resolution.
    var canvasSize: ShowCanvasSize = .fullHD
    var collections: [SlideCollection] = []
    /// Wrap the last slide of a timed sequence to the first (within the active collection).
    var loopAutoAdvance: Bool = false
    var globalTransitionSeconds: Double = 0.65
    /// Default time a slide stays on Program while Auto Transition is enabled.
    var globalAutoAdvanceSeconds: Double = 10

    init(formatVersion: Int = 6, title: String, slides: [PresentationSlide],
         canvasSize: ShowCanvasSize = .fullHD,
         collections: [SlideCollection] = [], loopAutoAdvance: Bool = false,
         globalTransitionSeconds: Double = 0.65, globalAutoAdvanceSeconds: Double = 10) {
        self.formatVersion = formatVersion
        self.title = title
        self.slides = slides
        self.canvasSize = canvasSize
        self.collections = collections
        self.loopAutoAdvance = loopAutoAdvance
        self.globalTransitionSeconds = globalTransitionSeconds
        self.globalAutoAdvanceSeconds = globalAutoAdvanceSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, title, slides, canvasWidth, canvasHeight, collections, loopAutoAdvance, globalTransitionSeconds, globalAutoAdvanceSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        // Older/third-party shows might not include title; the File opener
        // fills it from the filename when blank.
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        slides = try container.decode([PresentationSlide].self, forKey: .slides)
        let width = try container.decodeIfPresent(Int.self, forKey: .canvasWidth) ?? 1920
        let height = try container.decodeIfPresent(Int.self, forKey: .canvasHeight) ?? 1080
        canvasSize = ShowCanvasSize(width: width, height: height)
        collections = try container.decodeIfPresent([SlideCollection].self, forKey: .collections) ?? []
        loopAutoAdvance = try container.decodeIfPresent(Bool.self, forKey: .loopAutoAdvance) ?? false
        globalTransitionSeconds = try container.decodeIfPresent(Double.self, forKey: .globalTransitionSeconds) ?? 0.65
        globalAutoAdvanceSeconds = try container.decodeIfPresent(Double.self, forKey: .globalAutoAdvanceSeconds) ?? 10
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(title, forKey: .title)
        try container.encode(slides, forKey: .slides)
        try container.encode(canvasSize.width, forKey: .canvasWidth)
        try container.encode(canvasSize.height, forKey: .canvasHeight)
        try container.encode(collections, forKey: .collections)
        try container.encode(loopAutoAdvance, forKey: .loopAutoAdvance)
        try container.encode(globalTransitionSeconds, forKey: .globalTransitionSeconds)
        try container.encode(globalAutoAdvanceSeconds, forKey: .globalAutoAdvanceSeconds)
    }

    static let demo = PresentationShow(
        title: "Demo Show",
        slides: [
            PresentationSlide(text: "Welcome\nto the show", backgroundHex: "#172B4D", fontSize: 136),
            PresentationSlide(text: "Tonight's Event", backgroundHex: "#274A58", fontSize: 116),
            PresentationSlide(text: "Thank You!", backgroundHex: "#422C5B", fontSize: 156)
        ]
    )
}
