import AppKit
import SwiftUI

/// Shared slide clipboard. Unlike the layer clipboard, this holds an entire
/// authored slide, including notes, collection, timing, background, and media.
/// Paste gets new slide/layer/group UUIDs from ShowController.
private enum SlideClipboard {
    static let type = NSPasteboard.PasteboardType("com.openpresentation.slide")

    static func copy(_ slide: PresentationSlide) {
        guard let data = try? JSONEncoder().encode(slide) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: type)
    }
    static func paste() -> PresentationSlide? {
        guard let data = NSPasteboard.general.data(forType: type) else { return nil }
        return try? JSONDecoder().decode(PresentationSlide.self, from: data)
    }
}

@MainActor
struct OperatorView: View {
    @ObservedObject var show: ShowController
    @ObservedObject var output: OutputManager
    @ObservedObject var fileActions: ShowFileActions
    @AppStorage("liveAppearance") private var liveAppearance = LiveAppearance.system.rawValue
    @AppStorage("liveSlideViewMode") private var liveSlideViewMode = "icons"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var notesEditorTarget: SlideNotesEditorTarget?
    @State private var transitionEditorTarget: SlideTransitionEditorTarget?
    @State private var slidePendingDeletion: UUID?
    @State private var slideTransitionCustomText = ""
    @State private var globalTransitionCustomText = ""
    @State private var editingGlobalTransitionTime = false
    // Saved operator layout preference; never affects what the audience sees.
    @AppStorage("liveTopZoneHeight") private var liveTopZoneHeight: Double = 400
    @State private var topZoneDragOrigin: Double?
    @AppStorage("blindBottomZoneHeight") private var blindBottomZoneHeight: Double = 340
    @State private var blindZoneDragOrigin: Double?
    // A reused TextEditor must not retain keyboard focus when its slide changes.
    @FocusState private var notesPanelFocused: Bool
    @FocusState private var notesSheetFocused: Bool
    @FocusState private var showTitleFocused: Bool
    @FocusState private var slideTitleFocused: Bool

    private var liveColorScheme: ColorScheme? {
        (LiveAppearance(rawValue: liveAppearance) ?? .system).colorScheme
    }

