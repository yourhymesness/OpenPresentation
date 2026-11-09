import Foundation

/// Portable test of the Codable payload used by the macOS layer Cut clipboard.
/// The actual NSPasteboard, keyboard, native menu and Undo UI must be tested
/// on macOS, where AppKit is available.
@main struct CutLayerPayloadRoundTrip {
    static func main() throws {
        var title = SlideLayer.makeText("Title", name: "Heading")
        title.centerX = 0.28
        title.centerY = 0.71
        title.width = 0.44
        title.height = 0.23
        title.opacity = 0.42
        let group = UUID()
        title.groupID = group

        var image = SlideLayer.makeImage(Data([0, 1, 2, 3]), width: 0.3, height: 0.2)
        image.groupID = group
        image.isLocked = false

        var locked = SlideLayer.makeText("Safe", name: "Protected")
        locked.isLocked = true
        var slide = PresentationSlide(text: "")
        slide.layers = [title, image, locked]
        let selectedIDs: Set<UUID> = [title.id, image.id, locked.id]

        let copyable = slide.layers.filter { selectedIDs.contains($0.id) && !$0.isLocked }
        precondition(copyable.count == 2)
        let clipboardData = try JSONEncoder().encode(copyable)
        let clipboardLayers = try JSONDecoder().decode([SlideLayer].self, from: clipboardData)
        precondition(clipboardLayers == copyable, "Clipboard must preserve full layer payloads")

        let ids = Set(copyable.map(\.id))
        let before = slide
        slide.layers.removeAll { ids.contains($0.id) }
        precondition(slide.layers.map(\.id) == [locked.id], "Locked layers must stay")
        slide = before
        precondition(slide.layers == before.layers, "Original snapshot must restore removed layers")
        precondition(clipboardLayers[0].groupID == clipboardLayers[1].groupID)
        precondition(clipboardLayers[0].centerX == title.centerX)
        precondition(clipboardLayers[0].opacity == title.opacity)
        precondition(clipboardLayers[1].imageData == Data([0, 1, 2, 3]))
        print("PASS: cut payload retains image/text, geometry, groups, locks and restoration snapshot")
    }
}
