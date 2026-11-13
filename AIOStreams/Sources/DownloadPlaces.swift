import Foundation

/// Where a download's files may go, as the Android and desktop apps allow: a known media,
/// subtitle, image or details file at a relative path inside the downloads folder. Foundation
/// only, so the rules are tested without UIKit. Ported from the 9pbpsvr6f9-alt/aiostreams-ios fork.
enum DownloadPlaces {
    static let extensions: Set<String> = [
        "mkv", "mp4", "m4v", "avi", "mov", "webm", "ts", "m2ts", "wmv", "flv", "mpg", "mpeg", "ogv",
        "3gp", "srt", "vtt", "ass", "ssa", "sub", "sup", "idx", "ttml", "jpg", "jpeg", "png", "webp",
        "avif", "json",
    ]

    /// Names Windows refuses, for files copied off the device.
    private static let reserved: Set<String> = [
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8",
        "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ]

    struct Refused: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The file for `relative` inside `folder`, or an error naming what is wrong with it.
    static func place(_ folder: URL, _ relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { throw Refused(message: "no file name") }
        for part in parts {
            let stem = part.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map { String($0).uppercased() } ?? ""
            let bad = part.isEmpty || part == "." || part == ".." || part.count > 200
                || part.hasSuffix(".") || part.hasSuffix(" ")
                || part.unicodeScalars.contains { $0.properties.generalCategory == .control || "<>:\"\\|?*".unicodeScalars.contains($0) }
                || reserved.contains(stem)
            if bad { throw Refused(message: "\(part) is not a usable name") }
        }
        let ext = (relative as NSString).pathExtension.lowercased()
        guard extensions.contains(ext) else { throw Refused(message: "\(relative) is not a media file") }
        let file = parts.reduce(folder) { $0.appendingPathComponent($1) }
        guard isInside(folder, file.path) else { throw Refused(message: "\(relative) leaves the downloads folder") }
        return file
    }

    /// The partial file a download writes before it is complete.
    static func part(of file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".part")
    }

    /// Whether `path` (a plain path or a file URL) names a file inside `folder`.
    static func isInside(_ folder: URL, _ path: String) -> Bool {
        let plain = path.hasPrefix("file://") ? (URL(string: path)?.path ?? "") : path
        guard plain.hasPrefix("/") else { return false }
        let root = folder.standardizedFileURL.path
        let candidate = URL(fileURLWithPath: plain).standardizedFileURL.path
        return candidate.hasPrefix(root + "/")
    }
}