    private var isBlind: Bool { show.mode == .blind }
    private var blindBackground: Color { Color(red: 0.035, green: 0.072, blue: 0.14) }
    private var blindSurface: Color { Color(red: 0.065, green: 0.12, blue: 0.225) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .background(isBlind ? blindSurface : Color.gray.opacity(0.055))

            Divider()

            HStack(alignment: .top, spacing: isBlind ? 15 : 0) {
                // Keep the library mounted so its width can animate instead
                // of popping in and out whenever the operator changes modes.
                libraryPane
                    .frame(width: isBlind ? 222 : 0)
                    .opacity(isBlind ? 1 : 0)
                    .clipped()
                    .allowsHitTesting(isBlind)
                    .accessibilityHidden(!isBlind)

                mainPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(16)
            .animation(reduceMotion ? nil : .spring(response: 0.52, dampingFraction: 0.86),
                       value: show.mode)

            Divider()
            HStack {
                Image(systemName: "info.circle")
                Text(show.statusMessage).lineLimit(1)
                Spacer(minLength: 8)
                if isBlind {
                    Label("BLIND", systemImage: "eye.slash.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(red: 0.14, green: 0.27, blue: 0.49), in: Capsule())
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                        .accessibilityLabel("Blind editing mode")
                }
                Spacer(minLength: 8)
                Text(output.isWindowedOpen && output.isFullscreenOpen ? "Windowed + Fullscreen active" :
                     output.isWindowedOpen ? "Windowed output active" :
                     output.isFullscreenOpen ? "Fullscreen output active" : "No output open")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(isBlind ? blindSurface : Color.gray.opacity(0.06))
        }
        .background((isBlind ? blindBackground : Color(nsColor: .windowBackgroundColor)).ignoresSafeArea())
        .preferredColorScheme(isBlind ? .dark : liveColorScheme)
        .animation(.easeInOut(duration: 0.38), value: show.mode)
        // All three navigation paths can change the notes binding while the
        // same TextEditor is mounted. Drop the first responder immediately.
        .onChange(of: show.selectedSlideID) { _, _ in
            if isBlind { endTextEditing() }
        }
        .onChange(of: show.liveSlideID) { _, _ in
            // A program take must not forcibly resign text focus or rebuild
            // AppKit's open menu while the operator is editing / navigating.
            // Explicit slide selection still commits text via the handler above.
        }
        .onChange(of: show.mode) { _, _ in
            endTextEditing()
            // Program's auto clock continues while the operator is in Blind.
        }
        .confirmationDialog("Delete this slide?", isPresented: Binding(
            get: { slidePendingDeletion != nil },
            set: { if !$0 { slidePendingDeletion = nil } }
        ), titleVisibility: .visible) {
            Button("Delete Slide", role: .destructive) {
                if let slideID = slidePendingDeletion { show.deleteSlide(slideID) }
                slidePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { slidePendingDeletion = nil }
        } message: {
            Text("This removes the slide from the library. Current Program output will not change. You can undo the deletion in Blind mode.")
        }
        .sheet(item: $notesEditorTarget, onDismiss: endTextEditing) { target in
            VStack(alignment: .leading, spacing: 14) {
                Text("Slide \(slideNumber(for: target.id)) — Notes")
                    .font(.title2.weight(.semibold))
                Text("Operator notes are saved with the show and never appear on the audience output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: notesBinding(for: target.id))
                    .focused($notesSheetFocused)
                    .id(target.id)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.gray.opacity(0.25)))
                    .frame(minHeight: 155)
                    .background(NotesClickAwayObserver { notesSheetFocused = false })
                HStack {
                    Spacer()
                    Button("Done") {
                        endTextEditing()
                        notesEditorTarget = nil
                    }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
            .frame(minWidth: 440, minHeight: 280)
        }
        .sheet(item: $transitionEditorTarget) { target in
            VStack(alignment: .leading, spacing: 14) {
                Text("Transition Duration · \(show.slides.first(where: { $0.id == target.id })?.displayTitle ?? "Slide")")
                    .font(.title3.weight(.semibold))
                Text("Seconds for this slide when it is taken Live. The show's default is used if no override is set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Seconds", text: $slideTransitionCustomText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Use Show Default") {
                        show.setSlideTransitionOverride(target.id, seconds: nil)
                        transitionEditorTarget = nil
                    }
                    Spacer()
                    Button("Cancel") { transitionEditorTarget = nil }
                    Button("Save") {
                        if let value = Double(slideTransitionCustomText), value.isFinite, value >= 0.05 {
                            show.setSlideTransitionOverride(target.id, seconds: value)
                            transitionEditorTarget = nil
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(Double(slideTransitionCustomText).map { !$0.isFinite || $0 < 0.05 || $0 > 30 } ?? true)
                }
            }
            .padding(22)
            .frame(minWidth: 400)
        }
        .onAppear { output.refreshScreens() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            output.refreshScreens()
        }
        .alert("Unable to complete action", isPresented: Binding(
            get: { fileActions.errorMessage != nil },
            set: { if !$0 { fileActions.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { fileActions.errorMessage = nil }
        } message: {
            Text(fileActions.errorMessage ?? "Unexpected error")
        }
    }

    /// A stable slide-ID binding allows both Live and Blind to edit notes
    /// without ever changing the immutable Program presentation snapshot.
    private func notesBinding(for slideID: UUID) -> Binding<String> {
        Binding(
            get: { show.slides.first(where: { $0.id == slideID })?.notes ?? "" },
            set: { value in
                guard var slide = show.slides.first(where: { $0.id == slideID }) else { return }
                slide.notes = value
                show.updateSlide(slide)
            }
        )
    }

    private func slideTitleBinding(for slideID: UUID) -> Binding<String> {
        Binding(
            get: { show.slides.first(where: { $0.id == slideID })?.slideTitle ?? "" },
            set: { value in
                guard var slide = show.slides.first(where: { $0.id == slideID }) else { return }
                slide.slideTitle = value
                show.updateSlide(slide)
            }
        )
    }

    private func slideNumber(for id: UUID) -> Int {
        (show.slides.firstIndex(where: { $0.id == id }) ?? 0) + 1
    }

    /// Live's panel edits notes for the slide on Program. Blind edits notes
    /// for the selected slide without changing anything on Program.
    private var notesPanelSlideID: UUID? {
        isBlind ? show.selectedSlideID : (show.liveSlideID ?? show.selectedSlideID)
    }

    private func editSlideTransition(for slide: PresentationSlide) {
        slideTransitionCustomText = String(format: "%.2f", show.effectiveTransitionDuration(for: slide))
        transitionEditorTarget = SlideTransitionEditorTarget(id: slide.id)
    }

    @ViewBuilder private func slideTransitionContextMenu(for slide: PresentationSlide) -> some View {
        Menu("Transition Duration") {
            Button("Use Show Default (\(String(format: "%.2f", show.transitionDuration))s)") {
                show.setSlideTransitionOverride(slide.id, seconds: nil)
            }
            Divider()
            ForEach([0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0], id: \.self) { duration in
                Button(String(format: "%.2f seconds", duration)) {
                    show.setSlideTransitionOverride(slide.id, seconds: duration)
                }
            }
            Divider()
            Button("Custom…") { editSlideTransition(for: slide) }
        }
    }

    private func editNotes(for slideID: UUID) {
        endTextEditing()
        notesEditorTarget = SlideNotesEditorTarget(id: slideID)
    }

    /// Notes are stored as the user types. "Commit" means giving up first
    /// responder, so subsequent keystrokes cannot edit a different slide.
    private func endTextEditing() {
        notesPanelFocused = false
        notesSheetFocused = false
        showTitleFocused = false
        slideTitleFocused = false
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.title2)
                .foregroundStyle(.blue)
            // The title is editable show metadata. The filename beneath it
            // identifies the document currently open on disk.
            VStack(alignment: .leading, spacing: 2) {
                TextField("Show title", text: $show.title)
                    .focused($showTitleFocused)
                    .font(.title3.weight(.semibold))
                    .textFieldStyle(.plain)
                    .help("Editable show title; saved in the show file")
                    .accessibilityLabel("Show title")
                Text(show.openedShowFilename ?? "Unsaved show")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(show.openedShowURL?.path ?? "This show has not been saved yet")
            }
            .frame(width: 245, alignment: .leading)

            Spacer(minLength: 12)
            modeBar
            Spacer(minLength: 12)

            Button {
                output.toggleWindowed(controller: show)
            } label: {
                Label("Windowed Output", systemImage: output.isWindowedOpen ? "checkmark.rectangle" : "macwindow")
                    .frame(minWidth: 130, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(OutputButtonAppearance(isActive: output.isWindowedOpen))
            .help(output.isWindowedOpen ? "Close only Windowed Output" : "Open Windowed Output")

            Button {
                output.toggleFullscreen(controller: show)
            } label: {
                Label("Fullscreen Output", systemImage: output.isFullscreenOpen ? "checkmark.rectangle.fill" : "display")
                    .frame(minWidth: 138, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(OutputButtonAppearance(isActive: output.isFullscreenOpen))
            .disabled(!output.isFullscreenOpen && output.selectedScreen == nil)
            .help(output.isFullscreenOpen ? "Close only Fullscreen Output" : "Open Fullscreen Output")
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
    }

    /// Scrollable collections are part of the top control desk in Live and
    /// the lower control desk in Blind, rather than inside the slide lists.
    private var collectionsPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Label("COLLECTIONS", systemImage: "folder")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if isBlind {
                    Button { show.addCollection() } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless)
                        .help("Create a collection")
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    collectionRow(id: nil, name: "All Slides", count: show.slides.count)
                    ForEach(show.collections) { item in
                        collectionRow(id: item.id, name: item.name,
                                      count: show.slides.filter { $0.collectionID == item.id }.count)
                    }
                }
            }
            if isBlind, let id = show.selectedCollectionID,
               show.collections.contains(where: { $0.id == id }) {
                TextField("Rename collection", text: Binding(
                    get: { show.collections.first(where: { $0.id == id })?.name ?? "" },
                    set: { show.renameCollection(id, to: $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption2)
                Button(role: .destructive) { show.deleteCollection(id) } label: {
                    Label("Delete Collection", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .font(.caption2)
                .help("Slides become unfiled; they are not deleted")
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isBlind ? blindSurface : Color.gray.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 9))
    }

    private func collectionRow(id: UUID?, name: String, count: Int) -> some View {
        let selected = show.selectedCollectionID == id
        return Button {
            endTextEditing()
            show.selectCollection(id)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: id == nil ? "square.grid.2x2" : "folder.fill")
                    .font(.caption2)
                Text(name).lineLimit(1)
                Spacer(minLength: 1)
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption2.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.25) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Color.accentColor.opacity(0.75) : Color.clear,
                              lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show slides from \(name) without changing Program")
    }

    private func moveToCollectionMenu(for id: UUID) -> some View {
        Menu("Move to Collection") {
            Button("Unfiled") { show.assignSlide(id, to: nil) }
            ForEach(show.collections) { collection in
                Button(collection.name) { show.assignSlide(id, to: collection.id) }
            }
        }
    }

    private var libraryPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("SLIDES", systemImage: "square.on.square")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Copy Selected Slide", systemImage: "doc.on.doc") {
                        if let slide = show.previewSlide { SlideClipboard.copy(slide) }
                    }
                    .disabled(show.previewSlide == nil)
                    Button("Paste Slide", systemImage: "doc.on.clipboard") {
                        if let slide = SlideClipboard.paste() {
                            show.insertCopiedSlide(slide, after: show.selectedSlideID)
                        }
                    }
                    Button("Duplicate Selected Slide", systemImage: "plus.square.on.square") {
                        if let id = show.selectedSlideID { show.duplicateSlide(id) }
                    }
                    .disabled(show.selectedSlideID == nil)
                    Divider()
                    Button("Delete Selected Slide", systemImage: "trash", role: .destructive) {
                        slidePendingDeletion = show.selectedSlideID
                    }
                    .disabled(show.selectedSlideID == nil)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .help("Copy, paste, duplicate or delete slides")
                Button { show.addSlide() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add slide")
            }

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(show.visibleSlides) { slide in
                        Button {
                            endTextEditing()
                            show.select(slide)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                SlideCanvas(slide: slide, showTransparencyCheckerboard: true)
                                    .frame(height: 112)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                    .overlay(RoundedRectangle(cornerRadius: 5)
                                        .stroke(slide.id == show.selectedSlideID ? Color.accentColor : .gray.opacity(0.15),
                                                lineWidth: slide.id == show.selectedSlideID ? 3 : 1))
                                HStack(spacing: 5) {
                                    Text("\((show.slides.firstIndex(where: { $0.id == slide.id }) ?? 0) + 1).")
                                    Text(slide.displayTitle)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    // Blind shows the authored slide; the on-air
                                    // snapshot can be an older version, so a
                                    // green LIVE dot here would be misleading.
                                }
                                .font(.caption)
                            }
                            // Transparent preview pixels must be a clickable
                            // button surface, not just the thumbnail outline.
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Copy Slide", systemImage: "doc.on.doc") { SlideClipboard.copy(slide) }
                            Button("Paste Slide After", systemImage: "doc.on.clipboard") {
                                if let copied = SlideClipboard.paste() {
                                    show.insertCopiedSlide(copied, after: slide.id)
                                }
                            }
                            Button("Duplicate Slide", systemImage: "plus.square.on.square") {
                                show.duplicateSlide(slide.id)
                            }
                            Button("Delete Slide", systemImage: "trash", role: .destructive) {
                                slidePendingDeletion = slide.id
                            }
                            Divider()
                            Button("Edit Notes…", systemImage: "note.text") { editNotes(for: slide.id) }
                            slideTransitionContextMenu(for: slide)
                            moveToCollectionMenu(for: slide.id)
                        }
                    }
                }
            }

            HStack {
                Button { show.moveSelectedSlide(by: -1) } label: { Image(systemName: "arrow.up") }
                Button { show.moveSelectedSlide(by: 1) } label: { Image(systemName: "arrow.down") }
                Spacer()
                Button(role: .destructive) { slidePendingDeletion = show.selectedSlideID } label: {
                    Image(systemName: "trash")
                }
                .disabled(show.selectedSlideID == nil)
            }
            .buttonStyle(.borderless)
        }
        .padding(13)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(isBlind ? blindSurface : Color.gray.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    /// All six panels belong to ONE layout, with a single Program monitor.
    /// In v0.2.8 each mode used a different view tree, so moving between
    /// Live/Blind destroyed and rebuilt panels rather than animating their
    /// geometry. Keeping Program mounted also protects AVPlayer continuity.
    /// Preserve the single Program instance as the workspace morphs, and
    /// provide a draggable Live-zone divider independent of show content.
    private var mainPane: some View {
        GeometryReader { geometry in
            // Same limits are used by the splitter AND the custom layout.
            // There is no extra hidden minimum that the handle can cross.
            let upperMax = max(350, geometry.size.height - 165)
            let upperZone = min(max(350, CGFloat(liveTopZoneHeight)), upperMax)
            ZStack(alignment: .topLeading) {
                MorphingWorkspaceLayout(isBlind: isBlind, liveTopHeight: upperZone,
                                        blindBottomHeight: CGFloat(blindBottomZoneHeight)) {
                    ZStack {
                        if isBlind {
                            blindEditor
                                // The selection border belongs to Blind only.
                                // Never keep an outgoing editor snapshot alive
                                // during the Live workspace morph.
                                .transition(.identity)
                        }
                    }
                    .clipped()
                    .opacity(isBlind ? 1 : 0)
                    .allowsHitTesting(isBlind)
                    .accessibilityHidden(!isBlind)

                    // The same Program view survives layout changes.
                    programColumn

                    controlDesk
                    // Reserved layout slot for backwards-compatible morphing.
                    // The real Program actions now live within Program itself.
                    Color.clear
                        .allowsHitTesting(false)

                    ZStack {
                        if !isBlind { liveSlideCollection }
                    }
                    .clipped()
                    .opacity(isBlind ? 0 : 1)
                    .allowsHitTesting(!isBlind)
                    .accessibilityHidden(isBlind)
                }
                .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.88),
                           value: show.mode)
                // Video transport has a reserved footprint. Changing slide
                // media does not animate/re-measure the whole Program desk.

                if !isBlind {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, height: 14)
                        .background(Color.gray.opacity(0.22), in: Capsule())
                        .contentShape(Capsule())
                        // Center within the 20-point separator gap, never
                        // covering either the top panels or the Slides card.
                        .offset(x: (geometry.size.width - 48) / 2, y: upperZone + 3)
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if topZoneDragOrigin == nil { topZoneDragOrigin = Double(upperZone) }
                            let next = (topZoneDragOrigin ?? Double(upperZone)) + Double(value.translation.height)
                            liveTopZoneHeight = min(max(350, next), Double(upperMax))
                        }
                        .onEnded { _ in topZoneDragOrigin = nil })
                    .help("Drag vertically to resize the Program and controls area")
                    .zIndex(10)
                } else {
                    let bottomHeight = min(max(0, geometry.size.height - 180),
                                           max(285, CGFloat(blindBottomZoneHeight)))
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, height: 14)
                        .background(Color.gray.opacity(0.22), in: Capsule())
                        .contentShape(Capsule())
                        .offset(x: (geometry.size.width - 48) / 2,
                                y: geometry.size.height - bottomHeight - 20 + 3)
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if blindZoneDragOrigin == nil { blindZoneDragOrigin = Double(bottomHeight) }
                            let next = (blindZoneDragOrigin ?? Double(bottomHeight)) - Double(value.translation.height)
                            blindBottomZoneHeight = min(max(285, next), Double(max(285, geometry.size.height - 180)))
                        }
                        .onEnded { _ in blindZoneDragOrigin = nil })
                    .help("Drag to resize Blind's editor and lower control desk")
                    .zIndex(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Live navigation is now between Program and the slide library.
    /// Notes remain an independent card above Transition in the control desk.
    private var programColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            programMonitor
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var controlDesk: some View {
        GeometryReader { geometry in
            let available = max(1, geometry.size.width)
            let gap: CGFloat = 8
            let left = max(0, (available - 2 * gap) * 0.32)
            let middle = max(0, (available - 2 * gap) * 0.25)
            let halfHeight = max(0, (geometry.size.height - gap) / 2)
            HStack(alignment: .top, spacing: gap) {
                VStack(spacing: gap) {
                    if !isBlind {
                        notesPanel
                            .frame(maxWidth: .infinity)
                            .frame(height: halfHeight)
                        ScrollView(.vertical) {
                            transitionControls
                                .frame(maxWidth: .infinity)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: halfHeight)
                        .background(Color.gray.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 9))
                    } else {
                        ScrollView(.vertical) {
                            transitionControls
                                .frame(maxWidth: .infinity)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(blindSurface, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                .frame(width: left, height: geometry.size.height)
                collectionsPanel
                    .frame(width: middle, height: geometry.size.height)
                ProgramAudioMixer(show: show, isBlind: isBlind)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var blindEditor: some View {
        GeometryReader { geometry in
            // The old outer ScrollView showed a scrollbar even with a single
            // layer: canvasHeight was calculated as panelHeight - 85, while
            // the editor toolbar, spacing and padding require about 110pt.
            // Size the canvas to its actual slot and leave only the Layers
            // inspector scrollable when a slide has many editable objects.
            if let selected = show.previewSlide {
                SlideEditorView(slide: Binding(
                    get: { show.slides.first(where: { $0.id == selected.id }) ?? selected },
                    set: { show.updateSlide($0) }
                ), canvasHeight: max(90, geometry.size.height - 116),
                   isBlindTheme: true, controller: show)
                .id(selected.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ContentUnavailableView("No slide selected", systemImage: "rectangle.on.rectangle.slash",
                                       description: Text("Add a slide to begin."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The Live / Blind selector belongs in the app's highest content row,
    /// rather than consuming valuable space above the slide editor.
    private var modeBar: some View {
        HStack(spacing: 8) {
            Picker("Mode", selection: $show.mode) {
                Text("Live").tag(OperationMode.live)
                Text("Blind").tag(OperationMode.blind)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
            .help("Live sends clicked slides to Program. Blind protects the audience while editing.")
            // The mode control has a fixed width. The BLIND badge lives in
            // the bottom status bar, so the header never shifts horizontally.
        }
    }

    /// Blind transport now contains playback/seek only (no audio mixer); keep
    /// its reserved footprint small so the preview gets the available height.
    /// Layer audio gain lives in the Blind inspector, and cue gain in the mixer.
    private var blindVideoTransportHeight: CGFloat {
        guard !show.isCleared, let slide = show.liveSlide, !show.liveVideoSessions.isEmpty else {
            return 0
        }
        let backgroundCount = (slide.backgroundVideoPath?.isEmpty == false) ? 1 : 0
        let visibleVideos = slide.layers.filter {
            $0.kind == .video && $0.isVisible && $0.videoPath?.isEmpty == false
        }.count
        return (backgroundCount + visibleVideos) > 1 ? 76 : 52
    }

    private var programMonitor: some View {
        VStack(alignment: .leading, spacing: isBlind ? 4 : 7) {
            HStack(spacing: 7) {
                Text("PROGRAM")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                if show.liveSlide != nil {
                    PulsingProgramBadge(title: show.isBlackout ? "BLACKOUT" : (show.isCleared ? "CLEARED" : "LIVE"),
                                        tint: show.isBlackout ? .red : (show.isCleared ? .gray : .green))
                }
                Spacer(minLength: 0)
            }

            // Fill all available Program display area while preserving the
            // 16:9 canvas. The surrounding transport has a reserved height,
            // so adding/removing video controls doesn't resize the monitor.
            GeometryReader { area in
                let width = min(area.size.width, area.size.height * (16.0 / 9.0))
                let height = width * (9.0 / 16.0)
                ProgramCanvas(controller: show)
                    .transaction { $0.disablesAnimations = true }
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .frame(width: max(0, width), height: max(0, height))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Live Program preview")

            // Keep playback and seeking visible. Gain/mute remain in the Audio Mixer
            // and individual layer inspector, not the Program transport.
            if !isBlind || blindVideoTransportHeight > 0 {
                ProgramVideoTransport(show: show, compact: isBlind)
                    .controlSize(.mini)
                    .frame(height: isBlind ? blindVideoTransportHeight : 112, alignment: .top)
            }

            programNavigationAndEmergencyControls

            if isBlind {
                AutoCountdownButton(show: show)
                    .frame(height: 30)
                    .help("Program Auto continues while Blind editing is active")
            }

        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isBlind
                    ? Color(red: 0.20, green: 0.21, blue: 0.23)
                    : Color.gray.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isBlind ? Color.gray.opacity(0.55) : Color.clear, lineWidth: 1))
        .animation(.easeInOut(duration: 0.28), value: show.mode)
    }

    /// Both modes operate on live Program; Blind keeps its compact single row.
    /// Live gives navigation its own full-width row above the emergency actions.
    private var programNavigationAndEmergencyControls: some View {
        Group {
            if isBlind {
                HStack(spacing: 5) {
                    programPreviousButton
                    programNextButton
                    programClearSlideButton
                    programBlackoutButton
                }
            } else {
                VStack(spacing: 5) {
                    HStack(spacing: 5) {
                        programPreviousButton
                        programNextButton
                    }
                    HStack(spacing: 5) {
                        programClearSlideButton
                        programBlackoutButton
                    }
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live Program navigation and emergency controls")
    }

    private var programPreviousButton: some View {
        Button {
            endTextEditing()
            if isBlind { show.advanceProgram(by: -1) }
            else { show.advance(by: -1) }
        } label: {
            if isBlind {
                Label("Previous", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
                    .frame(width: 25, height: 26)
            } else {
                Label("Previous", systemImage: "chevron.left")
                    .frame(maxWidth: .infinity, minHeight: 26)
            }
        }
        .help("Take the previous slide live")
    }

    private var programNextButton: some View {
        Button {
            endTextEditing()
            if isBlind { show.advanceProgram(by: 1) }
            else { show.advance(by: 1) }
        } label: {
            if isBlind {
                Label("Next", systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
                    .frame(width: 25, height: 26)
            } else {
                HStack(spacing: 5) {
                    Text("Next")
                    Image(systemName: "chevron.right")
                }
                .frame(maxWidth: .infinity, minHeight: 26)
            }
        }
        .help("Take the next slide live")
    }

    private var programClearSlideButton: some View {
        Button { show.toggleClear() } label: {
            Label(show.isCleared ? "Restore Slide" : "Clear Slide",
                  systemImage: show.isCleared ? "rectangle.stack.fill" : "rectangle.stack.badge.minus")
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: 26)
        }
        .help("Clear or restore the entire live slide")
    }

    private var programBlackoutButton: some View {
        // Explicit red/green fills remain bright when an output window is key.
        Button { show.toggleBlackout() } label: {
            Label(show.isBlackout ? "End Blackout" : "Blackout",
                  systemImage: show.isBlackout ? "sun.max.fill" : "moon.fill")
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .contentTransition(.opacity)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, minHeight: 26)
                .background(show.isBlackout
                    ? Color(red: 0.13, green: 0.52, blue: 0.31)
                    : Color(red: 0.76, green: 0.19, blue: 0.23),
                    in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.white.opacity(0.26), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.32), value: show.isBlackout)
        .help("Blackout stays colored even when an audience-output window is active")
    }

    private var liveSlideCollection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("SLIDES", systemImage: liveSlideViewMode == "list" ? "list.bullet.rectangle" : "square.grid.3x2.fill")
                    .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Text("Click a slide to take it live.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Picker("View", selection: $liveSlideViewMode) {
                    Label("Icons", systemImage: "square.grid.2x2").tag("icons")
                    Label("List", systemImage: "list.bullet").tag("list")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                Text("\(show.visibleSlides.count) slides")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 3)
            .padding(.top, 3)
            if liveSlideViewMode == "list" {
                liveSlideList
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 175, maximum: 252), spacing: 16)],
                              alignment: .leading, spacing: 16) {
                        ForEach(show.visibleSlides) { slide in
                            liveSlideIcon(slide)
                        }
                    }
                    .padding(.horizontal, 3)
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var liveSlideList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("#").frame(width: 22)
                Text("THUMBNAIL").frame(width: 105, alignment: .leading)
                Text("SLIDE").frame(maxWidth: .infinity, alignment: .leading)
                Text("NOTES").frame(maxWidth: .infinity, alignment: .leading)
                Text("STATE").frame(width: 55, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(9)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(show.visibleSlides) { slide in
                        let index = show.visibleSlides.firstIndex(where: { $0.id == slide.id }) ?? 0
                        HStack(spacing: 12) {
                            Button {
                                endTextEditing()
                                show.takeLive(slide)
                            } label: {
                                HStack(spacing: 12) {
                                    Text("\(index + 1)")
                                        .frame(width: 22)
                                        .font(.caption.monospacedDigit())
                                    SlideCanvas(slide: slide, showTransparencyCheckerboard: true).frame(width: 105, height: 59)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                    Text(slide.displayTitle)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Click to take slide live")

                            // A dedicated notes cell never takes a slide live:
                            // double-click edits while right-click works anywhere.
                            Text(slide.notes.isEmpty ? "Double-click to add notes" : slide.notes)
                                .foregroundStyle(slide.notes.isEmpty ? .tertiary : .secondary)
                                .font(.caption)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { editNotes(for: slide.id) }
                                .help("Double-click to edit notes; does not change Program")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { editNotes(for: slide.id) }
                            Text(slide.id == show.liveSlideID && !show.isCleared && !show.isBlackout ? "LIVE" : "")
                                .foregroundStyle(.green)
                                .font(.caption.bold())
                                .frame(width: 55, alignment: .trailing)
                        }
                        .padding(7)
                        .background(slide.id == show.liveSlideID ? Color.green.opacity(0.10) : Color.clear)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Edit Notes…", systemImage: "note.text") { editNotes(for: slide.id) }
                            slideTransitionContextMenu(for: slide)
                            moveToCollectionMenu(for: slide.id)
                        }
                        Divider()
                    }
                }
            }
        }
    }

    private func liveSlideIcon(_ slide: PresentationSlide) -> some View {
        let selected = slide.id == show.selectedSlideID
        let onAir = slide.id == show.liveSlideID && show.liveSlide != nil && !show.isBlackout && !show.isCleared
        let slideNumber = (show.slides.firstIndex(where: { $0.id == slide.id }) ?? 0) + 1

        return Button {
            endTextEditing()
            // In Live mode, icon clicks are intentional TAKE actions.
            // The controller also guards against calls made in Blind mode.
            show.takeLive(slide)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                SlideCanvas(slide: slide, showTransparencyCheckerboard: true)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12),
                                          lineWidth: selected ? 3 : 1)
                    }
                HStack(alignment: .center, spacing: 6) {
                    Text("\(slideNumber).")
                        .font(.caption.weight(.semibold).monospacedDigit())
                    Text(slide.displayTitle)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 5) {
                    if onAir {
                        Label("LIVE", systemImage: "circle.fill")
                            .foregroundStyle(.green)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10, weight: .semibold))
                .frame(height: 13)
            }
            .padding(9)
            .background(selected ? Color.accentColor.opacity(0.11) : Color.gray.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit Notes…", systemImage: "note.text") { editNotes(for: slide.id) }
            slideTransitionContextMenu(for: slide)
            moveToCollectionMenu(for: slide.id)
        }
        .help("Click to take slide \(slideNumber) live, or right-click to edit notes.")
    }

    private var transitionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isBlind, let slideID = show.selectedSlideID {
                VStack(alignment: .leading, spacing: 4) {
                    Label("SLIDE TITLE", systemImage: "character.cursor.ibeam")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("Name this slide", text: slideTitleBinding(for: slideID))
                        .textFieldStyle(.roundedBorder)
                        .focused($slideTitleFocused)
                        .id("slide-title-\(slideID)")
                        .onSubmit { slideTitleFocused = false }
                        .help("This title appears in slide lists, but never on the audience output")
                }
            }
            Label("TRANSITION", systemImage: "square.stack.3d.up")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 8) {
                Picker("Effect", selection: $show.transitionStyle) {
                    ForEach(SlideTransitionStyle.allCases) { effect in
                        Text(effect.rawValue).tag(effect)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                globalTransitionTimeControls
                    .frame(width: 102, alignment: .trailing)
            }

            if !isBlind {
                HStack(spacing: 8) {
                    AutoCountdownButton(show: show)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                    LoopCollectionButton(show: show)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                }
                .help("Auto and Loop toggle independently; neither changes slide transition duration")
            }

            SlideAutoplayControls(show: show, isBlind: isBlind)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The ScrollView hosting Transition already paints the panel surface.
        // Avoid layering a second, lighter rectangle inside that dark card.
    }

    private var globalTransitionTimeControls: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Menu {
                ForEach([0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0], id: \.self) { duration in
                    Button(String(format: "%.2f seconds", duration)) {
                        show.transitionDuration = duration
                        editingGlobalTransitionTime = false
                        show.refreshAutoAdvance()
                    }
                }
                Divider()
                Button("Custom…") {
                    globalTransitionCustomText = String(format: "%.2f", show.transitionDuration)
                    editingGlobalTransitionTime = true
                }
            } label: {
                HStack(spacing: 4) {
                    Text(String(format: "%.2f s", show.transitionDuration))
                        .monospacedDigit().lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(show.transitionStyle == .cut)
            .help("Global transition time; right-click an individual slide to override")
            if editingGlobalTransitionTime {
                TextField("Seconds", text: $globalTransitionCustomText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitGlobalTransitionTime() }
                Button("Apply") { commitGlobalTransitionTime() }
                    .controlSize(.mini)
            }
            if let slide = isBlind ? show.previewSlide : show.liveSlide,
               let seconds = slide.transitionSecondsOverride {
                Text(String(format: "Slide: %.2f s", seconds))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Right-click the slide for its transition override")
            }
        }
    }

    /// Notes have their own card; they are never included in Program output.
    private var notesPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let slideID = notesPanelSlideID {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Label("NOTES · SLIDE \(slideNumber(for: slideID))", systemImage: "note.text")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Edit Notes", systemImage: "square.and.pencil") {
                            editNotes(for: slideID)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Open a larger notes editor")
                    }
                    TextEditor(text: notesBinding(for: slideID))
                        .focused($notesPanelFocused)
                        // Force a fresh AppKit text view for every note target
                        // and mode; a retained NSTextView can keep its caret.
                        .id("\(slideID.uuidString)-\(show.mode)")
                        .font(.caption)
                        .scrollContentBackground(.hidden)
                        .padding(3)
                        .frame(minHeight: 55, maxHeight: .infinity)
                        .background(NotesClickAwayObserver { notesPanelFocused = false })
                        .background(Color.gray.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.gray.opacity(0.22)))
                        .help("Click outside to finish editing. Notes never appear on Program.")
                }
            } else {
                Text("Select a slide to edit notes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isBlind ? blindSurface : Color.gray.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 9))
    }

    private func commitGlobalTransitionTime() {
        guard let value = Double(globalTransitionCustomText), value.isFinite,
              value >= 0.05, value <= 30 else { return }
        show.transitionDuration = value
        show.refreshAutoAdvance()
        editingGlobalTransitionTime = false
    }



}


/// Timed slide controls. The TimelineView is scoped to the button itself so
/// its 10 fps countdown cannot invalidate the editor's morphing layout.
private struct SlideAutoplayControls: View {
    @ObservedObject var show: ShowController
    let isBlind: Bool
    @State private var customTimeText = ""
    @State private var editingCustomTime = false
    @State private var customSlideTimeText = ""
    @State private var editingCustomSlideTime = false

    private var slide: PresentationSlide? {
        guard let id = isBlind ? show.selectedSlideID : show.liveSlideID else { return nil }
        return show.slides.first(where: { $0.id == id })
    }
    private func setSlideTime(_ seconds: Double?) {
        guard var edited = slide else { return }
        edited.autoAdvanceSeconds = seconds
        show.updateSlide(edited)
        if show.liveSlideID == edited.id { show.refreshAutoAdvance() }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text("GLOBAL AUTO TIME")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach([3.0, 5, 10, 15, 20, 30, 45, 60], id: \.self) { seconds in
                        Button("\(Int(seconds)) seconds") {
                            show.globalAutoAdvanceSeconds = seconds
                            show.refreshAutoAdvance()
                        }
                    }
                    Divider()
                    Button("Custom…") {
                        customTimeText = String(format: "%.1f", show.globalAutoAdvanceSeconds)
                        editingCustomTime = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(String(format: "%.1f s", show.globalAutoAdvanceSeconds))
                            .monospacedDigit().lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if editingCustomTime {
                    TextField("Seconds", text: $customTimeText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { applyCustomTime() }
                    Button("Apply") { applyCustomTime() }
                        .controlSize(.mini)
                }
            }
            .frame(width: 102, alignment: .leading)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 5) {
                Text("SLIDE AUTO TIME")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let slide {
                    Menu {
                        Button("Use Global Time") { setSlideTime(nil) }
                        ForEach([3.0, 5, 10, 15, 20, 30, 60], id: \.self) { seconds in
                            Button("\(Int(seconds)) seconds") { setSlideTime(seconds) }
                        }
                        Divider()
                        Button("Custom Slide Time…") {
                            customSlideTimeText = String(format: "%.1f", slide.autoAdvanceSeconds ?? show.globalAutoAdvanceSeconds)
                            editingCustomSlideTime = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(slide.autoAdvanceSeconds.map { String(format: "%.1f s", $0) } ?? "Global")
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.down").font(.system(size: 9))
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help("Per-slide auto advance time; overrides the global selection")
                    if editingCustomSlideTime {
                        TextField("Slide seconds", text: $customSlideTimeText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { applyCustomSlideTime() }
                        Button("Apply") { applyCustomSlideTime() }
                            .controlSize(.mini)
                    }
                } else {
                    Text("No slide")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 102, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func applyCustomSlideTime() {
        guard let value = Double(customSlideTimeText), value.isFinite, value >= 0.5, value <= 3600 else { return }
        setSlideTime(value)
        editingCustomSlideTime = false
    }
    private func applyCustomTime() {
        guard let value = Double(customTimeText), value.isFinite, value >= 0.5, value <= 3600 else { return }
        show.globalAutoAdvanceSeconds = value
        show.refreshAutoAdvance()
        editingCustomTime = false
    }
}

/// Independently toggles looping. The neutral, bright-gray active treatment
/// deliberately does not imply a Program take or a green ON-AIR change.
private struct LoopCollectionButton: View {
    @ObservedObject var show: ShowController

    var body: some View {
        Button {
            show.loopAutoAdvance.toggle()
            if show.autoAdvanceEnabled && show.autoAdvanceDeadline == nil {
                show.refreshAutoAdvance()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: show.loopAutoAdvance ? "repeat.circle.fill" : "repeat.circle")
                Text("Loop Collection").lineLimit(1).minimumScaleFactor(0.85)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(Color.gray.opacity(show.loopAutoAdvance ? 0.34 : 0.13),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.gray.opacity(show.loopAutoAdvance ? 0.85 : 0.35),
                              lineWidth: show.loopAutoAdvance ? 1.5 : 0.8))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Loop Collection")
        .accessibilityValue(show.loopAutoAdvance ? "On" : "Off")
        .help(show.loopAutoAdvance ? "Disable collection looping" : "Loop the current collection")
    }
}

private struct AutoCountdownButton: View {
    @ObservedObject var show: ShowController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if show.autoAdvanceEnabled, show.autoAdvanceDeadline != nil {
                TimelineView(.periodic(from: .now, by: 0.10)) { timeline in
                    autoButton(at: timeline.date)
                }
            } else {
                autoButton(at: .now)
            }
        }
    }

    private func autoButton(at date: Date) -> some View {
        let start = show.autoAdvanceStart
        let deadline = show.autoAdvanceDeadline
        let total = max(0.001, deadline?.timeIntervalSince(start ?? date) ?? 0)
        let elapsed = min(total, max(0, date.timeIntervalSince(start ?? date)))
        let progress = start != nil && deadline != nil ? elapsed / total : 0
        let secondsLeft = deadline.map { max(0, Int(ceil($0.timeIntervalSince(max(date, start ?? date))))) }
        let fadingTake = show.activeTransition.flatMap { transition -> ProgramTransition? in
            transition.id == show.autoTriggeredTransitionID ? transition : nil
        }
        let fadeProgress = fadingTake?.progress(at: date) ?? 1

        return Button {
            show.autoAdvanceEnabled.toggle()
            show.refreshAutoAdvance()
        } label: {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.gray.opacity(show.autoAdvanceEnabled ? 0.33 : 0.13))
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.gray.opacity(show.autoAdvanceEnabled ? 0.38 : 0))
                        .frame(width: max(0, geometry.size.width * progress))
                    // Auto reached 100%: the former fill fades away during the
                    // actual dissolve, rather than snapping empty on take.
                    if fadingTake != nil {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.gray.opacity(0.38))
                            .opacity(max(0, 1 - fadeProgress))
                    }
                    HStack(spacing: 5) {
                        Image(systemName: show.autoAdvanceEnabled ? "timer" : "arrow.right.circle")
                        Text("Auto Transition")
                        if show.autoAdvanceEnabled, let secondsLeft {
                            Text(String(format: "%02d:%02d", secondsLeft / 60, secondsLeft % 60))
                                .monospacedDigit()
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                                .opacity(fadingTake == nil ? 1 : fadeProgress)
                        }
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: secondsLeft != nil)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.gray.opacity(show.autoAdvanceEnabled ? 0.85 : 0.35),
                                  lineWidth: show.autoAdvanceEnabled ? 1.5 : 0.8))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(show.autoAdvanceEnabled ? "Disable automatic slide advance" : "Enable automatic slide advance")
        .help(show.autoAdvanceEnabled ? "Click to stop automatic advance" : "Click to enable automatic advance")
        .animation(reduceMotion ? nil : .linear(duration: 0.10), value: progress)
    }
}

/// A real, vertically oriented fader (not a rotated slider) with a continuous
/// hit target, separate mute below, and deterministic 0...1 binding.
private struct VerticalMixerFader: View {
    let title: String
    @Binding var gain: Double
    @Binding var muted: Bool

    var body: some View {
        VStack(spacing: 5) {
            Text(title).font(.system(size: 10, weight: .semibold))
                .lineLimit(2).multilineTextAlignment(.center)
                .frame(height: 27, alignment: .center)
                .help(title)
            Text("\(Int((gain * 100).rounded()))%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            GeometryReader { geometry in
                let usableHeight = max(1, geometry.size.height - 15)
                let knobY = 7.5 + (1 - CGFloat(gain)) * usableHeight
                ZStack {
                    Capsule().fill(Color.gray.opacity(0.25))
                        .frame(width: 8, height: usableHeight)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    Capsule().fill(muted ? Color.red.opacity(0.4) : Color.accentColor)
                        .frame(width: 8, height: usableHeight * CGFloat(gain))
                        .position(x: geometry.size.width / 2,
                                  y: geometry.size.height - 7.5 - usableHeight * CGFloat(gain) / 2)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .frame(width: 30, height: 13)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.4))
                        .position(x: geometry.size.width / 2, y: knobY)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let y = min(max(value.location.y - 7.5, 0), usableHeight)
                    gain = Double(1 - y / usableHeight)
                })
            }
            .frame(minHeight: 84, maxHeight: .infinity)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("\(title) volume")
            .accessibilityValue("\(Int((gain * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: gain = min(1, gain + 0.05)
                case .decrement: gain = max(0, gain - 0.05)
                @unknown default: break
                }
            }
            Button { muted.toggle() } label: {
                Label(muted ? "Unmute" : "Mute", systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(muted ? Color.red : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: 22)
            }
            .buttonStyle(.bordered)
            .help(muted ? "Unmute \(title)" : "Mute \(title)")
            .accessibilityLabel(muted ? "Unmute \(title)" : "Mute \(title)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProgramAudioMixer: View {
    @ObservedObject var show: ShowController
    let isBlind: Bool
    @Namespace private var cuePositions
    @ObservedObject private var mixer = LiveAudioMix.shared

    private func volumeBinding(for slideID: UUID?) -> Binding<Double> {
        Binding(get: {
            guard let slideID else { return 1 }
            return show.slides.first(where: { $0.id == slideID })?.cueAudioGain ?? 1
        }, set: { gain in
            guard let slideID else { return }
            show.setSlideAudioGain(slideID, to: gain)
        })
    }
    private func muteBinding(for slideID: UUID?) -> Binding<Bool> {
        Binding(get: {
            guard let slideID else { return false }
            return show.slides.first(where: { $0.id == slideID })?.cueAudioMuted ?? false
        }, set: { muted in
            guard let slideID else { return }
            show.setSlideAudioMuted(slideID, to: muted)
        })
    }

    private var programHasAudio: Bool {
        show.liveSlideSnapshot?.containsAudioMedia ?? false
    }

    private var nextHasAudio: Bool {
        guard let next = show.nextQueuedSlide else { return false }
        return next.preparedForProgram(after: show.liveSlideSnapshot).containsAudioMedia
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("AUDIO MIXER", systemImage: "slider.vertical.3")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            if isBlind {
                Label("STILL LIVE · Changes affect audience audio", systemImage: "speaker.wave.2")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
            }
            HStack(alignment: .top, spacing: 4) {
                VerticalMixerFader(title: show.liveSlide?.displayTitle ?? "Program —",
                                   gain: volumeBinding(for: show.liveSlideID),
                                   muted: muteBinding(for: show.liveSlideID))
                    .matchedGeometryEffect(id: "cue-\(show.liveSlideID?.uuidString ?? "program")", in: cuePositions)
                    .id("program-\(show.liveSlideID?.uuidString ?? "none")")
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 15)),
                        removal: .opacity.combined(with: .offset(x: -15))))
                    .opacity(programHasAudio ? 1 : 0.30)
                    .saturation(programHasAudio ? 1 : 0)
                    .allowsHitTesting(programHasAudio)
                    .accessibilityLabel(programHasAudio ? "Program contains audio" : "Program has no audio")
                VerticalMixerFader(title: show.nextQueuedSlide?.displayTitle ?? "Next —",
                                   gain: volumeBinding(for: show.nextQueuedSlide?.id),
                                   muted: muteBinding(for: show.nextQueuedSlide?.id))
                    .matchedGeometryEffect(id: "cue-\((show.nextQueuedSlide?.id == show.liveSlideID ? "next-loop" : show.nextQueuedSlide?.id.uuidString) ?? "next")", in: cuePositions)
                    .id("next-\(show.nextQueuedSlide?.id.uuidString ?? "none")")
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 15)),
                        removal: .opacity.combined(with: .offset(x: -15))))
                    .opacity(nextHasAudio ? 1 : 0.30)
                    .saturation(nextHasAudio ? 1 : 0)
                    .allowsHitTesting(nextHasAudio)
                    .accessibilityLabel(nextHasAudio ? "Next slide contains audio" : "Next slide has no audio")
                Divider().frame(maxHeight: .infinity).padding(.horizontal, 2)
                VerticalMixerFader(title: "Master", gain: $mixer.master, muted: $mixer.masterMuted)
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.84), value: show.liveSlideID)
            .frame(maxHeight: .infinity)
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isBlind
                    ? Color(red: 0.20, green: 0.21, blue: 0.23)
                    : Color.gray.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(isBlind ? Color.gray.opacity(0.55) : Color.clear, lineWidth: 1))
    }
}

