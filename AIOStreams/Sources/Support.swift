import AetherEngineFeatures
import Foundation
import UIKit

/// Reading the page's JSON messages, which arrive through `JSONSerialization`.
enum JSON {
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    static func flag(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// A track id as the page names tracks, or null for none.
    static func id(_ index: Int?) -> Any {
        index.map { String($0) as Any } ?? NSNull()
    }

    static func orNull(_ text: String?) -> Any {
        text.map { $0 as Any } ?? NSNull()
    }

    /// A number the page can read: JSON has no NaN or infinity.
    static func finite(_ value: Double) -> Any {
        value.isFinite ? value : NSNull()
    }

    /// `#RRGGBB` or `#AARRGGBB`, as mpv takes colours.
    static func color(_ value: Any?) -> UIColor? {
        guard let text = value as? String, text.hasPrefix("#"), let raw = UInt32(text.dropFirst(), radix: 16) else { return nil }
        let channel = { (shift: UInt32) in CGFloat((raw >> shift) & 0xFF) / 255 }
        switch text.count {
        case 7: return UIColor(red: channel(16), green: channel(8), blue: channel(0), alpha: 1)
        case 9: return UIColor(red: channel(16), green: channel(8), blue: channel(0), alpha: channel(24))
        default: return nil
        }
    }

    static func encode(_ message: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The app's log: Console, and the recent lines for a problem report.
enum AppLog {
    private static let lock = NSLock()
    private static var lines: [String] = []
    private static let limit = 500
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func info(_ tag: String, _ message: String) { write("I", tag, message) }
    static func warn(_ tag: String, _ message: String) { write("W", tag, message) }

    private static func write(_ level: String, _ tag: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) \(level) \(tag): \(message)"
        NSLog("%@", line)
        lock.lock()
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        lock.unlock()
    }

    static var recent: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

/// What the page reads about the app as it starts.
enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    static var deviceModel: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    @MainActor static var deviceName: String { UIDevice.current.name }

    /// Kept until the app is removed, so the server can tell this device's sessions apart.
    @MainActor static var deviceId: String {
        let key = "aiostreams.deviceId"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    static var player: String { "AetherEngine \(AetherEngine.version)" }

    /// What the app ships besides the page, in the page's own list's shape.
    static var licenses: [String: Any] {
        let lgpl = "GNU Lesser General Public License v3.0, with the AetherEngine App Store / DRM exception. https://github.com/superuser404notfound/AetherEngine/blob/\(AetherEngine.version)/LICENSE"
        let ffmpeg = "GNU Lesser General Public License v2.1 or later. Built by FFmpegBuild, whose LICENSES folder lists every component: https://github.com/superuser404notfound/FFmpegBuild/tree/main/LICENSES"
        let mit = { (holder: String) in """
        MIT License

        Copyright (c) \(holder)

        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
        """ }
        return [
            "type": "licenses",
            "texts": [lgpl, ffmpeg, mit("quietvoid and contributors"), mit("2019-2021 bloc97\nAll rights reserved.")],
            "libraries": [
                ["name": "AetherEngine", "version": AetherEngine.version, "licence": "LGPL-3.0-only",
                 "url": "https://github.com/superuser404notfound/AetherEngine", "texts": [0]],
                ["name": "FFmpeg", "licence": "LGPL-2.1-or-later", "url": "https://ffmpeg.org", "texts": [1]],
                ["name": "libdovi", "licence": "MIT", "url": "https://github.com/quietvoid/dovi_tool", "texts": [2]],
                // The line-art scaler's kernels, compiled into the engine whether or not it runs.
                ["name": "Anime4K", "licence": "MIT", "url": "https://github.com/bloc97/Anime4K", "texts": [3]],
            ],
        ]
    }
}

/// JPEGs of keyframes the page shows over the seek bar, served at `/thumbnail/...`.
final class ThumbnailStore: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: Data] = [:]
    private var order: [String] = []
    private let limit = 128

    func put(_ path: String, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        images[path] = data
        order.append(path)
        while order.count > limit { images[order.removeFirst()] = nil }
    }

    func get(_ path: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return images[path]
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        images.removeAll()
        order.removeAll()
    }
}
