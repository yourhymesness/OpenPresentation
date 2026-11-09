import Foundation

/// Imports to an application-owned staging directory. WebM is converted to a
/// QuickTime ProRes 4444 intermediate, retaining its alpha channel when FFmpeg
/// can decode one. WebM is not passed directly to AVFoundation.
enum MediaImporter {
    enum ImportError: LocalizedError {
        case unsupported(String)
        case ffmpegMissing
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let ext): return "Unsupported media type: .\(ext)"
            case .ffmpegMissing:
                return "WebM needs FFmpeg for conversion to an alpha-capable QuickTime movie. Install FFmpeg with Homebrew (brew install ffmpeg), then try again."
            case .conversionFailed(let detail):
                return "WebM conversion failed: \(detail)"
            }
        }
    }

    static func stageVideo(from url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let ext = url.pathExtension.lowercased()
            guard ["mp4", "mov", "m4v", "webm"].contains(ext) else {
                throw ImportError.unsupported(ext)
            }
            let folder = try stagingFolder()
            if ext == "webm" {
                let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
                    .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
                guard let ffmpeg else { throw ImportError.ffmpegMissing }
                let dest = folder.appendingPathComponent(UUID().uuidString + ".mov")
                // VP9's alpha plane is sometimes lost by FFmpeg's built-in
                // decoder. Prefer libvpx-vp9 first; retry automatic decoding
                // for VP8 or other WebM encodings.
                func attempt(forceVP9: Bool) throws {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: ffmpeg)
                    var args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"]
                    if forceVP9 { args += ["-c:v", "libvpx-vp9"] }
                    args += ["-i", url.path, "-map", "0:v:0", "-map", "0:a?",
                             "-c:v", "prores_ks", "-profile:v", "4",
                             "-pix_fmt", "yuva444p10le", "-c:a", "pcm_s16le", dest.path]
                    task.arguments = args
                    let pipe = Pipe()
                    task.standardError = pipe
                    try task.run()
                    task.waitUntilExit()
                    let output = pipe.fileHandleForReading.readDataToEndOfFile()
                    guard task.terminationStatus == 0 else {
                        throw ImportError.conversionFailed(String(data: output, encoding: .utf8) ?? "Exit code \(task.terminationStatus)")
                    }
                }
                do {
                    try attempt(forceVP9: true)
                } catch {
                    try? FileManager.default.removeItem(at: dest)
                    try attempt(forceVP9: false)
                }
                return dest.path
            }
            let dest = folder.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: url, to: dest)
            return dest.path
        }.value
    }

    static func stageAudio(from url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let ext = url.pathExtension.lowercased()
            guard ["wav", "mp3", "m4a", "aac", "aif", "aiff", "caf", "flac"].contains(ext) else {
                throw ImportError.unsupported(ext)
            }
            let folder = try stagingFolder()
            let dest = folder.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: url, to: dest)
            return dest.path
        }.value
    }

    private static func stagingFolder() throws -> URL {
        let fm = FileManager.default
        let parent = try fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("OpenPresentation/ImportedMedia", isDirectory: true)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent
    }
}