private struct SlideTransitionEditorTarget: Identifiable {
    let id: UUID
}

private struct SlideNotesEditorTarget: Identifiable {
    let id: UUID
}

/// Shared five-slot layout preserves Program's view identity as it morphs.
/// Slots: blind editor, Program, top control desk, Live Program navigation, slide collection.
private struct MorphingWorkspaceLayout: Layout {
    var blindProgress: CGFloat
    var liveTopHeight: CGFloat
    var blindBottomHeight: CGFloat
    init(isBlind: Bool, liveTopHeight: CGFloat, blindBottomHeight: CGFloat) {
        blindProgress = isBlind ? 1 : 0
        self.liveTopHeight = liveTopHeight
        self.blindBottomHeight = blindBottomHeight
    }
    var animatableData: CGFloat {
        get { blindProgress }
        set { blindProgress = newValue }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: max(0, proposal.width ?? 900), height: max(0, proposal.height ?? 600))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard subviews.count == 5 else { return }
        let w = max(0, bounds.width), h = max(0, bounds.height)
        let gap: CGFloat = 20 // Reserved space for the centered resize handle.
        func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: x, y: y, width: max(0, width), height: max(0, height))
        }
        let hidden = CGRect.zero
        // Live: Program occupies upper-left, controls at upper-right.
        // Slide grid/list uses the whole width below the monitors.
        let liveProgramWidth = min(450, max(0, w * 0.43))
        let settingsWidth = max(0, w - liveProgramWidth - gap)
        let liveTopH = min(max(350, h - 165), max(350, liveTopHeight))
        let live: [CGRect] = [hidden,
            rect(0, 0, liveProgramWidth, liveTopH),
            rect(liveProgramWidth + gap, 0, settingsWidth, liveTopH),
            hidden, // Program transport/actions are now inside the Program card.
            rect(0, liveTopH + gap, w, h - liveTopH - gap)]

        // Blind: editor expands, Program remains a charcoal inset at right.
        let blindProgramW = min(318, max(0, w * 0.43))
        let blindActionsW = max(0, w - blindProgramW - gap)
        let bottomH = min(max(0, h - 180),
                          max(285, blindBottomHeight))
        let editorH = max(0, h - bottomH - gap)
        let blind: [CGRect] = [
            rect(0, 0, w, editorH),
            rect(w - blindProgramW, h - bottomH, blindProgramW, bottomH),
            rect(0, h - bottomH, blindActionsW, bottomH),
            hidden,
            hidden]
        let t = min(1, max(0, blindProgress))
        func interp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        for i in 0..<5 {
            let a = live[i], b = blind[i]
            subviews[i].place(at: CGPoint(x: bounds.minX + interp(a.minX, b.minX),
                                          y: bounds.minY + interp(a.minY, b.minY)),
                              anchor: .topLeading,
                              proposal: ProposedViewSize(width: max(0, interp(a.width, b.width)),
                                                         height: max(0, interp(a.height, b.height))))
        }
    }
}


