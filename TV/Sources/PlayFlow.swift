import SwiftUI

/// How Play picks a version: as the settings say, by listing them, or by starting the first.
enum PlayMode {
    case usual, list, straight
}

/// Something to play: an item, from where it would start. A show plays its next episode.
struct VersionChoice: Identifiable {
    let id = UUID()
    let item: Item
    let startMs: Double?
    var mode: PlayMode = .usual
}

/// The version each title last played in, kept on this device, which resuming goes back to.
enum LastVersions {
    private static let key = "playback.lastVersions"
    private static let limit = 500

    static func get(_ itemId: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[itemId]
    }

    static func set(_ itemId: String, _ sourceId: String) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[itemId] = sourceId
        if all.count > limit { all.removeValue(forKey: all.keys.first { $0 != itemId }!) }
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// Lists a choice's versions, or starts one straight away, then plays it over whatever screen asked.
/// As the web app's picker does: Play starts the first version when "Auto-play the first version" is on,
/// and resuming goes back to the version that was playing; otherwise Play lists them.
struct PlayFlow: ViewModifier {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @Binding var choice: VersionChoice?
    var finished: () -> Void = {}

    @State private var playing: PlayRequest?
    /// Waits for the version sheet to close, as one screen can't open over another closing.
    @State private var pendingPlay: PlayRequest?
    /// The title a version is being found for, without the list.
    @State private var finding: Item?
    /// An episode the player played on to, whose versions are listed once the player has closed.
    @State private var listAfterPlayer: VersionChoice?

    private func straight(_ choice: VersionChoice) -> Bool {
        switch choice.mode {
        case .list: return false
        case .straight: return true
        case .usual:
            return prefs.autoPlayFirst || ((choice.startMs ?? 0) > 0 && LastVersions.get(choice.item.id) != nil)
        }
    }

    /// The list, for a choice that isn't played straight away.
    private var listed: Binding<VersionChoice?> {
        Binding(
            get: { choice.flatMap { straight($0) ? nil : $0 } },
            set: { choice = $0 }
        )
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let finding {
                    HStack(spacing: Theme.px(12)) {
                        ProgressView()
                        Text("Finding a version of \(finding.isEpisode ? finding.displayTitle : finding.name ?? "this")…")
                            .font(Theme.font(Theme.base, .medium))
                    }
                    .padding(.horizontal, Theme.px(20))
                    .padding(.vertical, Theme.px(12))
                    .background(Capsule().fill(Color(white: 17 / 255).opacity(0.95)))
                    .padding(.bottom, Theme.px(40))
                    .transition(.opacity)
                }
            }
            .onChange(of: choice?.id) { _, _ in
                guard let choice, straight(choice) else { return }
                self.choice = nil
                Task { await playStraight(choice) }
            }
            .fullScreenCover(item: listed, onDismiss: {
                if let request = pendingPlay {
                    pendingPlay = nil
                    playing = request
                }
            }) { choice in
                VersionsView(choice: choice) { request in
                    LastVersions.set(request.item.id, request.source.ownId)
                    pendingPlay = request
                    self.choice = nil
                }
                .environmentObject(session)
                .environmentObject(prefs)
                // The page stays in sight, dimmed, behind the panel.
                .presentationBackground(.clear)
            }
            .fullScreenCover(item: $playing, onDismiss: {
                if let next = listAfterPlayer {
                    listAfterPlayer = nil
                    choice = next
                }
            }) { request in
                PlayerScreen(request: request, close: {
                    playing = nil
                    finished()
                }, listVersions: { item in
                    listAfterPlayer = VersionChoice(item: item, startMs: item.userData?.played == true ? nil : item.resumeMs, mode: .list)
                })
                .environmentObject(session)
                .environmentObject(prefs)
            }
    }

    /// The version that was playing, else the first; the list where there's none to play.
    private func playStraight(_ choice: VersionChoice) async {
        guard let client = session.client, let userId = session.userId else { return }
        finding = choice.item
        defer { finding = nil }
        let info = try? await client.playbackInfo(userId: userId, itemId: choice.item.id)
        let sources = (info?.mediaSources ?? []).filter { $0.aiostreams?.ytId == nil }
        let last = (choice.startMs ?? 0) > 0 ? LastVersions.get(choice.item.id) : nil
        guard let source = sources.first(where: { $0.ownId == last }) ?? sources.first else {
            self.choice = VersionChoice(item: choice.item, startMs: choice.startMs, mode: .list)
            return
        }
        // Named again, the version brings its subtitles from the configuration's subtitle addons.
        var chosen = source
        var playSession = info?.playSessionId
        if let named = try? await client.playbackInfo(userId: userId, itemId: choice.item.id, sourceId: source.ownId),
           let match = named.mediaSources?.first(where: { $0.ownId == source.ownId }) ?? named.mediaSources?.first {
            chosen = match
            playSession = named.playSessionId ?? playSession
        }
        LastVersions.set(choice.item.id, chosen.ownId)
        playing = PlayRequest(item: choice.item, source: chosen, playSessionId: playSession, startMs: choice.startMs)
    }
}

extension View {
    func playFlow(_ choice: Binding<VersionChoice?>, finished: @escaping () -> Void = {}) -> some View {
        modifier(PlayFlow(choice: choice, finished: finished))
    }
}

/// What playing a title means: a show's next episode, else the title from where it stopped.
@MainActor
func playChoice(for item: Item, session: Session, mode: PlayMode = .usual) async -> VersionChoice? {
    guard item.isSeries else { return VersionChoice(item: item, startMs: item.resumeMs, mode: mode) }
    guard let client = session.client, let userId = session.userId else { return nil }
    let next: ItemsResult? = try? await client.get("/Shows/NextUp", ["userId": userId, "SeriesId": item.id, "Limit": "1"])
    if let episode = next?.items?.first { return VersionChoice(item: episode, startMs: episode.resumeMs, mode: mode) }
    let first: ItemsResult? = try? await client.get("/Shows/\(item.id)/Episodes", ["userId": userId, "Limit": "1"])
    return first?.items?.first.map { VersionChoice(item: $0, startMs: nil, mode: mode) }
}

/// Lets a page switch the rail's place.
private struct OpenPlaceKey: EnvironmentKey {
    static let defaultValue: (Place) -> Void = { _ in }
}

extension EnvironmentValues {
    var openPlace: (Place) -> Void {
        get { self[OpenPlaceKey.self] }
        set { self[OpenPlaceKey.self] = newValue }
    }
}

/// What the player is asked to play: an item, from a position, in a chosen version.
struct PlayRequest: Identifiable {
    let id = UUID()
    let item: Item
    let source: MediaSource
    let playSessionId: String?
    let startMs: Double?
    /// A title's trailer: played without telling the server, so the title's own progress is left alone.
    var isTrailer = false
    /// Audio languages in place of the account's, as a trailer's own language stands in for Original.
    var audioLanguages: [String]?
}
