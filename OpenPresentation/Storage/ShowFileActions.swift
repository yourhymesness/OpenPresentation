import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Native File menu commands for a lightweight non-NSDocument show editor.
/// The opened URL is the authoritative save destination until Save As changes it.
@MainActor
final class ShowFileActions: ObservableObject {
    @Published var errorMessage: String?
    /// Wired by the owning application session; avoids persisting dismissed work.
    var onSuccessfulSave: (() -> Void)?
    var onWillReplaceShow: (() -> Void)?
    @Published private(set) var recentShows: [URL] = []
    private let recentKey = "OpenPresentation.recentShows.v1"
    private let recentLimit = 12

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        recentShows = stored.map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        persistRecent()
    }

    func openShow(into show: ShowController) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openShow(at: url, into: show)
    }

    func openShow(at url: URL, into show: ShowController) {
        guard confirmMayReplaceCurrentShow(show) else { return }
        do {
            let document = try ProjectStore.load(from: url)
            onWillReplaceShow?()
            show.load(document, from: url)
            noteRecent(url)
            show.statusMessage = "Opened \(url.lastPathComponent)."
        } catch {
            errorMessage = "Could not open show: \(error.localizedDescription)"
            if !FileManager.default.fileExists(atPath: url.path) {
                recentShows.removeAll(where: { $0 == url.standardizedFileURL })
                persistRecent()
            }
        }
    }

    /// ⌘S saves directly to the existing show. A new show prompts for a name.
    @discardableResult func saveShow(from show: ShowController) -> Bool {
        guard let url = show.openedShowURL else {
            return saveShowAs(from: show)
        }
        return writeShow(from: show, to: url)
    }

    /// ⇧⌘S always offers a new destination, retaining the original if cancelled.
    @discardableResult func saveShowAs(from show: ShowController) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let title = show.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggested = show.openedShowURL?.deletingPathExtension().lastPathComponent
            ?? (title.isEmpty ? "Untitled Show" : title.replacingOccurrences(of: "/", with: "-"))
        panel.nameFieldStringValue = suggested + ".json"
        if let currentFolder = show.openedShowURL?.deletingLastPathComponent() {
            panel.directoryURL = currentFolder
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return writeShow(from: show, to: url)
    }


    /// Used before replacing an edited show with another file or a blank show.
    func confirmMayReplaceCurrentShow(_ show: ShowController) -> Bool {
        guard show.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(show.title)?"
        alert.informativeText = "The current show contains unsaved changes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveShow(from: show)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func clearRecent() {
        recentShows = []
        persistRecent()
    }

    @discardableResult private func writeShow(from show: ShowController, to url: URL) -> Bool {
        do {
            let enteredTitle = show.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let savedTitle = enteredTitle.isEmpty ? url.deletingPathExtension().lastPathComponent : enteredTitle
            var document = show.currentShow()
            document.title = savedTitle
            try ProjectStore.save(document, to: url)
            show.didSaveShow(to: url, withTitle: savedTitle)
            onSuccessfulSave?()
            noteRecent(url)
            show.statusMessage = "Saved \(savedTitle) to \(url.lastPathComponent)."
            return true
        } catch {
            errorMessage = "Could not save show: \(error.localizedDescription)"
            return false
        }
    }

    private func noteRecent(_ url: URL) {
        let normalized = url.standardizedFileURL
        recentShows.removeAll(where: { $0 == normalized })
        recentShows.insert(normalized, at: 0)
        if recentShows.count > recentLimit { recentShows = Array(recentShows.prefix(recentLimit)) }
        persistRecent()
        NSDocumentController.shared.noteNewRecentDocumentURL(normalized)
    }

    private func persistRecent() {
        UserDefaults.standard.set(recentShows.map(\.path), forKey: recentKey)
    }
}