/// Stable custom button styling. Unlike the standard bordered-prominent
/// macOS control, this green active outline does not dim gray when the
/// Windowed/Fullscreen audience window becomes the key application window.
private struct OutputButtonAppearance: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.semibold))
            .foregroundStyle(isActive ? Color(red: 0.34, green: 0.91, blue: 0.56) : Color.primary)
            .background(isActive ? Color.green.opacity(0.20) : Color.gray.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isActive ? Color.green : Color.gray.opacity(0.25),
                              lineWidth: isActive ? 1.7 : 0.8))
    }
}

/// Pulses the operator's Program status only; never animates audience content.
private struct PulsingProgramBadge: View {
    let title: String
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBright = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(.white)
                .frame(width: 5, height: 5)
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .contentTransition(.opacity)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint, in: Capsule())
        .opacity(reduceMotion ? 1 : (isBright ? 1.0 : 0.58))
        .scaleEffect(reduceMotion ? 1 : (isBright ? 1.03 : 0.98))
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.15).repeatForever(autoreverses: true), value: isBright)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.38), value: title)
        .onAppear { isBright = true }
        .accessibilityLabel("Program status: " + title)
    }
}


/// A small, tactile control style that animates only the operator interface.
/// It never changes the appearance or timing of the audience output.
private struct VideoTransportActionStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.22 : 0.12),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(configuration.isPressed ? 0.48 : 0.23),
                              lineWidth: 1))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.60),
                       value: configuration.isPressed)
    }
}

