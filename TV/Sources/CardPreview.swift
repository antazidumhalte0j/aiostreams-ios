import AVFoundation
import SwiftUI

// Card previews, after the web app's (components/media/card-preview.tsx): focus resting on a poster
// in a row opens it out into a wide card with the title's artwork and details, and a moment later its
// trailer plays in it. Upstream's TV timings: 1.2 s of rest to open, 1.5 s more before the trailer.

enum CardPreviewTiming {
    static let rest: Duration = .milliseconds(1200)
    static let trailer: Duration = .milliseconds(1500)
}

/// The opened card: the backdrop with the logo or title and the year, rating and genres over it,
/// then the trailer over all of it once it plays.
struct CardPreview: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    let item: Item
    let size: CGSize

    @State private var player: AVPlayer?
    @State private var playing = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: session.client?.backdrop(item, height: Int(size.height * 2))
                        ?? session.client?.still(item, height: Int(size.height * 2)))
                .frame(width: size.width, height: size.height)
            LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .bottom, endPoint: .center)
            VStack(alignment: .leading, spacing: Theme.px(4)) {
                TitleLogo(item: item, maxHeight: Theme.px(44), maxWidth: size.width * 0.6, titleSize: 22)
                HeroMeta(item: item)
                    .font(Theme.font(Theme.xs))
            }
            .padding(Theme.px(12))
            if let player {
                TrailerLayer(player: player)
                    .frame(width: size.width, height: size.height)
                    .opacity(playing ? 1 : 0)
                    .animation(.easeOut(duration: 0.4), value: playing)
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: item.id) { await startTrailer() }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    /// The title's first trailer, after a moment, muted unless Trailer sound is on.
    private func startTrailer() async {
        guard prefs.cardTrailers else { return }
        try? await Task.sleep(for: CardPreviewTiming.trailer)
        guard !Task.isCancelled, let client = session.client, let userId = session.userId else { return }
        // Rows come without their trailers, which the title's own details carry.
        let found: ItemsResult? = try? await client.get("/Items", ["userId": userId, "Ids": item.id, "Fields": "RemoteTrailers"])
        guard !Task.isCancelled, let url = await trailerURL(found?.items?.first?.remoteTrailers ?? []) else { return }
        let next = AVPlayer(url: url)
        next.isMuted = !prefs.trailerSound
        next.play()
        player = next
        // Shown once frames are coming, so the artwork doesn't blink to black first.
        while !Task.isCancelled, next.timeControlStatus != .playing {
            try? await Task.sleep(for: .milliseconds(150))
        }
        if !Task.isCancelled { playing = true }
    }

    private func trailerURL(_ trailers: [RemoteTrailer]) async -> URL? {
        for trailer in trailers {
            if let id = trailer.youTubeId {
                let stream: YouTube.Stream? = await withCheckedContinuation { done in
                    YouTube.resolve(id) { done.resume(returning: $0) }
                }
                if let stream, let url = URL(string: stream.url) { return url }
            } else if let text = trailer.url, text.lowercased().hasPrefix("http"), let url = URL(string: text) {
                return url
            }
        }
        return nil
    }
}

/// An AVPlayer's picture, filling its frame.
private struct TrailerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        view.playerLayer.player = player
    }

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
