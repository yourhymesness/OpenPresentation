import AppKit
import SwiftUI

/// Editor interaction is intentionally separated from rendering. In particular,
/// the selected layer's resize control lives ABOVE all selectable layer rectangles,
/// so an overlapping text box cannot steal a resize drag from a video.
struct SlideObjectCanvas: View {
    @Binding var slide: PresentationSlide
    @Binding var selectedLayerID: UUID?
    @Binding var selectedLayerIDs: Set<UUID>
    var snapToGuides: Bool
    var canvasSize: ShowCanvasSize = .fullHD
    // Temporary font candidate; used ONLY for the visual canvas. Never writes
    // through the slide binding and cannot affect the live Program snapshot.
    var previewFontLayerID: UUID? = nil
    var previewFontFamily: String? = nil
    @State private var initialPositions: [UUID: LayerCenter] = [:]
    @State private var movingIDs: Set<UUID> = []
    @State private var activeGuides: [CanvasSnapGuide] = []
    var onScaleLayer: (UUID, LayerScalePreset) -> Void
    var onResizeCompleted: (SlideLayer) -> Void
    var onReorderLayer: (UUID, LayerOrderAction) -> Void
    var onPaste: () -> Void
    @State private var editingLayerID: UUID?
    @FocusState private var inlineEditorFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                SlideCanvas(
                    slide: slide.previewingFont(previewFontFamily, onLayer: previewFontLayerID),
                    canvasSize: canvasSize,
                    showTransparencyCheckerboard: true
                )
                .allowsHitTesting(false)

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        finishEditing()
                        selectedLayerIDs = []
                        selectedLayerID = nil
                    }
                    .contextMenu {
                        Button("Paste") { onPaste() }
                    }

                // Paint order matches the renderer; the uppermost layer is
                // the one selected when overlapping hit regions are clicked.
                ForEach(slide.layers) { layer in
                    if layer.isVisible && layer.kind != .audio {
                        LayerMoveRegion(
                            layer: binding(for: layer),
                            canvasSize: geometry.size,
                            onSelect: { additive in select(layer.id, additive: additive) },
                            onEdit: {
                                guard layer.kind == .text && !layer.isLocked else { return }
                                select(layer.id, additive: false)
                                editingLayerID = layer.id
                            },
                            onMoveChanged: { translation in
                                moveLayers(triggerID: layer.id, translation: translation,
                                           canvasSize: geometry.size)
                            },
                            onMoveEnded: { finishMove() }
                        )
                        .contextMenu {
                            contextMenu(for: layer)
                        }
                    }
                }

                // Audio-only sources remain editable in the Layers inspector,
                // but never draw a placeholder or accept mouse hits on the
                // visual canvas. They cannot obscure another layer's handles.

                // Non-primary selections have outlines but no resize handles.
                // The primary handle stays above all hit regions.
                ForEach(slide.layers.filter { selectedLayerIDs.contains($0.id) &&
                                               $0.id != selectedLayerID && $0.isVisible && $0.kind != .audio }) { layer in
                    Rectangle()
                        .stroke(Color.cyan.opacity(0.85), lineWidth: 1.5)
                        .frame(width: max(1, layer.width * geometry.size.width),
                               height: max(1, layer.height * geometry.size.height))
                        .position(x: layer.centerX * geometry.size.width,
                                  y: layer.centerY * geometry.size.height)
                        .allowsHitTesting(false)
                        .zIndex(95)
                }

                ForEach(activeGuides.indices, id: \.self) { index in
                    let guide = activeGuides[index]
                    if guide.axis == .vertical {
                        Rectangle().fill(Color.cyan.opacity(0.9))
                            .frame(width: 1.5, height: geometry.size.height)
                            .position(x: guide.fraction * geometry.size.width,
                                      y: geometry.size.height / 2)
                            .allowsHitTesting(false)
                            .zIndex(98)
                    } else {
                        Rectangle().fill(Color.cyan.opacity(0.9))
                            .frame(width: geometry.size.width, height: 1.5)
                            .position(x: geometry.size.width / 2,
                                      y: guide.fraction * geometry.size.height)
                            .allowsHitTesting(false)
                            .zIndex(98)
                    }
                }

                // Selection decorations and the resize handle MUST be drawn
                // after all layer hit regions, regardless of layer ordering.
                if let selectedLayerID,
                   let selected = slide.layers.first(where: { $0.id == selectedLayerID && $0.isVisible && $0.kind != .audio }) {
                    SelectedLayerOverlay(layer: binding(for: selected), canvasSize: geometry.size,
                                         onResizeCompleted: onResizeCompleted)
                        .zIndex(100)
                }

                if let editingLayerID,
                   let layer = slide.layers.first(where: { $0.id == editingLayerID && $0.kind == .text }) {
                    let boxWidth = min(max(260, layer.width * geometry.size.width),
                                       max(90, geometry.size.width - 12))
                    let boxHeight = min(max(130, layer.height * geometry.size.height),
                                        max(65, geometry.size.height - 12))
                    let x = min(max(boxWidth / 2 + 6, layer.centerX * geometry.size.width),
                                geometry.size.width - boxWidth / 2 - 6)
                    let y = min(max(boxHeight / 2 + 6, layer.centerY * geometry.size.height),
                                geometry.size.height - boxHeight / 2 - 6)
                    VStack(spacing: 2) {
                        HStack {
                            Text("EDIT TEXT").font(.caption2.bold())
                            Spacer()
                            Button(action: finishEditing) {
                                Label("Done Editing", systemImage: "checkmark.circle.fill")
                                    .font(.caption.weight(.bold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .controlSize(.regular)
                            .keyboardShortcut(.return, modifiers: .command)
                            .help("Apply edits (or click outside the text box)")
                        }
                        TextEditor(text: Binding(
                            get: { slide.layers.first(where: { $0.id == editingLayerID })?.text ?? "" },
                            set: { updated in
                                guard let index = slide.layers.firstIndex(where: { $0.id == editingLayerID }) else { return }
                                slide.layers[index].text = updated
                            }
                        ))
                        .font(.custom(layer.fontFamily,
                                      size: max(12, CGFloat(layer.fontSize) * geometry.size.width / CGFloat(canvasSize.width))))
                        .foregroundStyle(Color(hex: layer.textColorHex))
                        .scrollContentBackground(.hidden)
                        .focused($inlineEditorFocused)
                        .onExitCommand { finishEditing() }
                    }
                    .padding(7)
                    .frame(width: boxWidth, height: boxHeight)
                    .background(Color.black.opacity(0.96), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 2))
                    .position(x: x, y: y)
                    .onAppear { inlineEditorFocused = true }
                    .zIndex(1000)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(Color.black)
            .clipped()
            .contentShape(Rectangle())
            // All gestures use a FIXED canvas coordinate space. Resizing an
            // element must never change the drag's coordinate reference.
            .coordinateSpace(name: "slideCanvas")
        }
        .aspectRatio(CGFloat(canvasSize.ratio), contentMode: .fit)
        .onChange(of: selectedLayerID) { _, newSelection in
            if editingLayerID != newSelection { finishEditing() }
        }
        .onChange(of: inlineEditorFocused) { _, focused in
            if !focused && editingLayerID != nil { finishEditing() }
        }
    }

    private func select(_ id: UUID, additive: Bool) {
        let ids: Set<UUID>
        if let group = slide.layers.first(where: { $0.id == id })?.groupID {
            ids = Set(slide.layers.filter { $0.groupID == group }.map(\.id))
        } else { ids = [id] }
        if additive {
            if ids.isSubset(of: selectedLayerIDs) {
                selectedLayerIDs.subtract(ids)
                if let selectedLayerID, ids.contains(selectedLayerID) {
                    self.selectedLayerID = selectedLayerIDs.first
                }
            } else {
                selectedLayerIDs.formUnion(ids)
                selectedLayerID = id
            }
        } else {
            selectedLayerIDs = ids
            selectedLayerID = id
        }
    }

    private func moveLayers(triggerID: UUID, translation: CGSize, canvasSize: CGSize) {
        guard let trigger = slide.layers.first(where: { $0.id == triggerID }), !trigger.isLocked else { return }
        if initialPositions.isEmpty {
            if !selectedLayerIDs.contains(triggerID) { select(triggerID, additive: false) }
            movingIDs = Set(slide.layers.filter {
                selectedLayerIDs.contains($0.id) && !$0.isLocked && $0.isVisible
            }.map(\.id))
            if movingIDs.isEmpty { movingIDs = [triggerID] }
            initialPositions = Dictionary(uniqueKeysWithValues: slide.layers
                .filter { movingIDs.contains($0.id) }
                .map { ($0.id, LayerCenter(x: $0.centerX, y: $0.centerY)) })
        }
        let proposedX = Double(translation.width / max(canvasSize.width, 1))
        let proposedY = Double(translation.height / max(canvasSize.height, 1))
        let snap = CanvasSnapper.resolve(layers: slide.layers, movingIDs: movingIDs,
                                         initialCenters: initialPositions,
                                         dragX: proposedX, dragY: proposedY,
                                         canvasWidth: Double(canvasSize.width),
                                         canvasHeight: Double(canvasSize.height),
                                         enabled: snapToGuides)
        for index in slide.layers.indices {
            let id = slide.layers[index].id
            guard let original = initialPositions[id] else { continue }
            slide.layers[index].centerX = original.x + snap.deltaX
            slide.layers[index].centerY = original.y + snap.deltaY
        }
        activeGuides = snap.guides
    }

    private func finishMove() {
        movingIDs = []
        initialPositions = [:]
        activeGuides = []
    }

    private func binding(for layer: SlideLayer) -> Binding<SlideLayer> {
        Binding(
            get: { slide.layers.first(where: { $0.id == layer.id }) ?? layer },
            set: { changed in
                guard let index = slide.layers.firstIndex(where: { $0.id == layer.id }) else { return }
                slide.layers[index] = changed
            }
        )
    }

    @ViewBuilder private func contextMenu(for layer: SlideLayer) -> some View {
        Button("Select \(layer.name.isEmpty ? "Layer" : layer.name)") { select(layer.id, additive: false) }
        Button("Paste") { onPaste() }
        Divider()
        ForEach(LayerOrderAction.allCases, id: \.self) { action in
            Button(action.rawValue) { onReorderLayer(layer.id, action) }
                .disabled(layer.isLocked)
        }
        Divider()
        ForEach(LayerScalePreset.allCases, id: \.self) { preset in
            Button(preset.rawValue) { onScaleLayer(layer.id, preset) }
                .disabled(layer.isLocked)
        }
    }

    private func finishEditing() {
        inlineEditorFocused = false
        editingLayerID = nil
    }
}