/// Transport controls use the SAME AVPlayer sessions that Program and the
/// external audience window are rendering. Their presentation is animated,
/// not their playback state: the audience output never receives these effects.
@MainActor
private struct ProgramVideoTransport: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var show: ShowController
    let compact: Bool
    @State private var selectedPath = ""
    @State private var scrubbing = false
    @State private var scrubPreview = 0.0
    // The UI switches icons immediately when clicked. AVPlayer.rate is NOT
    // treated as user intent; the retained pool continues to own that state.
    @State private var immediatePauseKey = ""
    @State private var immediatePaused: Bool? = nil

    private struct Source: Identifiable {
        let path: String
        let label: String
        var id: String { path }
    }

    private var sources: [Source] {
        guard let slide = show.liveSlide, !show.isCleared else { return [] }
        var results: [Source] = []
        var seen = Set<String>()
        func add(_ path: String, label: String) {
            let canonical = VideoTakePlanner.canonical(path)
            guard show.liveVideoSessions[canonical] != nil, seen.insert(canonical).inserted else { return }
            results.append(Source(path: canonical, label: label))
        }
        if let background = slide.backgroundVideoPath, !background.isEmpty {
            add(background, label: "Background: " + URL(fileURLWithPath: background).lastPathComponent)
        }
        for layer in slide.layers where layer.isVisible && layer.kind == .video {
            if let path = layer.videoPath, !path.isEmpty {
                add(path, label: layer.name + ": " + URL(fileURLWithPath: path).lastPathComponent)
            }
        }
        return results
    }

    // Source/slide changes update transport content immediately. Morphing the
    // transport cards between slides was distracting during live operation.

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let currentSources = sources
                if let source = currentSources.first(where: { $0.path == selectedPath }) ?? currentSources.first,
                   let session = show.liveVideoSessions[source.path] {
                    let sessionKey = source.path + "#" + session.uuidString
                    let status = VideoPlaybackPool.shared.transportStatus(path: source.path, sessionID: session)
                    let retainedPaused = VideoPlaybackPool.shared.isPaused(path: source.path, sessionID: session)
                    let paused = immediatePauseKey == sessionKey
                        ? (immediatePaused ?? retainedPaused) : retainedPaused

                    VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                        if currentSources.count > 1 {
                            Picker("Control video", selection: Binding(
                                get: { currentSources.contains(where: { $0.path == selectedPath }) ? selectedPath : source.path },
                                set: { selectedPath = $0; scrubbing = false }
                            )) {
                                ForEach(currentSources) { candidate in
                                    Text(candidate.label).tag(candidate.path)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else if !compact {
                            HStack(spacing: 6) {
                                Image(systemName: "film.stack")
                                    .foregroundStyle(Color.accentColor)
                                Text(source.label)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }

                        if compact {
                            // A single compact transport row reclaims space for
                            // the actual Program picture in Blind.
                            HStack(spacing: 5) {
                                Button {
                                    let nextPaused = VideoPlaybackPool.shared.togglePaused(
                                        path: source.path, sessionID: session)
                                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                        immediatePauseKey = sessionKey
                                        immediatePaused = nextPaused
                                    }
                                } label: {
                                    Image(systemName: paused ? "play.fill" : "pause.fill")
                                        .contentTransition(.symbolEffect(.replace))
                                }
                                .buttonStyle(VideoTransportActionStyle())
                                .help("Play or pause the live video")

                                Text(Self.timecode(scrubbing ? scrubPreview : status?.elapsed))
                                    .frame(minWidth: 34, alignment: .trailing)
                                Slider(value: Binding(
                                    get: {
                                        let value = scrubbing ? scrubPreview : (status?.elapsed ?? 0)
                                        return min(max(0, value), max(1.0, status?.duration ?? 1.0))
                                    },
                                    set: { scrubPreview = $0 }
                                ), in: 0...max(1.0, status?.duration ?? 1.0), onEditingChanged: { editing in
                                    if editing {
                                        scrubPreview = status?.elapsed ?? 0
                                        scrubbing = true
                                    } else {
                                        VideoPlaybackPool.shared.seek(to: scrubPreview,
                                                                      path: source.path, sessionID: session)
                                        scrubbing = false
                                    }
                                })
                                .tint(.cyan)
                                .disabled(status == nil || (status?.duration ?? 0) <= 0.1)
                                .accessibilityLabel("Program video playback position")
                                Text(Self.timecode(status?.duration.map {
                                    max(0, $0 - (scrubbing ? scrubPreview : (status?.elapsed ?? 0)))
                                }))
                                    .frame(minWidth: 34, alignment: .leading)
                            }
                            .font(.system(size: 9, design: .monospaced))

                        } else {
                            HStack(spacing: 9) {
                                Button {
                                    // Change the UI instantly, with an icon morph.
                                    // The pool continues to control both video decoders
                                    // and their audio, using one explicit pause intent.
                                    let nextPaused = VideoPlaybackPool.shared.togglePaused(
                                        path: source.path, sessionID: session)
                                    withAnimation(reduceMotion ? nil :
                                        .spring(response: 0.28, dampingFraction: 0.66)) {
                                        immediatePauseKey = sessionKey
                                        immediatePaused = nextPaused
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: paused ? "play.fill" : "pause.fill")
                                            .contentTransition(.symbolEffect(.replace))
                                        Text(paused ? "Play" : "Pause")
                                            .contentTransition(.opacity)
                                    }
                                    .frame(minWidth: compact ? 56 : 64)
                                }
                                .buttonStyle(VideoTransportActionStyle())
                                .help("Play or pause the active Program video and its soundtrack")

                                Spacer(minLength: 2)
                                Text("Elapsed " + Self.timecode(scrubbing ? scrubPreview : status?.elapsed))
                                Spacer(minLength: 2)
                                Text("Left −" + Self.timecode(
                                    status?.duration.map { max(0, $0 - (scrubbing ? scrubPreview : (status?.elapsed ?? 0))) }
                                ))
                            }
                            .font(.system(size: compact ? 10 : 11, design: .monospaced))

                            Slider(value: Binding(
                                get: {
                                    let value = scrubbing ? scrubPreview : (status?.elapsed ?? 0)
                                    return min(max(0, value), max(1.0, status?.duration ?? 1.0))
                                },
                                set: { scrubPreview = $0 }
                            ), in: 0...max(1.0, status?.duration ?? 1.0), onEditingChanged: { editing in
                                if editing {
                                    scrubPreview = status?.elapsed ?? 0
                                    scrubbing = true
                                } else {
                                    VideoPlaybackPool.shared.seek(to: scrubPreview,
                                                                  path: source.path, sessionID: session)
                                    scrubbing = false
                                }
                            })
                            .tint(.cyan)
                            .disabled(status == nil || (status?.duration ?? 0) <= 0.1)
                            .accessibilityLabel("Program video playback position")
                            .help("Drag to seek the live video. The new position is applied when released.")
                        }
                    }
                    .padding(.horizontal, compact ? 6 : 10)
                    .padding(.vertical, compact ? 3 : 7)
                    .background(
                        LinearGradient(colors: [Color.accentColor.opacity(0.11),
                                                Color.gray.opacity(0.07)],
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1))
                    .shadow(color: .black.opacity(0.10), radius: 7, y: 3)
                    // No insert/remove transition when Program changes clips.
                }
            }
        }
        // Only direct transport actions animate (e.g. play/pause button).
    }

    private static func timecode(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
                         : String(format: "%02d:%02d", minutes, remainder)
    }
}

/// A noninteractive, background-only view that observes mouse-down events in
/// the containing window. Clicking outside its text editor drops focus without
/// consuming the event, so the clicked slide/button still works normally.
/// The local event monitor is removed when SwiftUI dismantles this view.
@MainActor
private struct NotesClickAwayObserver: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOutsideClick: onOutsideClick)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.onOutsideClick = onOutsideClick
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        weak var hostView: NSView?
        var onOutsideClick: () -> Void
        private var mouseMonitor: Any?

        init(onOutsideClick: @escaping () -> Void) {
            self.onOutsideClick = onOutsideClick
        }

        func startMonitoring() {
            guard mouseMonitor == nil else { return }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self,
                      let hostView = self.hostView,
                      let window = hostView.window,
                      event.window === window else { return event }
                let location = hostView.convert(event.locationInWindow, from: nil)
                if !hostView.bounds.contains(location) {
                    self.onOutsideClick()
                }
                return event
            }
        }

        func stopMonitoring() {
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
        }

    }
}
