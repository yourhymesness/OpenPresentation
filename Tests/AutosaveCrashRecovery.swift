import Foundation

@main struct AutosaveCrashRecoveryTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("openpresentation-recovery-test-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let store = RecoverySnapshotStore(directory: root.appendingPathComponent("Recovery"))
        let startingSnapshots = try store.recoverableSnapshots()
        assert(startingSnapshots.isEmpty)
        let id = UUID()
        let savedShow = PresentationShow(title: "Original", slides: [PresentationSlide(text: "Saved")],
                                         canvasSize: ShowCanvasSize(width: 1080, height: 1920))
        let savedURL = root.appendingPathComponent("Original.json")
        let savedBytes = try JSONEncoder().encode(savedShow)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try savedBytes.write(to: savedURL)

        let draft = PresentationShow(title: "Edited, but not saved", slides: [PresentationSlide(text: "Recovered!")],
                                     canvasSize: ShowCanvasSize(width: 1080, height: 1920))
        let d1 = RecoverySnapshot(documentID: id, capturedAt: Date(timeIntervalSince1970: 100),
                                  originalURL: savedURL, show: draft)
        try store.save(d1)
        var latest = try store.recoverableSnapshots()
        assert(latest.count == 1)
        assert(latest[0].show.slides[0].layers[0].text == "Recovered!")
        assert(latest[0].show.canvasSize.width == 1080)
        assert(latest[0].originalURL == savedURL)
        let untouchedOriginal = try Data(contentsOf: savedURL)
        assert(untouchedOriginal == savedBytes, "Autosave must not modify original")

        // Rotate three generations, preserve earlier snapshots if current is damaged.
        var versions = [d1]
        for n in 1...3 {
            let next = RecoverySnapshot(documentID: id,
                                        capturedAt: Date(timeIntervalSince1970: 100 + Double(n)),
                                        originalURL: savedURL,
                                        show: PresentationShow(title: "Edited #\(n)", slides: draft.slides))
            try store.save(next)
            versions.append(next)
        }
        latest = try store.recoverableSnapshots()
        assert(latest.count == 1 && latest[0].show.title == "Edited #3")
        // Corrupt current and confirm the previous generation still loads.
        let currentFile = store.directory.appendingPathComponent(id.uuidString + ".json")
        try Data("invalid json".utf8).write(to: currentFile)
        latest = try store.recoverableSnapshots()
        assert(latest.count == 1 && latest[0].show.title == "Edited #2")

        // A separate new, unsaved show has a different identity and is retained.
        let unsavedID = UUID()
        let unsaved = RecoverySnapshot(documentID: unsavedID, originalURL: nil,
                                       show: PresentationShow(title: "Not yet saved", slides: draft.slides))
        try store.save(unsaved)
        latest = try store.recoverableSnapshots()
        assert(latest.count == 2)
        assert(latest.contains(where: { $0.documentID == unsavedID && $0.originalURL == nil }))
        try store.discard(documentID: id)
        latest = try store.recoverableSnapshots()
        assert(latest.count == 1 && latest[0].documentID == unsavedID)
        let untouchedAfterRecovery = try Data(contentsOf: savedURL)
        assert(untouchedAfterRecovery == savedBytes)
        try store.discard(documentID: unsavedID)
        let endingSnapshots = try store.recoverableSnapshots()
        assert(endingSnapshots.isEmpty)
        print("Autosave and crash recovery tests passed")
    }
}
