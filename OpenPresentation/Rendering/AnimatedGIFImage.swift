import AppKit
import SwiftUI

/// Preserve animated GIF timing (and transparent frames) with AppKit.
/// SwiftUI's Image(nsImage:) is used for static editor thumbnails instead.
struct AnimatedGIFImage: NSViewRepresentable {
    let data: Data
    var contentMode: LayerContentMode = .fill

    static func isGIF(_ data: Data) -> Bool {
        data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8))
    }

    func makeNSView(context: Context) -> AnimatedGIFContainer {
        let view = AnimatedGIFContainer(frame: .zero)
        view.configure(data: data, contentMode: contentMode)
        return view
    }

    func updateNSView(_ view: AnimatedGIFContainer, context: Context) {
        view.configure(data: data, contentMode: contentMode)
    }
}

final class AnimatedGIFContainer: NSView {
    private let imageView = NSImageView()
    private var currentData: Data?
    private var currentMode: LayerContentMode = .fill

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = true
        imageView.imageFrameStyle = .none
        imageView.animates = true
        addSubview(imageView)
    }

    func configure(data: Data, contentMode: LayerContentMode) {
        currentMode = contentMode
        // Repeated SwiftUI updates must not reset the GIF to frame zero.
        if currentData != data {
            currentData = data
            imageView.image = NSImage(data: data)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let image = imageView.image, image.size.width > 0,
              image.size.height > 0, bounds.width > 0, bounds.height > 0 else {
            imageView.frame = bounds
            return
        }
        if currentMode == .stretch {
            imageView.imageScaling = .scaleAxesIndependently
            imageView.frame = bounds
            return
        }
        let ratio = currentMode == .fill
            ? max(bounds.width / image.size.width, bounds.height / image.size.height)
            : min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.frame = NSRect(x: (bounds.width - size.width) / 2,
                                 y: (bounds.height - size.height) / 2,
                                 width: size.width, height: size.height)
    }
}