/// Only an element's body accepts move/select events; it does not own resize
/// controls. That prevents lower/upper elements from intercepting corner drags.
private struct LayerMoveRegion: View {
    @Binding var layer: SlideLayer
    let canvasSize: CGSize
    let onSelect: (Bool) -> Void
    let onEdit: () -> Void
    let onMoveChanged: (CGSize) -> Void
    let onMoveEnded: () -> Void

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.003))
            .frame(width: max(1, layer.width * canvasSize.width),
                   height: max(1, layer.height * canvasSize.height))
            .contentShape(Rectangle())
            .position(x: layer.centerX * canvasSize.width, y: layer.centerY * canvasSize.height)
            .onTapGesture { onSelect(NSEvent.modifierFlags.contains(.shift)) }
            .highPriorityGesture(TapGesture(count: 2).onEnded { onEdit() })
            .gesture(moveGesture)
            .help(layer.isLocked ? "Layer is locked" :
                  (layer.kind == .text ? "Double-click to edit; drag to move" : "Drag to move; right-click for scale options"))
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("slideCanvas"))
            .onChanged { value in
                if !layer.isLocked { onMoveChanged(value.translation) }
            }
            .onEnded { _ in onMoveEnded() }
    }

}

private struct SelectedLayerOverlay: View {
    @Binding var layer: SlideLayer
    let canvasSize: CGSize
    var onResizeCompleted: (SlideLayer) -> Void
    @State private var resizeStart: SlideLayer?

