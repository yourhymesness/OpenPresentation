import SwiftUI

enum OperationMode: String, CaseIterable, Identifiable {
    case blind = "Blind"
    case live = "Live"
    var id: String { rawValue }
}

/// Slide takes, Clear Slide, and Blackout all follow the selected transition.
enum SlideTransitionStyle: String, CaseIterable, Identifiable {
    case cut = "Cut"
    case dissolve = "Dissolve"
    case fadeThroughBlack = "Fade Through Black"
    var id: String { rawValue }
}

/// Immutable rendered snapshots; edit changes never leak into live transitions.
struct ProgramFrame {
    let slide: PresentationSlide?
    let isBlackout: Bool
    let isCleared: Bool
    let videoSessions: [String: UUID]
}

/// All output surfaces use the same absolute start time for consistent animation.
struct ProgramTransition: Identifiable {
    let id = UUID()
    let from: ProgramFrame
    let to: ProgramFrame
    let style: SlideTransitionStyle
    let startedAt: Date
    let duration: TimeInterval

    func progress(at date: Date) -> Double {
        min(1.0, max(0.0, date.timeIntervalSince(startedAt) / max(duration, 0.001)))
    }

    /// Layer opacity for the outgoing and incoming frames respectively.
    func opacities(at date: Date) -> (outgoing: Double, incoming: Double) {
        let p = progress(at: date)
        switch style {
        case .cut:
            return (0, 1)
        case .dissolve:
            // Fade old foreground away as new foreground appears. Keeping
            // outgoing at 100% until the very end leaves stale text visible
            // behind transparent slides, then makes it disappear abruptly.
            return (1 - p, p)
        case .fadeThroughBlack:
            return (max(0, 1 - 2 * p), max(0, 2 * p - 1))
        }
    }
}

/// Global master gain, intentionally separate from each slide's cue mix.
/// Editing the upcoming slide can never change the outgoing Program level.
final class LiveAudioMix: ObservableObject {
    static let shared = LiveAudioMix()
    @Published var master: Double {
        didSet { UserDefaults.standard.set(master, forKey: "masterAudioGain") }
    }
    @Published var masterMuted: Bool {
        didSet { UserDefaults.standard.set(masterMuted, forKey: "masterAudioMuted") }
    }
    private init() {
        master = UserDefaults.standard.object(forKey: "masterAudioGain") as? Double ?? 1
        masterMuted = UserDefaults.standard.bool(forKey: "masterAudioMuted")
    }
    var effectiveProgramGain: Double {
        masterMuted ? 0 : min(1, max(0, master))
    }
}

/// Preview changes never mutate the on-air snapshot. In Blind mode, even
/// keyboard next/previous navigates Preview without advancing Program.
@MainActor
final class ShowController: ObservableObject {
    @Published var title: String = "Untitled Show"
    /// Distinguishes recovery drafts even for shows not yet saved to a URL.
    @Published private(set) var documentSessionID = UUID()
    @Published private(set) var canvasSize: ShowCanvasSize = .fullHD
    @Published private(set) var openedShowURL: URL?

    var openedShowFilename: String? { openedShowURL?.lastPathComponent }
    @Published var slides: [PresentationSlide] = []
    @Published var collections: [SlideCollection] = []
    /// Nil shows the entire library. Filters do not affect Program until a take.
    @Published var selectedCollectionID: UUID? = nil
    @Published var loopAutoAdvance = false
    @Published var globalAutoAdvanceSeconds: Double = 10
    @Published var autoAdvanceEnabled = false
    private var scheduledAdvance: DispatchWorkItem?
    /// Stable cue timeline for the operator Auto button (never affects output animation).
    @Published private(set) var autoAdvanceStart: Date?
    @Published private(set) var autoAdvanceDeadline: Date?
    /// Identifies an automatic take so the outgoing Auto fill can fade out
    /// over the exact slide transition; manual takes don't trigger it.
    @Published private(set) var autoTriggeredTransitionID: UUID?

