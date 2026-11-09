import Foundation

/// An emergency draft, not a replacement for the operator's saved .json show.
/// Media references remain external paths; duplicating multi-gigabyte media on
/// every edit would be unsafe for both storage and live video playback.
struct RecoverySnapshot: Codable {
    let schemaVersion: Int
    let documentID: UUID
    let capturedAt: Date
    let originalPath: String?
    let show: PresentationShow

    init(documentID: UUID, capturedAt: Date = Date(),
         originalURL: URL?, show: PresentationShow) {
        schemaVersion = 1
        self.documentID = documentID
        self.capturedAt = capturedAt
        originalPath = originalURL?.standardizedFileURL.path
        self.show = show
    }

    var originalURL: URL? { originalPath.map { URL(fileURLWithPath: $0) } }
}

/// Portable, Foundation-only storage so recovery can be tested without AppKit.
/// Each document has an atomic current file plus two older fallbacks. These
/// snapshots live in Application Support, never next to or inside the user's
/// original document. A damaged current snapshot can fall back to a backup.
struct RecoverySnapshotStore {
    let directory: URL
    private let fm = FileManager.default

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask)[0]
            self.directory = support.appendingPathComponent("OpenPresentation", isDirectory: true)
                .appendingPathComponent("Recovery", isDirectory: true)
        }
    }

    private func path(for id: UUID, generation: Int) -> URL {
        let suffix = generation == 0 ? "" : "-backup-\(generation)"
        return directory.appendingPathComponent(id.uuidString + suffix + ".json")
    }

    func save(_ snapshot: RecoverySnapshot) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(snapshot)
        let current = path(for: snapshot.documentID, generation: 0)
        let older = path(for: snapshot.documentID, generation: 2)
        let newer = path(for: snapshot.documentID, generation: 1)
        // Copy, rather than move, the latest good snapshot before overwriting
        // it. Failure to rotate never destroys the current recovery copy.
        if fm.fileExists(atPath: newer.path) {
            if fm.fileExists(atPath: older.path) { try fm.removeItem(at: older) }
            try fm.copyItem(at: newer, to: older)
        }
        if fm.fileExists(atPath: current.path) {
            if fm.fileExists(atPath: newer.path) { try fm.removeItem(at: newer) }
            try fm.copyItem(at: current, to: newer)
        }
        try bytes.write(to: current, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
    }

    /// Return newest valid snapshot per document. Corrupt/incomplete files
    /// never block older backups from being recovered.
    func recoverableSnapshots() throws -> [RecoverySnapshot] {
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var latest: [UUID: RecoverySnapshot] = [:]
        let decoder = JSONDecoder()
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let draft = try? decoder.decode(RecoverySnapshot.self, from: data),
                  draft.schemaVersion == 1,
                  (1...6).contains(draft.show.formatVersion) else { continue }
            if let previous = latest[draft.documentID],
               previous.capturedAt >= draft.capturedAt { continue }
            latest[draft.documentID] = draft
        }
        return latest.values.sorted { $0.capturedAt > $1.capturedAt }
    }

    /// Removing one document's emergency drafts never discards unrelated shows.
    func discard(documentID: UUID) throws {
        for generation in 0...2 {
            let file = path(for: documentID, generation: generation)
            if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        }
    }
}
