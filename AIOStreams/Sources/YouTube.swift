import Foundation

/**
 * A YouTube video's stream for a trailer, asked of YouTube's player API as
 * YouTube's own apps ask, so the player can play it. Follows AIOStreams' desktop
 * `core/src/youtube.rs`, Android `YouTube.kt` and the web app's `hosts/youtube.ts`:
 * the same clients, in the same order. The links only play from the address that
 * asked, so the app resolves them itself rather than the page.
 *
 * Ported from the 9pbpsvr6f9-alt/aiostreams-ios fork, with the original audio language added.
 */
enum YouTube {
    /// A trailer's stream, and the language its default audio track is in, where a manifest with
    /// dubs says so (`en-US.4` gives `en-US`).
    struct Stream {
        let url: String
        let originalLanguage: String?
    }

    private struct Client {
        let name: String
        let id: String
        let version: String
        let userAgent: String
        let key: String?
        let fields: [String: String]
        /// An HLS playlist of every size, where the muxed formats stop at 360p.
        let hls: Bool
    }

    private static let clients = [
        Client(
            name: "VISIONOS",
            id: "101",
            version: "1.02",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
            key: nil,
            fields: [
                "deviceMake": "Apple",
                "deviceModel": "RealityDevice17,1",
                "osName": "visionOS",
                "osVersion": "26.5.23O471",
            ],
            hls: true
        ),
        Client(
            name: "ANDROID",
            id: "3",
            version: "20.10.41",
            userAgent: "com.google.android.youtube/20.10.41 (Linux; U; Android 11) gzip",
            key: "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w",
            fields: [
                "deviceMake": "Google",
                "deviceModel": "Pixel 5",
                "osName": "Android",
                "osVersion": "11",
                "androidSdkVersion": "30",
                "platform": "MOBILE",
            ],
            hls: false
        ),
    ]

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    /// The stream, or nil where no client gets one; answers on the main thread.
    static func resolve(_ videoId: String, done: @escaping (Stream?) -> Void) {
        let valid = videoId.count == 11 && videoId.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-"
        }
        guard valid else { return done(nil) }
        Task.detached {
            var stream: Stream?
            for client in clients {
                do {
                    stream = try await ask(client, videoId)
                } catch {
                    AppLog.warn("youtube", "\(client.name): \(error.localizedDescription)")
                }
                if stream != nil { break }
            }
            let found = stream
            await MainActor.run { done(found) }
        }
    }

    private static func ask(_ client: Client, _ videoId: String) async throws -> Stream? {
        var visitor: String?
        for _ in 0..<2 {
            let answer = try await player(client, videoId, visitor)
            let status = (answer["playabilityStatus"] as? [String: Any])?["status"] as? String
            if status == "OK" {
                let streaming = answer["streamingData"] as? [String: Any]
                let formats = streaming?["formats"] as? [[String: Any]] ?? []
                let url = client.hls
                    ? streaming?["hlsManifestUrl"] as? String
                    : formats.lazy.compactMap { $0["url"] as? String }.first
                return url.map { Stream(url: $0, originalLanguage: originalLanguage(streaming)) }
            }
            // Without a visitor id YouTube refuses, but hands one out for the next ask.
            guard let id = (answer["responseContext"] as? [String: Any])?["visitorData"] as? String else { return nil }
            visitor = id
        }
        return nil
    }

    /// The default audio track's language, which a manifest with dubs doesn't mark.
    private static func originalLanguage(_ streaming: [String: Any]?) -> String? {
        let adaptive = streaming?["adaptiveFormats"] as? [[String: Any]] ?? []
        let track = adaptive.lazy
            .compactMap { $0["audioTrack"] as? [String: Any] }
            .first { $0["audioIsDefault"] as? Bool == true }
        return (track?["id"] as? String)?.split(separator: ".").first.map(String.init)
    }

    private static func player(_ client: Client, _ videoId: String, _ visitor: String?) async throws -> [String: Any] {
        var fields: [String: Any] = ["clientName": client.name, "clientVersion": client.version, "hl": "en", "gl": "US"]
        if let visitor { fields["visitorData"] = visitor }
        for (name, value) in client.fields { fields[name] = value }
        let body: [String: Any] = [
            "videoId": videoId,
            "context": ["client": fields],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        let key = client.key.map { "key=\($0)&" } ?? ""
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?\(key)prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(client.id, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitor { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw YouTubeError("HTTP \(http.statusCode)")
        }
        guard let answer = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeError("not a JSON object")
        }
        return answer
    }
}

/// Resolver failures are local to this host; no dependency on the reference app's player protocol.
private struct YouTubeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