    var visibleSlides: [PresentationSlide] {
        guard let selectedCollectionID else { return slides }
        return slides.filter { $0.collectionID == selectedCollectionID }
    }

    func addCollection(named name: String = "New Collection") {
        let item = SlideCollection(name: name)
        collections.append(item)
        selectedCollectionID = item.id
        selectedSlideID = visibleSlides.first?.id
    }

    func renameCollection(_ id: UUID, to name: String) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].name = name
    }

    func deleteCollection(_ id: UUID) {
        collections.removeAll(where: { $0.id == id })
        for index in slides.indices where slides[index].collectionID == id {
            slides[index].collectionID = nil
        }
        if selectedCollectionID == id { selectedCollectionID = nil }
    }

    func assignSlide(_ slideID: UUID, to collectionID: UUID?) {
        guard collectionID == nil || collections.contains(where: { $0.id == collectionID }),
              let index = slides.firstIndex(where: { $0.id == slideID }) else { return }
        slides[index].collectionID = collectionID
    }

    func selectCollection(_ id: UUID?) {
        selectedCollectionID = id
        if !visibleSlides.contains(where: { $0.id == selectedSlideID }) {
            selectedSlideID = visibleSlides.first?.id
        }
    }

    private func cancelAutoAdvance() {
        scheduledAdvance?.cancel()
        scheduledAdvance = nil
        autoAdvanceStart = nil
        autoAdvanceDeadline = nil
    }

    private func scheduleAutoAdvance(for slide: PresentationSlide) {
        cancelAutoAdvance()
        // Auto is a transport mode, not a per-slide checkbox. A slide with
        // no custom dwell inherits a safe 10-second default, so advancing
        // cannot silently stop the sequence.
        guard autoAdvanceEnabled else { return }
        let duration = min(3600, max(0.5, slide.autoAdvanceSeconds ?? globalAutoAdvanceSeconds))
        let expected = slide.id
        let action = DispatchWorkItem { [weak self] in
            guard let self, self.autoAdvanceEnabled,
                  self.liveSlideID == expected, !self.isCleared, !self.isBlackout else { return }
            let sequence = self.programSequence
            guard let current = sequence.firstIndex(where: { $0.id == expected }) else { return }
            if current + 1 < sequence.count {
                self.takeSnapshotLive(sequence[current + 1], triggeredByAuto: true)
            } else if self.loopAutoAdvance, let first = sequence.first {
                self.takeSnapshotLive(first, triggeredByAuto: true)
            }
        }
        scheduledAdvance = action
        // Dwell begins after the destination slide's transition completes.
        let transitionLead = transitionStyle == .cut ? 0 : effectiveTransitionDuration(for: slide)
        let now = Date()
        autoAdvanceStart = now.addingTimeInterval(transitionLead)
        autoAdvanceDeadline = autoAdvanceStart?.addingTimeInterval(duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + transitionLead, execute: action)
    }

    func refreshAutoAdvance() {
        // Timing settings are operator metadata, not frozen visual Program pixels.
        if let id = liveSlideID,
           let published = programSequence.first(where: { $0.id == id }) ?? liveSlideSnapshot {
            scheduleAutoAdvance(for: published)
        } else { cancelAutoAdvance() }
    }

    @Published var selectedSlideID: UUID?
    @Published var mode: OperationMode = .blind {
        didSet {
            guard mode != oldValue else { return }
            if mode == .blind {
                captureBlindProgramBaseline()
            } else {
                // Publish staged edits for future takes only. Do not mutate
                // the immutable slide already on the audience display.
                blindPublishedSlides = nil
                blindProgramSequenceIDs = nil
            }
        }
    }
    /// While Blind is active, Program navigation and Auto operate on the
    /// last published library, never on edits still being made in Blind.
    /// The editing library itself stays fully editable and is what gets saved.
    private var blindPublishedSlides: [UUID: PresentationSlide]? = nil
    private var blindProgramSequenceIDs: [UUID]? = nil

    private func captureBlindProgramBaseline() {
        blindPublishedSlides = Dictionary(uniqueKeysWithValues: slides.map { ($0.id, $0) })
        blindProgramSequenceIDs = visibleSlides.map(\.id)
    }

    private var programSequence: [PresentationSlide] {
        if mode == .blind, let frozen = blindPublishedSlides,
           let ids = blindProgramSequenceIDs {
            return ids.compactMap { frozen[$0] }
        }
        return visibleSlides
    }
    @Published private(set) var liveSlideID: UUID?
    @Published private(set) var liveSlideSnapshot: PresentationSlide?
    @Published private(set) var liveVideoSessions: [String: UUID] = [:]
    @Published private(set) var isBlackout = false
    @Published private(set) var isCleared = false
    @Published var transitionStyle: SlideTransitionStyle = .dissolve
    /// Global show default, with destination-slide overrides as needed.
    @Published var transitionDuration: Double = 0.65

    func effectiveTransitionDuration(for slide: PresentationSlide?) -> Double {
        let value = slide?.transitionSecondsOverride ?? transitionDuration
        return value.isFinite ? min(max(value, 0.05), 30) : 0.65
    }

    var nextQueuedSlide: PresentationSlide? {
        let sequence = programSequence
        guard !sequence.isEmpty else { return nil }
        guard let id = liveSlideID,
              let index = sequence.firstIndex(where: { $0.id == id }) else { return sequence.first }
        if index + 1 < sequence.count { return sequence[index + 1] }
        return loopAutoAdvance ? sequence.first : nil
    }

    func setSlideAudioGain(_ slideID: UUID, to gain: Double) {
        guard let index = slides.firstIndex(where: { $0.id == slideID }) else { return }
        slides[index].cueAudioGain = gain.isFinite ? min(max(gain, 0), 1) : 1
        // Blind editing must not alter the audible Program snapshot.
        if mode == .live && liveSlideID == slideID {
            liveSlideSnapshot?.cueAudioGain = slides[index].cueAudioGain
        }
    }

    func setSlideAudioMuted(_ slideID: UUID, to muted: Bool) {
        guard let index = slides.firstIndex(where: { $0.id == slideID }) else { return }
        slides[index].cueAudioMuted = muted
        if mode == .live && liveSlideID == slideID { liveSlideSnapshot?.cueAudioMuted = muted }
    }

    func setSlideTransitionOverride(_ slideID: UUID, seconds: Double?) {
        guard let index = slides.firstIndex(where: { $0.id == slideID }) else { return }
        slides[index].transitionSecondsOverride = seconds.map { min(max($0, 0.05), 30) }
    }
    @Published private(set) var activeTransition: ProgramTransition?
    @Published var statusMessage = "BLIND: Changes remain off-air. Switch to Live before sending a slide."


    /// Bounded, document-local history for operator changes in Blind mode.
    /// Keeping this independent from the current AppKit first responder lets
    /// a pasted image/layer be undone after selection/focus changes.
    private struct EditCheckpoint {
        let slides: [PresentationSlide]
        let selectedSlideID: UUID?
        let actionName: String
    }
    @Published private var undoHistory: [EditCheckpoint] = []
    @Published private var redoHistory: [EditCheckpoint] = []
    var canUndoSlideEdit: Bool { !undoHistory.isEmpty }
    var canRedoSlideEdit: Bool { !redoHistory.isEmpty }

    private func pushCheckpoint(_ priorSlides: [PresentationSlide],
                                priorSelectedID: UUID?, name: String) {
        undoHistory.append(EditCheckpoint(slides: priorSlides,
                                          selectedSlideID: priorSelectedID,
                                          actionName: name))
        if undoHistory.count > 40 { undoHistory.removeFirst() }
        redoHistory.removeAll()
    }

    /// Record one undo step after a successful layer paste or cut. The original
    /// slide is spliced into the prior document snapshot before checkpointing.
    func recordLayerChangeUndo(before original: PresentationSlide, name: String) {
        guard mode == .blind,
              let i = slides.firstIndex(where: { $0.id == original.id }),
              slides[i] != original else { return }
        var previous = slides
        previous[i] = original
        pushCheckpoint(previous, priorSelectedID: original.id, name: name)
    }

    private func checkpointBeforeSlideOperation(_ name: String) {
        pushCheckpoint(slides, priorSelectedID: selectedSlideID, name: name)
    }

    func undoSlideEdit() {
        guard mode == .blind, let entry = undoHistory.popLast() else { return }
        redoHistory.append(EditCheckpoint(slides: slides,
                                          selectedSlideID: selectedSlideID,
                                          actionName: entry.actionName))
        slides = entry.slides
        selectedSlideID = entry.selectedSlideID
        statusMessage = "BLIND: Undid \(entry.actionName). Program unchanged."
    }

    func redoSlideEdit() {
        guard mode == .blind, let entry = redoHistory.popLast() else { return }
        undoHistory.append(EditCheckpoint(slides: slides,
                                          selectedSlideID: selectedSlideID,
                                          actionName: entry.actionName))
        slides = entry.slides
        selectedSlideID = entry.selectedSlideID
        statusMessage = "BLIND: Redid \(entry.actionName). Program unchanged."
    }

    /// Deep-copy slide identity and layer/group identifiers without changing
    /// media bytes, positioning, or authored options.
    func insertCopiedSlide(_ source: PresentationSlide, after slideID: UUID?) {
        guard mode == .blind else { return }
        checkpointBeforeSlideOperation("Paste Slide")
        var pasted = source.duplicatedForLibrary()
        pasted.slideTitle = source.slideTitle.isEmpty ? "Copied Slide" : source.slideTitle + " Copy"
        if let slideID, let index = slides.firstIndex(where: { $0.id == slideID }) {
            slides.insert(pasted, at: index + 1)
        } else {
            slides.append(pasted)
        }
        selectedSlideID = pasted.id
        statusMessage = "BLIND: Slide pasted. Program unchanged."
    }

    func duplicateSlide(_ slideID: UUID) {
        guard let source = slides.first(where: { $0.id == slideID }) else { return }
        insertCopiedSlide(source, after: slideID)
    }

    func deleteSlide(_ slideID: UUID) {
        guard mode == .blind, let i = slides.firstIndex(where: { $0.id == slideID }) else { return }
        checkpointBeforeSlideOperation("Delete Slide")
        let wasLive = slideID == liveSlideID
        slides.remove(at: i)
        if selectedSlideID == slideID {
            selectedSlideID = slides.isEmpty ? nil : slides[min(i, slides.count - 1)].id
        }
        statusMessage = wasLive ? "BLIND: Slide deleted; live Program snapshot held." : "BLIND: Slide deleted."
    }

    init() {
        selectedSlideID = slides.first?.id
        recordSavedBaseline()
    }

    var previewSlide: PresentationSlide? {
        slides.first(where: { $0.id == selectedSlideID })
    }

    var liveSlide: PresentationSlide? { liveSlideSnapshot }

    func select(_ slide: PresentationSlide) {
        selectedSlideID = slide.id
    }

    /// Immediately takes a specific slide to Program in Live mode only.
    /// The on-air snapshot remains isolated from subsequent edits.
    func takeLive(_ slide: PresentationSlide) {
        guard mode == .live else {
            statusMessage = "BLIND: Program unchanged. Switch to Live to take a slide."
            return
        }
        // Resolve from the current library, avoiding stale UI snapshots.
        guard let current = slides.first(where: { $0.id == slide.id }) else { return }
        // Re-taking an unchanged cue is a no-op, but a staged edit of that
        // SAME slide must go through the normal Program transition. Never
        // replace the old on-air snapshot before the dissolve begins.
        if liveSlideID == current.id && !isBlackout && !isCleared,
           let prior = liveSlideSnapshot,
           current.preparedForProgram(after: prior).hasSameProgramContent(as: prior) {
            statusMessage = "LIVE: \(current.displayTitle) already on Program."
            return
        }
        takeSnapshotLive(current)
    }

    func goLive() {
        guard mode == .live else {
            statusMessage = "BLIND: No slide sent. Switch to Live to take Preview to Program."
            return
        }
        guard let selected = previewSlide else { return }
        takeLive(selected)
    }

    /// Navigate within the current playback sequence. Loop Collection is a
    /// transport behavior for manual buttons as well as timed Auto playback.
    private func programDestination(in sequence: [PresentationSlide], offset: Int) -> PresentationSlide? {
        guard !sequence.isEmpty else { return nil }
        let current = sequence.firstIndex(where: { $0.id == liveSlideID })
            ?? (offset > 0 ? -1 : sequence.count)
        let requested = current + offset
        if sequence.indices.contains(requested) { return sequence[requested] }
        guard loopAutoAdvance else { return nil }
        let wrapped = ((requested % sequence.count) + sequence.count) % sequence.count
        return sequence[wrapped]
    }

    func advance(by offset: Int) {
        guard !slides.isEmpty else { return }
        if mode == .blind {
            let sequence = visibleSlides
            let current = sequence.firstIndex(where: { $0.id == selectedSlideID }) ?? 0
            let destination = current + offset
            guard sequence.indices.contains(destination) else { return }
            selectedSlideID = sequence[destination].id
            statusMessage = "BLIND: Preview moved to slide \(destination + 1); Program unchanged."
            return
        }

        guard let destination = programDestination(in: programSequence, offset: offset) else { return }
        takeSnapshotLive(destination)
    }

    /// Intentional Program navigation from the gray on-air panel in Blind.
    /// Unlike advance(by:), this takes a slide to Program and never changes
    /// the slide currently selected for editing.
    func advanceProgram(by offset: Int) {
        guard let destination = programDestination(in: programSequence, offset: offset) else { return }
        takeSnapshotLive(destination)
    }

    private var currentProgramFrame: ProgramFrame {
        ProgramFrame(slide: liveSlideSnapshot, isBlackout: isBlackout,
                     isCleared: isCleared, videoSessions: liveVideoSessions)
    }

    private func beginProgramTransition(from old: ProgramFrame, to next: ProgramFrame,
                                        destination: PresentationSlide? = nil) {
        activeTransition = nil
        autoTriggeredTransitionID = nil
        // A transition from a blank idle Program need not animate, but
        // clearing an already-live slide does honor the selected effect.
        let duration = effectiveTransitionDuration(for: destination)
        guard transitionStyle != .cut, duration > 0 else { return }
        let effect = ProgramTransition(from: old, to: next, style: transitionStyle,
                                       startedAt: Date(), duration: duration)
        activeTransition = effect
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.12) { [weak self] in
            guard let self, self.activeTransition?.id == effect.id else { return }
            self.activeTransition = nil
        }
    }

    func toggleBlackout() {
        let before = currentProgramFrame
        isBlackout.toggle()
        if isBlackout { cancelAutoAdvance() }
        else if let liveSlideSnapshot { scheduleAutoAdvance(for: liveSlideSnapshot) }
        beginProgramTransition(from: before, to: currentProgramFrame)
        statusMessage = isBlackout ? "BLACKOUT enabled (transitioned)." : "Blackout disabled (transitioned)."
    }

    /// Escape is an emergency Clear command, never a toggle/restore.
    func clearSlide() {
        guard !isCleared else { return }
        toggleClear()
    }

    func toggleClear() {
        let before = currentProgramFrame
        isCleared.toggle()
        if isCleared { cancelAutoAdvance() }
        else if let liveSlideSnapshot { scheduleAutoAdvance(for: liveSlideSnapshot) }
        if isCleared {
            // Keep the outgoing session in the frozen transition frame only:
            // audio can fade naturally, then its player detaches.
            liveVideoSessions = [:]
            statusMessage = "Program slide cleared with transition."
        } else {
            liveVideoSessions = liveSlideSnapshot.map {
                VideoTakePlanner.sessions(for: $0, previous: [:])
            } ?? [:]
            statusMessage = "Program slide restored with transition."
        }
        beginProgramTransition(from: before, to: currentProgramFrame)
    }

    /// Called only from intentional Live-mode slide actions.
    private func takeSnapshotLive(_ newSlide: PresentationSlide, triggeredByAuto: Bool = false) {
        // Resolve transparent backgrounds BEFORE comparing the old/new cue.
        // That allows a changed same-slide retake to fade from its immutable
        // on-air snapshot, while an unchanged loop remains seamless.
        let programSlide = newSlide.preparedForProgram(after: liveSlideSnapshot)
        let sameSlideRetake = liveSlideID == newSlide.id && !isBlackout && !isCleared
        if sameSlideRetake, let prior = liveSlideSnapshot,
           programSlide.hasSameProgramContent(as: prior) {
            scheduleAutoAdvance(for: newSlide)
            statusMessage = "LIVE: \(newSlide.displayTitle) already on Program."
            return
        }
        var newSessions = VideoTakePlanner.sessions(for: programSlide, previous: liveVideoSessions)
        if sameSlideRetake {
            // Text/shape edits must not restart an unchanged video or its
            // audio. A replaced media file already has a new canonical path.
            for path in newSessions.keys {
                if let oldSession = liveVideoSessions[path] {
                    newSessions[path] = oldSession
                }
            }
        }
        let outgoing = ProgramFrame(slide: liveSlideSnapshot, isBlackout: isBlackout,
                                    isCleared: isCleared, videoSessions: liveVideoSessions)
        let incoming = ProgramFrame(slide: programSlide, isBlackout: false,
                                    isCleared: false, videoSessions: newSessions)
        activeTransition = nil // A fresh take supersedes an unfinished transition.
        liveSlideID = newSlide.id
        liveSlideSnapshot = programSlide
        liveVideoSessions = newSessions
        // Auto or Program navigation can occur while the operator edits a
        // different slide in Blind mode. Never hijack that edit selection.
        if mode == .live { selectedSlideID = newSlide.id }
        isBlackout = false
        isCleared = false
        scheduleAutoAdvance(for: newSlide)

        // First take cuts from idle. Subsequent takes use the chosen effect.
        if outgoing.slide != nil {
            beginProgramTransition(from: outgoing, to: incoming, destination: newSlide)
            if triggeredByAuto { autoTriggeredTransitionID = activeTransition?.id }
        }
        let number = (slides.firstIndex(where: { $0.id == newSlide.id }) ?? 0) + 1
        statusMessage = "LIVE: slide \(number) of \(slides.count) · \(transitionStyle.rawValue)."
    }

    func updateSlide(_ updated: PresentationSlide) {
        guard let index = slides.firstIndex(where: { $0.id == updated.id }) else { return }
        slides[index] = updated
    }

    func addSlide() {
        let slide = PresentationSlide(text: "")
        var assigned = slide
        assigned.collectionID = selectedCollectionID
        slides.append(assigned)
        selectedSlideID = assigned.id
        statusMessage = "New slide added to Preview."
    }

    func deleteSelectedSlide() {
        guard let selectedSlideID,
              let index = slides.firstIndex(where: { $0.id == selectedSlideID }) else { return }
        let wasLive = selectedSlideID == liveSlideID
        slides.remove(at: index)
        self.selectedSlideID = slides.isEmpty ? nil : slides[min(index, slides.count - 1)].id
        statusMessage = wasLive ? "Slide deleted from library; Program snapshot held." : "Slide removed."
    }

    func moveSelectedSlide(by offset: Int) {
        guard let selectedSlideID,
              let index = slides.firstIndex(where: { $0.id == selectedSlideID }) else { return }
        let destination = index + offset
        guard slides.indices.contains(destination) else { return }
        slides.swapAt(index, destination)
    }

    func currentShow() -> PresentationShow {
        PresentationShow(title: title, slides: slides, canvasSize: canvasSize,
                         collections: collections, loopAutoAdvance: loopAutoAdvance,
                         globalTransitionSeconds: transitionDuration,
                         globalAutoAdvanceSeconds: globalAutoAdvanceSeconds)
    }

    /// Called only after a successful save; do not update the document label
    /// if saving fails or the user cancels the save panel.
    func didSaveShow(to url: URL, withTitle savedTitle: String) {
        openedShowURL = url
        title = savedTitle
        recordSavedBaseline()
    }

    func load(_ show: PresentationShow, from url: URL? = nil) {
        undoHistory.removeAll()
        redoHistory.removeAll()
        let storedTitle = show.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Older files may have no title metadata. Prefer a meaningful saved
        // title, then fall back to the filename without the extension.
        title = storedTitle.isEmpty
            ? (url?.deletingPathExtension().lastPathComponent ?? "Untitled Show")
            : storedTitle
        openedShowURL = url
        documentSessionID = UUID()
        slides = show.slides
        canvasSize = show.canvasSize
        collections = show.collections
        loopAutoAdvance = show.loopAutoAdvance
        globalAutoAdvanceSeconds = show.globalAutoAdvanceSeconds
        transitionDuration = show.globalTransitionSeconds
        autoAdvanceEnabled = false
        cancelAutoAdvance()
        selectedCollectionID = nil
        selectedSlideID = slides.first?.id
        if mode == .blind { captureBlindProgramBaseline() }
        liveSlideID = nil
        liveSlideSnapshot = nil
        liveVideoSessions = [:]
        activeTransition = nil
        // Preserve the operator's current Live/Blind mode while opening another show.
        isBlackout = false
        isCleared = false
        statusMessage = "Show loaded. Program idle; operator mode preserved."
        recordSavedBaseline()
    }

    /// Restore a draft without declaring it saved. Undo/Redo history starts
    /// fresh; the recovered slide library remains off-air until explicitly taken.
    func restoreRecoveredShow(_ snapshot: RecoverySnapshot) {
        load(snapshot.show, from: snapshot.originalURL)
        documentSessionID = snapshot.documentID
        savedBaseline = nil
        statusMessage = "Recovered unsaved changes. Review them and Save or Save As."
    }

    // Compare encoded show content, not window/mode/transport state. Changes in
    // title, slide objects, collections or timing all count as unsaved edits.
    private var savedBaseline: Data?
    var hasUnsavedChanges: Bool {
        guard let data = encodedShowData() else { return true }
        return data != savedBaseline
    }
    private func encodedShowData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(currentShow())
    }
    private func recordSavedBaseline() {
        savedBaseline = encodedShowData()
    }
    func newBlankShow(canvasSize: ShowCanvasSize = .fullHD, title: String = "Untitled Show") {
        undoHistory.removeAll()
        redoHistory.removeAll()
        cancelAutoAdvance()
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Show" : title
        self.canvasSize = canvasSize
        openedShowURL = nil
        documentSessionID = UUID()
        slides = []
        collections = []
        selectedCollectionID = nil
        selectedSlideID = nil
        liveSlideID = nil
        liveSlideSnapshot = nil
        liveVideoSessions = [:]
        activeTransition = nil
        isBlackout = false
        isCleared = false
        loopAutoAdvance = false
        autoAdvanceEnabled = false
        globalAutoAdvanceSeconds = 10
        transitionDuration = 0.65
        if mode == .blind { captureBlindProgramBaseline() }
        statusMessage = "Blank \(canvasSize.sizeLabel) show ready. Add a slide to begin."
        recordSavedBaseline()
    }

}
