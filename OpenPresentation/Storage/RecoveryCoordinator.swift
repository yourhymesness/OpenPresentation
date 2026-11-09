import AppKit
import SwiftUI

/// Keeps recovery on the main actor and outside the rendering/transport path.
/// An idle timer requests snapshots; no background threads touch the live show.
@MainActor
final class RecoveryCoordinator: ObservableObject {
    @Published private(set) var statusText = "Recovery ready"
    private weak var show: ShowController?
    private let store: RecoverySnapshotStore
    private var started = false
    private var lastEncodedShow: Data?
    private var lastDocumentID: UUID?

    init(show: ShowController, store: RecoverySnapshotStore = RecoverySnapshotStore()) {
        self.show = show
        self.store = store
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        lastDocumentID = show?.documentSessionID
        do {
            guard let snapshot = try store.recoverableSnapshots().first else { return }
            let date = DateFormatter.localizedString(from: snapshot.capturedAt,
                                                     dateStyle: .medium, timeStyle: .short)
            let alert = NSAlert()
            alert.messageText = "Recover an unsaved OpenPresentation show?"
            alert.informativeText = "A recovery snapshot of ‘\(snapshot.show.title)’ from \(date) was found. " +
                "Recover opens it as unsaved work; your original show file will not be overwritten. " +
                "Media files must remain at their original paths."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Recover")
            alert.addButton(withTitle: "Later")
            alert.addButton(withTitle: "Discard Recovery")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                show?.restoreRecoveredShow(snapshot)
                lastDocumentID = snapshot.documentID
                lastEncodedShow = try? JSONEncoder().encode(snapshot.show)
                statusText = "Recovered unsaved work · Save to keep"
            case .alertThirdButtonReturn:
                try store.discard(documentID: snapshot.documentID)
                statusText = "Recovery discarded"
            default:
                // Later deliberately leaves the snapshot for a future launch.
                statusText = "Recovery retained for later"
            }
        } catch {
            statusText = "Recovery unavailable · \(error.localizedDescription)"
        }
    }

    /// Called every five seconds by the operator window; unchanged drafts do
    /// not rewrite the disk and completed saves remove the active draft.
    func autosaveIfNeeded() {
        guard started, let show else { return }
        if lastDocumentID != show.documentSessionID {
            lastDocumentID = show.documentSessionID
            lastEncodedShow = nil
        }
        guard show.hasUnsavedChanges else {
            if lastEncodedShow != nil {
                discardCurrent()
                statusText = "All changes saved"
            }
            return
        }
        let document = show.currentShow()
        do {
            let bytes = try JSONEncoder().encode(document)
            guard lastEncodedShow != bytes else { return }
            let draft = RecoverySnapshot(documentID: show.documentSessionID,
                                         originalURL: show.openedShowURL, show: document)
            try store.save(draft)
            lastEncodedShow = bytes
            let time = DateFormatter.localizedString(from: draft.capturedAt,
                                                     dateStyle: .none, timeStyle: .short)
            statusText = "Recovery saved \(time)"
        } catch {
            // Do not pretend that an emergency backup succeeded when disk I/O
            // fails. Keep the last good copy untouched and retry next tick.
            statusText = "Recovery save failed · \(error.localizedDescription)"
        }
    }

    /// Successful normal Save and deliberate document replacement invalidate
    /// only this show's recovery drafts, not drafts left for later.
    func discardCurrent() {
        guard let show else { return }
        do {
            try store.discard(documentID: show.documentSessionID)
            lastEncodedShow = nil
        } catch {
            statusText = "Could not clear recovery · \(error.localizedDescription)"
        }
    }

    func didSave() {
        discardCurrent()
        statusText = "Saved · Recovery cleared"
    }

    func willReplaceShow() {
        discardCurrent()
        lastDocumentID = nil
        lastEncodedShow = nil
    }

    /// Only call once a normal Quit is actually approved. A Force Quit/crash
    /// bypasses this method, retaining the most recent recovery snapshot.
    func willTerminateNormally() { discardCurrent() }
}
