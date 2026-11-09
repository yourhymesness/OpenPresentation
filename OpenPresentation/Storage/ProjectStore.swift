import Foundation

enum ProjectStore {
    enum StoreError: LocalizedError {
        case unsupportedVersion(Int)
        case missingVideo(String)
        case invalidVideoPath(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "This show uses format version \(version), which this prototype cannot open."
            case .missingVideo(let path):
                return "Cannot save: media file is missing at \(path). Relink or remove it."
            case .invalidVideoPath(let path):
                return "Invalid video filename in show: \(path)"
            }
        }
    }

    /// The companion directory is next to the JSON, e.g.
    /// "Sunday Show.json" + "Sunday Show.media". Keep them together.
    private static func mediaFolder(for showURL: URL) -> URL {
        showURL.deletingLastPathComponent()
            .appendingPathComponent(showURL.deletingPathExtension().lastPathComponent + ".media",
                                    isDirectory: true)
    }

    static func save(_ show: PresentationShow, to url: URL) throws {
        let fm = FileManager.default
        let folder = mediaFolder(for: url)
        var portable = show
        portable.formatVersion = 5
        var copies: [String: String] = [:]

        func packaged(_ path: String?) throws -> String? {
            guard let path, !path.isEmpty else { return nil }
            if let previous = copies[path] { return previous }
            let source = URL(fileURLWithPath: path).standardizedFileURL
            guard fm.fileExists(atPath: source.path) else { throw StoreError.missingVideo(path) }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let original = source.lastPathComponent
            let parent = source.deletingLastPathComponent().standardizedFileURL
            // A second save of an already packaged show reuses its video files.
            let filename = parent == folder.standardizedFileURL
                ? original
                : UUID().uuidString + "." + source.pathExtension.lowercased()
            let destination = folder.appendingPathComponent(filename)
            if source != destination.standardizedFileURL {
                try fm.copyItem(at: source, to: destination)
            }
            let reference = "media:" + filename
            copies[path] = reference
            return reference
        }

        for s in portable.slides.indices {
            portable.slides[s].backgroundVideoPath = try packaged(portable.slides[s].backgroundVideoPath)
            for l in portable.slides[s].layers.indices {
                portable.slides[s].layers[l].videoPath = try packaged(portable.slides[s].layers[l].videoPath)
                portable.slides[s].layers[l].audioPath = try packaged(portable.slides[s].layers[l].audioPath)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(portable)
        try data.write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> PresentationShow {
        let data = try Data(contentsOf: url)
        var show = try JSONDecoder().decode(PresentationShow.self, from: data)
        guard (1...5).contains(show.formatVersion) else { throw StoreError.unsupportedVersion(show.formatVersion) }
        let folder = mediaFolder(for: url)

        func resolved(_ path: String?) throws -> String? {
            guard let path, path.hasPrefix("media:") else { return path }
            let filename = String(path.dropFirst(6))
            // Never accept directory traversal in media references.
            guard !filename.isEmpty, filename == URL(fileURLWithPath: filename).lastPathComponent,
                  filename != ".", filename != ".." else {
                throw StoreError.invalidVideoPath(filename)
            }
            return folder.appendingPathComponent(filename).path
        }

        for s in show.slides.indices {
            show.slides[s].backgroundVideoPath = try resolved(show.slides[s].backgroundVideoPath)
            for l in show.slides[s].layers.indices {
                show.slides[s].layers[l].videoPath = try resolved(show.slides[s].layers[l].videoPath)
                show.slides[s].layers[l].audioPath = try resolved(show.slides[s].layers[l].audioPath)
            }
        }
        return show
    }
}
