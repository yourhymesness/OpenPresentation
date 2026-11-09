import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Native clipboard for full layer values (including embedded images and
/// video paths). Paste creates fresh object IDs and remaps group IDs.
private enum LayerClipboard {
    static let type = NSPasteboard.PasteboardType("com.openpresentation.layers")

    @discardableResult
    static func copy(_ layers: [SlideLayer]) -> Bool {
        guard !layers.isEmpty, let data = try? JSONEncoder().encode(layers) else { return false }
        let board = NSPasteboard.general
        board.clearContents()
        return board.setData(data, forType: type)
    }

    static func paste() -> [SlideLayer]? {
        guard let data = NSPasteboard.general.data(forType: type),
              let layers = try? JSONDecoder().decode([SlideLayer].self, from: data),
              !layers.isEmpty else { return nil }
        var groupMap: [UUID: UUID] = [:]
        return layers.map { layer in
            var copy = layer
            copy.id = UUID()
            if let group = layer.groupID {
                if groupMap[group] == nil { groupMap[group] = UUID() }
                copy.groupID = groupMap[group]
            }
            copy.name += " Copy"
            // Preserve exact coordinates, size, stacking, opacity and media settings
            // when pasting a layer onto a different slide.
            return copy
        }
    }

    static var hasLayers: Bool { NSPasteboard.general.data(forType: type) != nil }
}

/// Layer-based slide editor. Edits update Preview only; Program uses a frozen
/// slide value until the operator explicitly takes a new snapshot live.
struct SlideEditorView: View {
    @Binding var slide: PresentationSlide
    // The Blind workspace gives the interactive canvas substantially more room.
    // This adjusts editor geometry only; it never changes the 1920×1080 show model.
    var canvasHeight: CGFloat = 330
    var isBlindTheme = false
    var controller: ShowController? = nil
    @State private var mediaError: String?
    @State private var mediaImporting = false
    @State private var selectedLayerID: UUID?
    @State private var selectedLayerIDs: Set<UUID> = []
    @State private var snapToGuides = true
    @FocusState private var canvasFocused: Bool
    @State private var draggingLayerID: UUID?
    @State private var showAdvancedHex = false
    @State private var showBackgroundVideoSettings = false
    // Monitors are installed only while the Blind editor is on screen.
    // Text editors / text fields keep their native Copy, Paste, and Delete.
    @State private var editorKeyMonitor: Any?
    @State private var menuRegistrationID = UUID()

    private let maxImportedImageSize = 30_000_000
    private let maxLayersPerSlide = 40

    private var fontFamilies: [String] {
        let installed = NSFontManager.shared.availableFontFamilies
        let saved = slide.layers.filter { $0.kind == .text }.map(\.fontFamily)
        return Array(Set(installed + saved + ["Helvetica Neue"])).sorted()
    }

    private var selectedLayerBinding: Binding<SlideLayer>? {
        guard let selectedLayerID,
              let fallback = slide.layers.first(where: { $0.id == selectedLayerID }) else { return nil }
        return Binding(
            get: { slide.layers.first(where: { $0.id == selectedLayerID }) ?? fallback },
            set: { updated in
                guard let index = slide.layers.firstIndex(where: { $0.id == selectedLayerID }) else { return }
                slide.layers[index] = updated
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("LAYER EDITOR")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Toggle("Snap", isOn: $snapToGuides)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Snap moved layers to edges and centerlines. Guides appear while dragging.")
                Spacer()
                Button { addTextBox() } label: {
                    Label("Add Text Box", systemImage: "textformat")
                }
                Menu {
                    ForEach(SlideShapeKind.allCases) { kind in
                        Button(kind.rawValue) { addShape(kind) }
                    }
                } label: {
                    Label("Add Object", systemImage: "square.on.circle")
                }
                Button { importMediaLayer() } label: {
                    Label("Add Media…", systemImage: "plus.rectangle.on.folder")
                }
                .help("Choose a supported image, animated GIF, video or audio file")
                if let controller {
                    Button { controller.undoSlideEdit() } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!controller.canUndoSlideEdit)
                    .help("Undo the last Blind edit (⌘Z)")
                    Button { controller.redoSlideEdit() } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .disabled(!controller.canRedoSlideEdit)
                    .help("Redo the last undone edit (⇧⌘Z)")
                }
                if mediaImporting {
                    ProgressView().controlSize(.small)
                    Text("Importing media…").font(.caption2)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    SlideObjectCanvas(slide: $slide,
                                      selectedLayerID: $selectedLayerID,
                                      selectedLayerIDs: $selectedLayerIDs,
                                      snapToGuides: snapToGuides,
                                      onScaleLayer: { id, preset in scaleLayer(id, preset: preset) },
                                      onResizeCompleted: { original in
                                          var before = slide
                                          if let index = before.layers.firstIndex(where: { $0.id == original.id }) {
                                              before.layers[index] = original
                                              controller?.recordLayerChangeUndo(before: before, name: "Resize Layer")
                                          }
                                      },
                                      onReorderLayer: { id, action in reorderLayer(id, action: action) },
                                      onPaste: { pasteFromClipboard() })
                        .frame(maxWidth: .infinity)
                        .frame(height: canvasHeight)
                        .focusable()
                        .focused($canvasFocused)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.gray.opacity(0.4), lineWidth: 1))
                    Text("Shift-click to select multiple layers; drag to move together. Cyan guides show snapping.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Notes/Background stay pinned; a long layer list may still
                // scroll independently inside its own inspector region.
                VStack(alignment: .leading, spacing: 7) {
                    ScrollView(.vertical) {
                        layerSidebar
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    notesAndBackgroundSidebar
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 280, height: canvasHeight + 35)
            }
        }
        .padding(14)
        .background(isBlindTheme
                    ? Color(red: 0.075, green: 0.14, blue: 0.26)
                    : Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
        .onPasteCommand(of: [.image, .fileURL, .plainText]) { _ in
            pasteFromClipboard()
        }
        .onAppear {
            OpenPresentationNativeMenus.shared.registerEditor(
                owner: menuRegistrationID,
                actions: LayerEditorMenuActions(
                    hasSelection: { !selectedLayerIDs.isEmpty },
                    canCut: { canCutSelectedLayers },
                    cut: { cutSelectedLayers() },
                    copy: { copySelectedLayers() },
                    paste: { pasteFromClipboard() },
                    selectAll: {
                        selectedLayerIDs = Set(slide.layers.filter(\.isVisible).map(\.id))
                        selectedLayerID = slide.layers.last(where: \.isVisible)?.id
                    },
                    deleteSelection: { removeSelectedLayers() }
                )
            )
            editorKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // The canvas command handler is active only for the operator
                // window, never for a Windowed Audience Output or Settings.
                guard event.window?.title == "OpenPresentation" else { return event }
                // These two AppKit classes are the first responders while a
                // TextEditor, TextField, or inline layer editor is active.
                if let responder = event.window?.firstResponder,
                   responder is NSTextView || responder is NSTextField { return event }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if modifiers.contains(.command) && !modifiers.contains(.option) && !modifiers.contains(.control) {
                    switch event.charactersIgnoringModifiers?.lowercased() {
                    case "c" where !selectedLayerIDs.isEmpty:
                        copySelectedLayers()
                        return nil
                    case "x" where canCutSelectedLayers:
                        cutSelectedLayers()
                        return nil
                    case "v":
                        if pasteFromClipboard() { return nil }
                    case "z":
                        if modifiers.contains(.shift) { controller?.redoSlideEdit() }
                        else { controller?.undoSlideEdit() }
                        return nil
                    default: break
                    }
                }
                if (event.keyCode == 51 || event.keyCode == 117) &&
                    !modifiers.contains(.command) && !modifiers.contains(.option) &&
                    !selectedLayerIDs.isEmpty {
                    removeSelectedLayers()
                    return nil
                }
                return event
            }
        }
        .onChange(of: slide.id) { _, _ in
            // The standard macOS ColorPicker uses a shared floating panel.
            // Keep it from editing the next slide after a selection change.
            NSColorPanel.shared.close()
            showBackgroundVideoSettings = false
            selectedLayerID = nil
            selectedLayerIDs = []
        }
        .onDisappear {
            OpenPresentationNativeMenus.shared.unregisterEditor(owner: menuRegistrationID)
            NSColorPanel.shared.close()
            if let monitor = editorKeyMonitor { NSEvent.removeMonitor(monitor) }
            editorKeyMonitor = nil
        }
        .alert("Media operation failed", isPresented: Binding(
            get: { mediaError != nil },
            set: { if !$0 { mediaError = nil } }
        )) {
            Button("OK", role: .cancel) { mediaError = nil }
        } message: {
            Text(mediaError ?? "Unexpected error")
        }
    }

    private var layerSidebar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("LAYERS (TOP FIRST)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Select All") {
                    selectedLayerIDs = Set(slide.layers.filter(\.isVisible).map(\.id))
                    selectedLayerID = slide.layers.last(where: \.isVisible)?.id
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                Text("\(slide.layers.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(slide.layers.reversed())) { layer in
                        HStack(spacing: 5) {
                            Button {
                                selectLayer(layer.id, additive: NSEvent.modifierFlags.contains(.shift))
                                canvasFocused = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: layer.kind == .text ? "textformat" :
                                          (layer.kind == .image ? "photo" :
                                           (layer.kind == .video ? "film" : layer.kind == .audio ? "waveform" : "square.on.circle")))
                                    if layer.groupID != nil {
                                        Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.cyan)
                                    }
                                    Text(layer.name.isEmpty ? (layer.kind == .text ? "Text" :
                                          (layer.kind == .image ? "Image" :
                                           (layer.kind == .video ? "Video" : layer.kind == .audio ? "Audio" : "Object"))) : layer.name)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(5)
                                .frame(maxWidth: .infinity)
                                .background(selectedLayerIDs.contains(layer.id) ? Color.accentColor.opacity(0.22) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Select Layer") { selectLayer(layer.id, additive: false) }
                                Button("Copy Layer") {
                                    selectLayer(layer.id, additive: false)
                                    copySelectedLayers()
                                }
                                Button("Paste") { pasteFromClipboard() }
                                if layer.groupID != nil {
                                    Button("Ungroup") {
                                        selectLayer(layer.id, additive: false)
                                        ungroupSelectedLayers()
                                    }
                                }
                                Divider()
                                ForEach(LayerOrderAction.allCases, id: \.self) { action in
                                    Button(action.rawValue) { reorderLayer(layer.id, action: action) }
                                        .disabled(layer.isLocked)
                                }
                                Divider()
                                ForEach(LayerScalePreset.allCases, id: \.self) { preset in
                                    Button(preset.rawValue) { scaleLayer(layer.id, preset: preset) }
                                        .disabled(layer.isLocked)
                                }
                            }
                            Button {
                                updateLayer(layer.id) { $0.isVisible.toggle() }
                            } label: {
                                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                            }
                            .buttonStyle(.borderless)
                            .help(layer.isVisible ? "Hide layer" : "Show layer")
                            Button {
                                updateLayer(layer.id) { $0.isLocked.toggle() }
                            } label: {
                                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                            }
                            .buttonStyle(.borderless)
                            .help(layer.isLocked ? "Unlock layer" : "Lock layer")
                        }
                        .onDrag {
                            draggingLayerID = layer.id
                            selectLayer(layer.id, additive: false)
                            return NSItemProvider(object: layer.id.uuidString as NSString)
                        }
                        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                            guard let source = draggingLayerID, source != layer.id,
                                  slide.layers.contains(where: { $0.id == source && !$0.isLocked }) else {
                                draggingLayerID = nil
                                return false
                            }
                            LayerOrdering.drag(source, onto: layer.id, layers: &slide.layers)
                            draggingLayerID = nil
                            return true
                        }
                    }
                }
            }
            .frame(height: 116)

            HStack(spacing: 6) {
                Button { moveSelectedLayer(by: 1) } label: { Image(systemName: "arrow.up") }
                    .help("Move selected layer forward")
                Button { moveSelectedLayer(by: -1) } label: { Image(systemName: "arrow.down") }
                    .help("Move selected layer backward")
                Menu {
                    ForEach(LayerOrderAction.allCases, id: \.self) { action in
                        Button(action.rawValue) {
                            if let selectedLayerID { reorderLayer(selectedLayerID, action: action) }
                        }
                    }
                } label: { Image(systemName: "square.3.layers.3d") }
                    .help("Layer order")
                Button { duplicateSelectedLayer() } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplicate layer")
                Spacer()
                Button(role: .destructive) { removeSelectedLayers() } label: {
                    Image(systemName: "trash")
                }
                .help("Remove selected layer")
            }
            .buttonStyle(.borderless)
            .disabled(selectedLayerBinding == nil)

            HStack(spacing: 5) {
                Button("Group") { groupSelectedLayers() }
                    .disabled(selectedLayerIDs.count < 2)
                    .help("Group the selected layers; moving one member moves the group")
                Button("Ungroup") { ungroupSelectedLayers() }
                    .disabled(!slide.layers.contains(where: { selectedLayerIDs.contains($0.id) && $0.groupID != nil }))
                Spacer(minLength: 0)
                Button { copySelectedLayers() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .disabled(selectedLayerIDs.isEmpty)
                    .help("Copy selected layers, including images, to the macOS clipboard")
                // Paste is available via Command-V and the layer/canvas context menus.
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Divider()

            if selectedLayerIDs.count > 1 {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(selectedLayerIDs.count) LAYERS SELECTED")
                        .font(.caption2.bold()).foregroundStyle(.secondary)
                    // Audio-only selections have no opacity. For mixed
                    // groups, preserve the non-visual audio layers unchanged.
                    if let visual = slide.layers.first(where: {
                        selectedLayerIDs.contains($0.id) && $0.kind != .audio
                    }) {
                        HStack(spacing: 6) {
                            Text("Group Opacity").font(.caption2)
                            Slider(value: Binding(
                                get: { slide.layers.first(where: { $0.id == visual.id })?.resolvedOpacity ?? 1 },
                                set: { value in
                                    for index in slide.layers.indices where
                                        selectedLayerIDs.contains(slide.layers[index].id) &&
                                        slide.layers[index].kind != .audio {
                                        slide.layers[index].opacity = value
                                    }
                                }), in: 0...1, step: 0.01)
                            Text("\(Int((slide.layers.first(where: { $0.id == visual.id })?.resolvedOpacity ?? 1) * 100))%")
                                .font(.caption2.monospacedDigit()).frame(width: 38)
                        }
                    }
                    Text("Drag any selected layer to move the group. Shift-click to add or remove objects.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Divider()
            }

            if let binding = selectedLayerBinding {
                layerInspector(binding)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select a layer to edit it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Drag layers to reorder; add text, images, videos or shapes.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Fixed footer in the Blind inspector. Important slide-wide options
    /// remain available even when a selected layer has many attributes.
    private var notesAndBackgroundSidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Label("SLIDE NOTES", systemImage: "square.and.pencil")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            TextEditor(text: $slide.notes)
                .id(slide.id)
                .font(.caption)
                .scrollContentBackground(.hidden)
                .frame(height: 63)
                .padding(4)
                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .help("Private operator notes for this slide; never projected")

            Divider()
            HStack {
                Label("SLIDE BACKGROUND", systemImage: "rectangle.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Toggle("Transparent", isOn: Binding(
                    get: { slide.backgroundHex == "#00000000" },
                    set: { slide.backgroundHex = $0 ? "#00000000" : "#15263D" }))
                    .font(.caption2)
                    .controlSize(.mini)
            }
            Toggle("Keep Previous Background", isOn: Binding(
                get: { slide.retainPreviousBackground == true },
                set: { slide.retainPreviousBackground = $0 }))
                .disabled(!slide.isVisuallyTransparentBackground)
                .font(.caption2)
                .controlSize(.mini)
                .help("Only transparent slides: keep the previous on-air background, like a background slide. Off clears to black on audience output.")
            HStack(spacing: 7) {
                ColorPicker("Color", selection: colorBinding($slide.backgroundHex), supportsOpacity: true)
                    .id(slide.id)
                    .font(.caption)
                TextField("#15263D", text: $slide.backgroundHex)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(maxWidth: 112)
                    .help("Background HEX color, such as #15263D")
            }
            HStack(spacing: 6) {
                Button("Import Image…") { importBackgroundImage() }
                Button("Video…") { importVideoBackground() }
            }
            .controlSize(.small)
            HStack(spacing: 6) {
                if slide.backgroundImageData != nil {
                    Button("Remove Image") { slide.backgroundImageData = nil }
                }
                if let path = slide.backgroundVideoPath {
                    Button("Video Settings…") { showBackgroundVideoSettings = true }
                        .help(URL(fileURLWithPath: path).lastPathComponent)
                    Button("Remove Video") { slide.backgroundVideoPath = nil }
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .font(.caption2)
            .popover(isPresented: $showBackgroundVideoSettings) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("BACKGROUND VIDEO OPTIONS")
                        .font(.caption.weight(.bold))
                    if let path = slide.backgroundVideoPath {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        videoPlaybackOptions(
                            onTake: Binding(
                                get: { slide.resolvedBackgroundVideoTakeBehavior },
                                set: { slide.backgroundVideoTakeBehavior = $0 }),
                            behavior: Binding(
                                get: { slide.resolvedBackgroundVideoEndBehavior },
                                set: { slide.backgroundVideoEndBehavior = $0 }),
                            fade: Binding(
                                get: { slide.resolvedBackgroundVideoFadeDuration },
                                set: { slide.backgroundVideoFadeDuration = $0 }),
                            audible: Binding(
                                get: { slide.backgroundVideoAudioEnabled ?? false },
                                set: { slide.backgroundVideoAudioEnabled = $0 }),
                            volume: Binding(
                                get: { slide.resolvedBackgroundVideoVolume },
                                set: { slide.backgroundVideoVolume = $0 })
                        )
                    }
                    HStack {
                        Spacer()
                        Button("Done") { showBackgroundVideoSettings = false }
                    }
                }
                .padding(14)
                .frame(width: 325)
            }
            // This also controls optional advanced HEX fields for text/shapes.
            Toggle("Layer HEX fields", isOn: $showAdvancedHex)
                .font(.caption2)
                .controlSize(.mini)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Precise X/Y/W/H fields are based on the current 1920×1080 show canvas.
    /// Fields change the same normalized geometry as the eight drag handles.
    private func pixelBinding(_ binding: Binding<SlideLayer>, field: LayerDimensionField) -> Binding<Double> {
        Binding(
            get: {
                let rect = LayerGeometry(layer: binding.wrappedValue)
                switch field {
                case .x: return rect.left * 1920
                case .y: return rect.top * 1080
                case .width: return rect.width * 1920
                case .height: return rect.height * 1080
                }
            },
            set: { pixels in
                let before = slide
                var adjusted = binding.wrappedValue
                let rect = LayerGeometry(layer: adjusted).setting(
                    field, pixels: pixels,
                    canvasWidth: 1920, canvasHeight: 1080,
                    keepRatio: adjusted.resolvedAspectRatioLocked
                )
                rect.applied(to: &adjusted)
                guard binding.wrappedValue != adjusted else { return }
                binding.wrappedValue = adjusted
                controller?.recordLayerChangeUndo(before: before, name: "Set Layer Geometry")
            }
        )
    }

    private func pixelField(_ title: String, field: LayerDimensionField,
                            binding: Binding<SlideLayer>) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.caption2.weight(.medium)).frame(width: 13, alignment: .leading)
            TextField(title, value: pixelBinding(binding, field: field),
                      format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
                .accessibilityLabel("\(title) in canvas pixels")
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func layerInspector(_ binding: Binding<SlideLayer>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField("Layer name", text: binding.name)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            if binding.wrappedValue.kind != .audio {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("GEOMETRY · 1920 × 1080").font(.caption2.weight(.semibold))
                        Spacer()
                        Toggle("Lock ratio", isOn: Binding(
                            get: { binding.wrappedValue.resolvedAspectRatioLocked },
                            set: { binding.wrappedValue.aspectRatioLocked = $0 }
                        ))
                        .font(.caption2)
                        .controlSize(.mini)
                        .help("Preserve this layer's pixel aspect ratio when resizing")
                    }
                    HStack(spacing: 6) {
                        pixelField("X", field: .x, binding: binding)
                        pixelField("Y", field: .y, binding: binding)
                    }
                    HStack(spacing: 6) {
                        pixelField("W", field: .width, binding: binding)
                        pixelField("H", field: .height, binding: binding)
                    }
                }
                .disabled(binding.wrappedValue.isLocked)
            }
            // Audio is non-visual. Opacity controls only visual layers;
            // audio levels are adjusted with the Volume control below.
            if binding.wrappedValue.kind != .audio {
                HStack(spacing: 6) {
                    Text("Opacity").font(.caption2)
                    Slider(value: Binding(
                        get: { binding.wrappedValue.resolvedOpacity },
                        set: { binding.wrappedValue.opacity = $0 }), in: 0...1, step: 0.01)
                    Text("\(Int((binding.wrappedValue.resolvedOpacity * 100).rounded()))%")
                        .font(.caption2.monospacedDigit()).frame(width: 38, alignment: .trailing)
                }
            }

            if binding.wrappedValue.kind == .text {
                Text("TEXT BOX")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)

                TextEditor(text: binding.text)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(height: 60)
                    .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))

                Picker("Font", selection: binding.fontFamily) {
                    ForEach(fontFamilies, id: \.self) { font in
                        // Prefer the font family shown in its own typeface;
                        // some macOS versions may normalize native menu styles.
                        Text(font)
                            .font(.custom(font, size: 13))
                            .tag(font)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .font(.caption)

                HStack(spacing: 6) {
                    Text("Size").font(.caption)
                    Slider(value: binding.fontSize, in: 12...280, step: 2)
                    Text("\(Int(binding.wrappedValue.fontSize))")
                        .font(.caption.monospacedDigit())
                        .frame(width: 32, alignment: .trailing)
                }

                ColorPicker("Text color", selection: colorBinding(binding.textColorHex), supportsOpacity: false)
                    .font(.caption)
                if showAdvancedHex {
                    TextField("#FFFFFF", text: binding.textColorHex)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                }

                Picker("Align", selection: binding.textAlignment) {
                    ForEach(SlideTextAlignment.allCases) { alignment in
                        Text(alignment.rawValue).tag(alignment)
                    }
                }
                .pickerStyle(.segmented)
                .font(.caption)
            } else if binding.wrappedValue.kind == .shape {
                Text("VECTOR OBJECT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Picker("Shape", selection: Binding(
                    get: { binding.wrappedValue.resolvedShapeKind },
                    set: { binding.wrappedValue.shapeKind = $0 }
                )) {
                    ForEach(SlideShapeKind.allCases) { shape in Text(shape.rawValue).tag(shape) }
                }
                .pickerStyle(.menu)
                ColorPicker("Fill", selection: colorBinding(Binding(
                    get: { binding.wrappedValue.resolvedShapeFill },
                    set: { binding.wrappedValue.shapeFillHex = $0 })), supportsOpacity: false)
                    .font(.caption)
                ColorPicker("Outline", selection: colorBinding(Binding(
                    get: { binding.wrappedValue.resolvedShapeStroke },
                    set: { binding.wrappedValue.shapeStrokeHex = $0 })), supportsOpacity: false)
                    .font(.caption)
                HStack(spacing: 6) {
                    Text("Outline Width").font(.caption2)
                    Slider(value: Binding(
                        get: { binding.wrappedValue.resolvedShapeStrokeWidth },
                        set: { binding.wrappedValue.shapeStrokeWidth = $0 }), in: 0...40, step: 1)
                    Text("\(Int(binding.wrappedValue.resolvedShapeStrokeWidth))")
                        .font(.caption2.monospacedDigit())
                }
                if showAdvancedHex {
                    HStack {
                        TextField("Fill #RRGGBB", text: Binding(
                            get: { binding.wrappedValue.resolvedShapeFill },
                            set: { binding.wrappedValue.shapeFillHex = $0 }))
                        TextField("Outline #RRGGBB", text: Binding(
                            get: { binding.wrappedValue.resolvedShapeStroke },
                            set: { binding.wrappedValue.shapeStrokeHex = $0 }))
                    }
                    .textFieldStyle(.roundedBorder)
                }
            } else if binding.wrappedValue.kind == .image {
                Text("IMAGE LAYER")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("Drag to move, use the corner handle to resize, or right-click the image for Fit, Fill, Stretch and Original Size.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Smaller") { scaleSelectedImage(by: 0.9) }
                    Button("Larger") { scaleSelectedImage(by: 1.1) }
                }
                .controlSize(.small)
            } else if binding.wrappedValue.kind == .audio {
                Text("AUDIO LAYER")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(URL(fileURLWithPath: binding.wrappedValue.audioPath ?? "").lastPathComponent)
                    .font(.caption2).lineLimit(2)
                Toggle("Loop audio", isOn: Binding(
                    get: { binding.wrappedValue.audioLoops ?? false },
                    set: { binding.wrappedValue.audioLoops = $0 }))
                    .font(.caption)
                HStack(spacing: 6) {
                    Text("Volume").font(.caption2)
                    Slider(value: Binding(
                        get: { binding.wrappedValue.resolvedAudioVolume },
                        set: { binding.wrappedValue.audioVolume = $0 }), in: 0...1)
                    Text("\(Int(binding.wrappedValue.resolvedAudioVolume * 100))%")
                        .font(.caption2.monospacedDigit())
                }
                Text("Audio layers do not render visuals. Multiple different clips can play concurrently; only the audience output emits sound.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("VIDEO LAYER")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(URL(fileURLWithPath: binding.wrappedValue.videoPath ?? "").lastPathComponent)
                    .font(.caption2)
                    .lineLimit(2)
                videoPlaybackOptions(
                    onTake: Binding(
                        get: { binding.wrappedValue.resolvedVideoTakeBehavior },
                        set: { binding.wrappedValue.videoTakeBehavior = $0 }),
                    behavior: Binding(
                        get: { binding.wrappedValue.resolvedVideoEndBehavior },
                        set: { binding.wrappedValue.videoEndBehavior = $0 }),
                    fade: Binding(
                        get: { binding.wrappedValue.resolvedVideoFadeDuration },
                        set: { binding.wrappedValue.videoFadeDuration = $0 }),
                    audible: Binding(
                        get: { binding.wrappedValue.videoAudioEnabled ?? false },
                        set: { binding.wrappedValue.videoAudioEnabled = $0 }),
                    volume: Binding(
                        get: { binding.wrappedValue.resolvedVideoVolume },
                        set: { binding.wrappedValue.videoVolume = $0 })
                )
                Text("Drag to move, use the corner handle to resize, or right-click for Fit, Fill, Stretch and Original Size.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("X \(Int(binding.wrappedValue.centerX * 100))%  Y \(Int(binding.wrappedValue.centerY * 100))%  •  W \(Int(binding.wrappedValue.width * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func videoPlaybackOptions(onTake: Binding<VideoTakeBehavior>,
                                      behavior: Binding<VideoEndBehavior>,
                                      fade: Binding<Double>,
                                      audible: Binding<Bool>,
                                      volume: Binding<Double>) -> some View {
        Picker("When slide changes", selection: onTake) {
            ForEach(VideoTakeBehavior.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .font(.caption)
        Text(onTake.wrappedValue == .continueOnConsecutive
             ? "Same video on the next slide continues; returning after any different slide starts at 0."
             : "Every slide take begins this video at 0, including adjacent slides using the same file.")
            .font(.caption2)
            .foregroundStyle(.secondary)

        Picker("At end", selection: behavior) {
            ForEach(VideoEndBehavior.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .font(.caption)

        if behavior.wrappedValue.usesFadeTime {
            HStack(spacing: 7) {
                Text("Blend / fade")
                    .font(.caption2)
                Slider(value: fade, in: 0.2...3.0, step: 0.1)
                Text(String(format: "%.1fs", fade.wrappedValue))
                    .font(.caption2.monospacedDigit())
            }
        }
        Toggle("Enable video audio", isOn: audible)
            .font(.caption)
        if audible.wrappedValue {
            HStack(spacing: 6) {
                Text("Volume").font(.caption2)
                Slider(value: volume, in: 0...1)
                Text("\(Int(volume.wrappedValue * 100))%")
                    .font(.caption2.monospacedDigit())
            }
        }
        Text("Audio is emitted only from the Audience output, using the device selected in OpenPresentation → Settings → Audio. Program monitor stays muted.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func members(for id: UUID) -> Set<UUID> {
        guard let layer = slide.layers.first(where: { $0.id == id }),
              let group = layer.groupID else { return [id] }
        return Set(slide.layers.filter { $0.groupID == group }.map(\.id))
    }

    private func selectLayer(_ id: UUID, additive: Bool) {
        let ids = members(for: id)
        if additive {
            if ids.isSubset(of: selectedLayerIDs) {
                selectedLayerIDs.subtract(ids)
                if let primary = selectedLayerID, ids.contains(primary) {
                    selectedLayerID = selectedLayerIDs.first
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

    private func groupSelectedLayers() {
        guard selectedLayerIDs.count >= 2 else { return }
        let id = UUID()
        // If a preexisting group is among the selection, include its other
        // members rather than orphaning them.
        let existing = Set(slide.layers.filter { selectedLayerIDs.contains($0.id) }
            .compactMap(\.groupID))
        for index in slide.layers.indices {
            if selectedLayerIDs.contains(slide.layers[index].id) ||
                (slide.layers[index].groupID.map { existing.contains($0) } ?? false) {
                slide.layers[index].groupID = id
                selectedLayerIDs.insert(slide.layers[index].id)
            }
        }
    }

    private func ungroupSelectedLayers() {
        let groups = Set(slide.layers.filter { selectedLayerIDs.contains($0.id) }.compactMap(\.groupID))
        guard !groups.isEmpty else { return }
        for index in slide.layers.indices {
            if let group = slide.layers[index].groupID, groups.contains(group) {
                slide.layers[index].groupID = nil
            }
        }
    }

    /// Consistent paste precedence: OpenPresentation layer bundle, original
    /// image/GIF, general image, then ordinary text as a new text layer.
    /// Returns false if the clipboard has nothing the slide can accept.
    @discardableResult
    private func pasteFromClipboard() -> Bool {
        let board = NSPasteboard.general
        if LayerClipboard.hasLayers {
            pasteLayers()
            return true
        }
        if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           urls.contains(where: { ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif"].contains($0.pathExtension.lowercased()) }) {
            pasteImageFromClipboard()
            return true
        }
        if board.canReadObject(forClasses: [NSImage.self], options: nil) {
            pasteImageFromClipboard()
            return true
        }
        if let text = board.string(forType: .string), !text.isEmpty {
            guard slide.layers.count < maxLayersPerSlide else {
                mediaError = "Too many layers on this slide."
                return true
            }
            var layer = SlideLayer.makeText(String(text.prefix(20_000)), name: "Pasted Text")
            layer.centerX = 0.5
            layer.centerY = 0.5
            let before = slide
            slide.layers.append(layer)
            controller?.recordLayerChangeUndo(before: before, name: "Paste Text")
            selectLayer(layer.id, additive: false)
            canvasFocused = true
            return true
        }
        return false
    }

    private var canCutSelectedLayers: Bool {
        slide.layers.contains { selectedLayerIDs.contains($0.id) && !$0.isLocked }
    }

    private func copySelectedLayers() {
        let layers = slide.layers.filter { selectedLayerIDs.contains($0.id) }
        LayerClipboard.copy(layers)
    }

    /// Cut is one atomic Blind edit. Only unlocked layers are removed, and
    /// the clipboard must accept their serialized data before anything changes.
    /// The snapshot keeps Cut reversible through the existing document history.
    private func cutSelectedLayers() {
        let layers = slide.layers.filter { selectedLayerIDs.contains($0.id) && !$0.isLocked }
        guard !layers.isEmpty else { return }
        guard LayerClipboard.copy(layers) else {
            mediaError = "Unable to copy the selected layers to the clipboard. Nothing was cut."
            return
        }
        let before = slide
        let removedIDs = Set(layers.map(\.id))
        slide.layers.removeAll { removedIDs.contains($0.id) }
        controller?.recordLayerChangeUndo(before: before, name: "Cut Layers")
        selectedLayerIDs.subtract(removedIDs)
        selectedLayerID = selectedLayerIDs.first
        canvasFocused = true
    }

    private func pasteLayers() {
        guard let incoming = LayerClipboard.paste() else { return }
        guard slide.layers.count + incoming.count <= maxLayersPerSlide else {
            mediaError = "Pasting would exceed the \(maxLayersPerSlide)-layer limit."
            return
        }
        let before = slide
        slide.layers.append(contentsOf: incoming)
        controller?.recordLayerChangeUndo(before: before, name: "Paste Layers")
        selectedLayerIDs = Set(incoming.map(\.id))
        selectedLayerID = incoming.last?.id
        canvasFocused = true
    }

    private func addTextBox() {
        guard slide.layers.count < maxLayersPerSlide else {
            mediaError = "The prototype supports up to \(maxLayersPerSlide) layers per slide."
            return
        }
        var layer = SlideLayer.makeText()
        layer.centerY = 0.4
        slide.layers.append(layer)
        selectLayer(layer.id, additive: false)
        canvasFocused = true
    }

    private func addShape(_ kind: SlideShapeKind) {
        guard slide.layers.count < maxLayersPerSlide else {
            mediaError = "The prototype supports up to \(maxLayersPerSlide) layers per slide."
            return
        }
        let layer = SlideLayer.makeShape(kind)
        slide.layers.append(layer)
        selectLayer(layer.id, additive: false)
        canvasFocused = true
    }

    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: hex.wrappedValue) },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return }
                let r = Int((min(1, max(0, rgb.redComponent)) * 255).rounded())
                let g = Int((min(1, max(0, rgb.greenComponent)) * 255).rounded())
                let b = Int((min(1, max(0, rgb.blueComponent)) * 255).rounded())
                let alpha = Int((min(1, max(0, rgb.alphaComponent)) * 255).rounded())
                hex.wrappedValue = alpha == 255
                    ? String(format: "#%02X%02X%02X", r, g, b)
                    : String(format: "#%02X%02X%02X%02X", r, g, b, alpha)
            }
        )
    }

    private func reorderLayer(_ id: UUID, action: LayerOrderAction) {
        LayerOrdering.apply(action, id: id, layers: &slide.layers)
        selectLayer(id, additive: false)
    }

    private func updateLayer(_ id: UUID, change: (inout SlideLayer) -> Void) {
        guard let index = slide.layers.firstIndex(where: { $0.id == id }) else { return }
        change(&slide.layers[index])
    }

    private func moveSelectedLayer(by offset: Int) {
        guard let selectedLayerID,
              let index = slide.layers.firstIndex(where: { $0.id == selectedLayerID }) else { return }
        let action: LayerOrderAction = offset > 0 ? .forward : .backward
        LayerOrdering.apply(action, id: selectedLayerID, layers: &slide.layers)
    }

    private func duplicateSelectedLayer() {
        guard let selectedLayerID,
              let index = slide.layers.firstIndex(where: { $0.id == selectedLayerID }) else { return }
        guard slide.layers.count < maxLayersPerSlide else {
            mediaError = "The prototype supports up to \(maxLayersPerSlide) layers per slide."
            return
        }
        var duplicate = slide.layers[index]
        duplicate.id = UUID()
        duplicate.name += " Copy"
        duplicate.isLocked = false
        duplicate.centerX = min(1 - duplicate.width / 2, duplicate.centerX + 0.04)
        duplicate.centerY = min(1 - duplicate.height / 2, duplicate.centerY + 0.04)
        slide.layers.insert(duplicate, at: index + 1)
        selectLayer(duplicate.id, additive: false)
    }

    private func removeSelectedLayers() {
        guard !selectedLayerIDs.isEmpty else { return }
        let ids = selectedLayerIDs
        // Locked layers are never deleted by an accidental keypress.
        slide.layers.removeAll(where: { ids.contains($0.id) && !$0.isLocked })
        selectedLayerIDs = Set(slide.layers.filter { ids.contains($0.id) }.map(\.id))
        selectedLayerID = selectedLayerIDs.first
        canvasFocused = true
    }

    private func scaleSelectedImage(by factor: Double) {
        guard let selectedLayerID,
              let index = slide.layers.firstIndex(where: { $0.id == selectedLayerID }),
              slide.layers[index].kind == .image,
              !slide.layers[index].isLocked else { return }
        let original = slide.layers[index]
        let ratio = original.height / max(original.width, 0.001)
        let maxWidth = min(1, 1 / max(ratio, 0.001))
        let width = min(max(0.06, original.width * factor), maxWidth)
        let height = width * ratio
        slide.layers[index].width = width
        slide.layers[index].height = height
        slide.layers[index].centerX = min(max(width / 2, original.centerX), 1 - width / 2)
        slide.layers[index].centerY = min(max(height / 2, original.centerY), 1 - height / 2)
    }

    // Sizing commands are shared by canvas and layer-list context menus.
    // Native source sizes are cached into the layer model so they survive
    // saving and reopening a show. An old video can be probed on first use.
    private func scaleLayer(_ id: UUID, preset: LayerScalePreset) {
        guard let layer = slide.layers.first(where: { $0.id == id }), !layer.isLocked else { return }
        if layer.kind == .video,
           (layer.mediaPixelWidth ?? 0) <= 0,
           let path = layer.videoPath {
            Task {
                let pixels = await videoPixelSize(path: path)
                await MainActor.run {
                    applyScalePreset(preset, to: id, sourcePixels: pixels)
                }
            }
        } else {
            let pixels = imagePixelSize(layer)
            applyScalePreset(preset, to: id, sourcePixels: pixels)
        }
    }

    private func applyScalePreset(_ preset: LayerScalePreset, to id: UUID, sourcePixels: CGSize?) {
        updateLayer(id) { layer in
            if let size = sourcePixels, size.width > 0, size.height > 0 {
                layer.mediaPixelWidth = Double(size.width)
                layer.mediaPixelHeight = Double(size.height)
            }
            layer.applyScalePreset(preset, pixelSize: sourcePixels)
        }
        selectLayer(id, additive: false)
    }

    private func imagePixelSize(_ layer: SlideLayer) -> CGSize? {
        guard layer.kind == .image, let data = layer.imageData,
              let image = NSImage(data: data) else { return nil }
        if let bitmap = NSBitmapImageRep(data: data) {
            return CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        }
        return image.size
    }

    private func videoPixelSize(path: String) async -> CGSize? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let display = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized.size
        guard display.width > 0, display.height > 0 else { return nil }
        return display
    }

    private func importMediaLayer() {
        guard slide.layers.count < maxLayersPerSlide else {
            mediaError = "Too many layers on this slide (limit: 40)."
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .movie, .audio,
                                     UTType(filenameExtension: "webm") ?? .movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "heic", "tif", "tiff", "gif":
            do { appendImage(try validatedData(Data(contentsOf: url))) }
            catch { mediaError = error.localizedDescription }
        case "mp3", "m4a", "wav", "aif", "aiff", "caf", "aac", "flac":
            stageSelectedAudio(url)
        default:
            stageSelectedVideo(url)
        }
    }

    private func stageSelectedAudio(_ url: URL) {
        let targetSlide = slide.id
        mediaImporting = true
        Task {
            do {
                let path = try await MediaImporter.stageAudio(from: url)
                guard slide.id == targetSlide else { mediaImporting = false; return }
                let layer = SlideLayer.makeAudio(path: path, name: url.deletingPathExtension().lastPathComponent)
                slide.layers.append(layer)
                selectLayer(layer.id, additive: false)
            } catch { mediaError = error.localizedDescription }
            mediaImporting = false
        }
    }

    private func stageSelectedVideo(_ url: URL) {
        let targetSlide = slide.id
        mediaImporting = true
        Task {
            do {
                let path = try await MediaImporter.stageVideo(from: url)
                guard slide.id == targetSlide else { mediaImporting = false; return }
                let layer = SlideLayer.makeVideo(path: path, name: url.deletingPathExtension().lastPathComponent)
                slide.layers.append(layer)
                selectLayer(layer.id, additive: false)
                if let size = await videoPixelSize(path: path), slide.id == targetSlide {
                    updateLayer(layer.id) { stored in
                        stored.mediaPixelWidth = Double(size.width)
                        stored.mediaPixelHeight = Double(size.height)
                    }
                }
            } catch { mediaError = error.localizedDescription }
            mediaImporting = false
        }
    }

    private func importVideoBackground() {
        guard let url = chooseVideoURL() else { return }
        let targetSlide = slide.id
        mediaImporting = true
        Task {
            do {
                let path = try await MediaImporter.stageVideo(from: url)
                if slide.id == targetSlide { slide.backgroundVideoPath = path }
            } catch { mediaError = error.localizedDescription }
            mediaImporting = false
        }
    }

    private func importVideoLayer() {
        guard slide.layers.count < maxLayersPerSlide else {
            mediaError = "Too many layers on this slide (limit: 40)."
            return
        }
        guard let url = chooseVideoURL() else { return }
        let targetSlide = slide.id
        mediaImporting = true
        Task {
            do {
                let path = try await MediaImporter.stageVideo(from: url)
                guard slide.id == targetSlide else { mediaImporting = false; return }
                let layer = SlideLayer.makeVideo(path: path,
                    name: "Video \(slide.layers.filter({ $0.kind == .video }).count + 1)")
                slide.layers.append(layer)
                selectLayer(layer.id, additive: false)
                if let size = await videoPixelSize(path: path), slide.id == targetSlide {
                    updateLayer(layer.id) { stored in
                        stored.mediaPixelWidth = Double(size.width)
                        stored.mediaPixelHeight = Double(size.height)
                    }
                }
            } catch { mediaError = error.localizedDescription }
            mediaImporting = false
        }
    }

    private func importAudioLayer() {
        guard slide.layers.count < maxLayersPerSlide else {
            mediaError = "Too many layers on this slide (limit: 40)."
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let targetSlide = slide.id
        mediaImporting = true
        Task {
            do {
                let path = try await MediaImporter.stageAudio(from: url)
                if slide.id == targetSlide {
                    let layer = SlideLayer.makeAudio(path: path,
                        name: "Audio \(slide.layers.filter({ $0.kind == .audio }).count + 1)")
                    slide.layers.append(layer)
                    selectLayer(layer.id, additive: false)
                }
            } catch { mediaError = error.localizedDescription }
            mediaImporting = false
        }
    }

    private func chooseVideoURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, UTType(filenameExtension: "webm") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func importBackgroundImage() {
        guard let data = chooseImageFile() else { return }
        slide.backgroundImageData = data
    }

    private func importForegroundImage() {
        guard let data = chooseImageFile() else { return }
        appendImage(data)
    }

    private func chooseImageFile() -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { return try validatedData(Data(contentsOf: url)) }
        catch { mediaError = error.localizedDescription; return nil }
    }

    private func pasteImageFromClipboard() {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first(where: { $0.pathExtension.lowercased() == "gif" }) {
            do { appendImage(try Data(contentsOf: url)) }
            catch { mediaError = error.localizedDescription }
            return
        }
        if let image = (board.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                mediaError = "Could not turn the clipboard image into PNG data."
                return
            }
            appendImage(png)
            return
        }
        if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first(where: { ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif"].contains($0.pathExtension.lowercased()) }) {
            do { appendImage(try Data(contentsOf: url)) }
            catch { mediaError = error.localizedDescription }
            return
        }
        mediaError = "Clipboard does not contain an image. Copy one in Preview or Finder."
    }

    private func validatedData(_ data: Data) throws -> Data {
        guard data.count <= maxImportedImageSize else { throw ImageError.tooLarge }
        guard NSImage(data: data) != nil else { throw ImageError.invalid }
        return data
    }

    private func appendImage(_ incoming: Data) {
        do {
            let data = try validatedData(incoming)
            guard slide.layers.count < maxLayersPerSlide else { throw ImageError.tooMany }
            guard let image = NSImage(data: data), image.size.width > 0,
                  image.size.height > 0 else { throw ImageError.invalid }
            let aspect = Double(image.size.width / image.size.height)
            let width = min(0.44, max(0.12, aspect * 0.25))
            let height = min(0.80, max(0.05, width * (16.0 / 9.0) / aspect))
            var layer = SlideLayer.makeImage(data, width: width, height: height, name: "Image \(slide.layers.filter({ $0.kind == .image }).count + 1)")
            if let dimensions = imagePixelSize(layer) {
                layer.mediaPixelWidth = Double(dimensions.width)
                layer.mediaPixelHeight = Double(dimensions.height)
            }
            let before = slide
            slide.layers.append(layer)
            controller?.recordLayerChangeUndo(before: before, name: "Paste Image")
            selectLayer(layer.id, additive: false)
            canvasFocused = true
        } catch {
            mediaError = error.localizedDescription
        }
    }

    private enum ImageError: LocalizedError {
        case tooLarge, invalid, tooMany
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "Image exceeds the 30 MB prototype limit."
            case .invalid: return "Could not decode this image. Use PNG, JPEG, HEIC or TIFF."
            case .tooMany: return "Too many layers on this slide (limit: 40)."
            }
        }
    }
}