    var body: some View {
        let cw = max(1, canvasSize.width)
        let ch = max(1, canvasSize.height)
        let left = (layer.centerX - layer.width / 2) * cw
        let top = (layer.centerY - layer.height / 2) * ch
        let width = layer.width * cw
        let height = layer.height * ch

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.accentColor, lineWidth: 2)
                .frame(width: max(1, width), height: max(1, height))
                .position(x: layer.centerX * cw, y: layer.centerY * ch)
                .allowsHitTesting(false)

            Text(layer.isLocked ? "LOCKED" : layer.name)
                .font(.system(size: 9, weight: .medium))
                .padding(3)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
                .position(x: constrain(layer.centerX * cw, 35, cw - 35),
                          y: constrain(top - 13, 12, ch - 12))
                .allowsHitTesting(false)

            if !layer.isLocked {
                ForEach(LayerResizeHandle.allCases) { handle in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .frame(width: 11, height: 11)
                        .overlay(RoundedRectangle(cornerRadius: 2)
                            .stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .position(
                            x: constrain(left + width * handle.fx, 14, cw - 14),
                            y: constrain(top + height * handle.fy, 14, ch - 14)
                        )
                        .highPriorityGesture(resizeGesture(for: handle))
                        .help("Drag to resize. Hold Option (⌥) to stretch freely; media pixels stretch to the new frame.")
                }
            }
        }
        .frame(width: cw, height: ch)
    }

    private func resizeGesture(for handle: LayerResizeHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("slideCanvas"))
            .onChanged { value in
                guard !layer.isLocked else { return }
                if resizeStart == nil { resizeStart = layer }
                guard let original = resizeStart else { return }
                let freeStretch = NSEvent.modifierFlags.contains(.option)
                let resized = LayerGeometry(layer: original).resizing(
                    from: handle,
                    deltaX: Double(value.translation.width),
                    deltaY: Double(value.translation.height),
                    canvasWidth: Double(canvasSize.width),
                    canvasHeight: Double(canvasSize.height),
                    keepRatio: original.resolvedAspectRatioLocked && !freeStretch
                )
                resized.applied(to: &layer)
                layer.applyResizeModifier(freeStretch: freeStretch)
            }
            .onEnded { _ in
                if let original = resizeStart, original != layer {
                    onResizeCompleted(original)
                }
                resizeStart = nil
            }
    }
}

private func constrain(_ v: Double, _ low: Double, _ high: Double) -> Double {
    min(max(v, min(low, high)), max(low, high))
}
