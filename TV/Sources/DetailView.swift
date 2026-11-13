import SwiftUI

// The web app's title page (pages/item.tsx) as a TV shows it: the backdrop over the top,
// the poster beside the title's logo, facts, genres and overview, its actions, then the
// seasons as pills over a row of episodes, the cast, and titles like it.

struct DetailView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    let item: Item
    /// The trailer playing, or being found.
    @State private var trailer: PlayRequest?
    @State private var findingTrailer = false
    @State private var trailerFailed = false

    @State private var full: Item?
    @State private var seasons: [Item] = []
    @State private var season: Item?
    @State private var episodes: [Item] = []
    @State private var nextUp: Item?
    @State private var similar: [Item] = []
    @State private var choice: VersionChoice?
    @FocusState private var playFocused: Bool

    private var shown: Item { full ?? item }

    /// What Play plays: the title, or a show's next episode.
    private var target: Item? { shown.isSeries ? nextUp : (shown.playable ? shown : nil) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ItemBackdrop(item: shown)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.px(48)) {
                    header
                    if shown.isSeries { seasonsSection }
                    castSection
                    if !similar.isEmpty {
                        ItemRow(row: HomeRow(id: "similar", title: "More like this", items: similar))
                    }
                }
                // 26% down a 720-line screen.
                .padding(.top, Theme.px(187))
                .padding(.bottom, Theme.px(64))
            }
            .edgeToEdge()
        }
        .task { await load() }
        .reloadOnWatchChange { await load() }
        .playFlow($choice) { Task { await load() } }
        .fullScreenCover(item: $trailer) { request in
            PlayerScreen(request: request, close: { trailer = nil })
                .environmentObject(session)
                .environmentObject(prefs)
        }
        .alert("This trailer couldn't be played.", isPresented: $trailerFailed) {
            Button("OK", role: .cancel) {}
        }
        .onAppear { playFocused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: Theme.px(32)) {
            RemoteImage(url: session.client?.poster(shown, height: 672))
                .frame(width: Theme.px(224), height: Theme.px(336))
                .clipShape(RoundedRectangle(cornerRadius: Theme.px(12), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.px(12), style: .continuous).stroke(.white.opacity(0.1), lineWidth: Theme.px(1)))
                .shadow(color: .black.opacity(0.6), radius: Theme.px(24), y: Theme.px(12))
            VStack(alignment: .leading, spacing: Theme.px(16)) {
                TitleLogo(item: shown, maxHeight: Theme.px(128), maxWidth: Theme.px(416), titleSize: 48)
                if let tagline = shown.taglines?.first, !tagline.isEmpty {
                    Text(tagline).font(Theme.font(Theme.base)).italic().foregroundStyle(Theme.gray300)
                }
                facts
                if let genres = shown.genres, !genres.isEmpty {
                    HStack(spacing: Theme.px(6)) {
                        ForEach(genres.prefix(6), id: \.self) { genre in
                            Text(genre)
                                .font(Theme.font(13, .semibold))
                                .padding(.horizontal, Theme.px(10))
                                .padding(.vertical, Theme.px(3))
                                .background(Capsule().fill(.white.opacity(0.1)))
                                .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: Theme.px(1)))
                        }
                    }
                }
                if let overview = shown.overview, !overview.isEmpty {
                    Text(overview)
                        .font(Theme.font(Theme.base))
                        .lineSpacing(Theme.px(5))
                        .foregroundStyle(Theme.gray300)
                        .lineLimit(4)
                }
                actions
            }
            .frame(maxWidth: Theme.px(768), alignment: .leading)
        }
        .pagePadding()
    }

    /// `2024 • PG-13 • 2h 47m • ★ 8.4`, the rating boxed.
    private var facts: some View {
        var parts: [AnyView] = []
        if let year = shown.productionYear { parts.append(AnyView(Text(String(year)))) }
        if let rating = shown.officialRating, !rating.isEmpty {
            parts.append(AnyView(
                Text(rating)
                    .font(Theme.font(Theme.xs))
                    .padding(.horizontal, Theme.px(6))
                    .padding(.vertical, Theme.px(1))
                    .overlay(RoundedRectangle(cornerRadius: Theme.px(4)).stroke(.white.opacity(0.3), lineWidth: Theme.px(1)))
            ))
        }
        if !shown.isSeries, let runtime = shown.runtimeText { parts.append(AnyView(Text(runtime))) }
        if shown.isSeries, let status = shown.status, status == "Continuing" || status == "Ended" {
            parts.append(AnyView(Text(status)))
        }
        if let score = shown.communityRating, score > 0 {
            parts.append(AnyView(HStack(spacing: Theme.px(4)) {
                Image(systemName: "star.fill").foregroundStyle(Theme.star).font(.system(size: Theme.px(12)))
                Text(String(format: "%.1f", score))
            }))
        }
        return MetaLine(parts: parts)
            .font(Theme.font(Theme.sm))
            .foregroundStyle(Theme.gray200)
    }

    /// The web app's labels: `Resume S01E04`, `Resume from 1:35:11`, `Play S01E01`, `Play`.
    private var playLabel: String {
        let code = shown.isSeries ? target?.episodeCode : nil
        if let resume = target?.resumeMs {
            return code.map { "Resume \($0)" } ?? "Resume from \(clock(resume))"
        }
        return code.map { "Play \($0)" } ?? "Play"
    }

    private var actions: some View {
        HStack(spacing: Theme.px(8)) {
            if let target {
                Button {
                    choice = VersionChoice(item: target, startMs: target.resumeMs)
                } label: {
                    Label(playLabel, systemImage: "play.fill")
                }
                .buttonStyle(PrimaryPillStyle())
                .focused($playFocused)
                if target.resumeMs != nil {
                    Button {
                        choice = VersionChoice(item: target, startMs: 0)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(CircleIconStyle())
                }
            }
            if shown.remoteTrailers?.contains(where: { $0.url != nil }) == true {
                Button {
                    Task { await playTrailer() }
                } label: {
                    if findingTrailer { ProgressView() } else { Image(systemName: "film") }
                }
                .buttonStyle(CircleIconStyle())
                .disabled(findingTrailer)
            }
            Button {
                Task { await setPlayed(!(shown.userData?.played ?? false)) }
            } label: {
                Image(systemName: "checkmark")
            }
            .buttonStyle(CircleIconStyle(active: shown.userData?.played == true))
            Button {
                Task { await setFavourite(!(shown.userData?.isFavorite ?? false)) }
            } label: {
                Image(systemName: shown.userData?.isFavorite == true ? "heart.fill" : "heart")
            }
            .buttonStyle(CircleIconStyle(active: shown.userData?.isFavorite == true))
        }
        .focusSection()
    }

    // MARK: Seasons and episodes

    @ViewBuilder private var seasonsSection: some View {
        VStack(alignment: .leading, spacing: Theme.px(16)) {
            if seasons.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: Theme.px(8)) {
                        ForEach(seasons) { candidate in
                            Button(candidate.name ?? "Season") {
                                season = candidate
                                Task { await loadEpisodes() }
                            }
                            .buttonStyle(SeasonPillStyle(selected: candidate.id == season?.id))
                        }
                    }
                    .pagePadding()
                    .padding(.vertical, Theme.px(6))
                }
                .edgeToEdge()
                .focusSection()
            } else if let only = seasons.first {
                Text(only.name ?? "Episodes").font(Theme.font(Theme.xl, .semibold))
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.px(16)) {
                    ForEach(episodes) { episode in
                        EpisodeCard(episode: episode) {
                            choice = VersionChoice(item: episode, startMs: episode.resumeMs)
                        }
                    }
                }
                .pagePadding()
                .padding(.vertical, Theme.px(8))
            }
            .edgeToEdge()
            .focusSection()
        }
    }

    // MARK: Cast

    @ViewBuilder private var castSection: some View {
        let cast = Array((shown.people ?? []).filter { $0.type == "Actor" || $0.type == nil }.prefix(30))
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: Theme.px(16)) {
                Text("Cast").font(Theme.font(Theme.xl, .semibold))
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Theme.px(16)) {
                        ForEach(cast) { person in
                            PersonCard(person: person, url: personImage(person))
                        }
                    }
                    .pagePadding()
                    .padding(.vertical, Theme.px(8))
                }
                .edgeToEdge()
            }
            .focusSection()
        }
    }

    private func personImage(_ person: Person) -> URL? {
        guard let client = session.client, let tag = person.primaryImageTag else { return nil }
        return client.image(person.id, .primary, tag: tag, height: 192)
    }

    // MARK: Trailer

    /// Plays the title's first trailer: a YouTube one through the stream the app finds, as the web
    /// app's players do, any other by its address.
    private func playTrailer() async {
        guard !findingTrailer, let trailers = shown.remoteTrailers else { return }
        findingTrailer = true
        defer { findingTrailer = false }
        var found: (url: String, language: String?)?
        for candidate in trailers {
            if let id = candidate.youTubeId {
                let stream: YouTube.Stream? = await withCheckedContinuation { done in
                    YouTube.resolve(id) { done.resume(returning: $0) }
                }
                if let stream { found = (stream.url, stream.originalLanguage) }
            } else if let url = candidate.url, url.lowercased().hasPrefix("http") {
                found = (url, nil)
            }
            if found != nil { break }
        }
        guard let found else {
            trailerFailed = true
            return
        }
        // The account's audio languages, with Original meaning the trailer's own.
        let chosen = prefs.languages(list: "AudioLanguages", one: "AudioLanguagePreference")
        var languages = chosen.compactMap { $0 == "OriginalLanguage" ? found.language : $0 }
        if languages.isEmpty, let original = found.language { languages = [original] }
        trailer = PlayRequest(
            item: shown,
            source: MediaSource(id: "trailer", name: "Trailer", path: found.url),
            playSessionId: nil,
            startMs: nil,
            isTrailer: true,
            audioLanguages: languages
        )
    }

    // MARK: Loading

    private func load() async {
        guard let client = session.client, let userId = session.userId else { return }
        let found: ItemsResult? = try? await client.get("/Items", [
            "userId": userId,
            "Ids": item.id,
            "Fields": "Genres,Overview,People,Taglines,Status,RemoteTrailers,ProviderIds",
        ])
        if let first = found?.items?.first { full = first }
        let similarResult: ItemsResult? = try? await client.get("/Items/\(item.id)/Similar", ["userId": userId, "Limit": "12"])
        similar = similarResult?.items ?? []
        guard shown.isSeries else { return }
        let next: ItemsResult? = try? await client.get("/Shows/NextUp", ["userId": userId, "SeriesId": item.id, "Limit": "1"])
        nextUp = next?.items?.first
        let list: ItemsResult? = try? await client.get("/Shows/\(item.id)/Seasons", ["userId": userId])
        seasons = list?.items ?? []
        // Opens on the next episode's season, else the first with something left, as the web app does.
        if season == nil || !seasons.contains(where: { $0.id == season?.id }) {
            season = seasons.first { $0.id == nextUp?.seasonId }
                ?? seasons.first { $0.userData?.played != true && ($0.indexNumber ?? 0) > 0 }
                ?? seasons.first
        }
        await loadEpisodes()
        if nextUp == nil { nextUp = episodes.first { $0.playable } }
    }

    private func loadEpisodes() async {
        guard let client = session.client, let userId = session.userId, let season else { return }
        let list: ItemsResult? = try? await client.get("/Shows/\(item.id)/Episodes", [
            "userId": userId,
            "SeasonId": season.id,
            "Fields": "Overview",
        ])
        episodes = list?.items ?? []
    }

    private func setPlayed(_ played: Bool) async {
        guard let client = session.client, let userId = session.userId else { return }
        try? await client.call(played ? "POST" : "DELETE", "/UserPlayedItems/\(shown.id)", ["userId": userId])
        await load()
    }

    private func setFavourite(_ favourite: Bool) async {
        guard let client = session.client, let userId = session.userId else { return }
        try? await client.call(favourite ? "POST" : "DELETE", "/UserFavoriteItems/\(shown.id)", ["userId": userId])
        await load()
    }

    private func clock(_ ms: Double) -> String {
        let seconds = Int(ms / 1000)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The title's backdrop over the top 85% of the screen, under the rail, shaded into the page.
struct ItemBackdrop: View {
    @EnvironmentObject private var session: Session
    let item: Item

    private static let height = Theme.px(612)

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width + Theme.px(80), Self.height * 2.6)
            ZStack(alignment: .bottom) {
                RemoteImage(url: session.client?.backdrop(item, height: 1080))
                    .frame(width: width, height: Self.height)
                    .mask(
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0), .init(color: .black, location: Theme.px(192) / width)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                LinearGradient(
                    stops: [
                        .init(color: Theme.background, location: 0),
                        .init(color: Theme.background.opacity(0.6), location: 0.4),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                LinearGradient(
                    stops: [
                        .init(color: Theme.background, location: 0),
                        .init(color: Theme.background.opacity(0.7), location: 0.5),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(height: Self.height * 3 / 4)
            }
            .frame(height: Self.height)
        }
        .frame(height: Self.height)
        .padding(.leading, -Theme.px(80))
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// A season's pill: white when chosen, as the web app's season pills are.
struct SeasonPillStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        SeasonPill(label: configuration.label, selected: selected, pressed: configuration.isPressed)
    }

    private struct SeasonPill<Label: View>: View {
        @Environment(\.isFocused) private var focused
        let label: Label
        let selected: Bool
        let pressed: Bool

        var body: some View {
            label
                .font(Theme.font(Theme.sm, .medium))
                .foregroundStyle(selected ? Color.black : (focused ? Color.white : Theme.gray200))
                .padding(.horizontal, Theme.px(14))
                .frame(height: Theme.px(34))
                .background(Capsule().fill(selected ? Color.white : (focused ? Color.white.opacity(0.16) : Theme.gray800)))
                .focusRing(focused)
                .opacity(pressed ? 0.8 : 1)
        }
    }
}

/// An episode in the row: its still with how far it got, its number and name, length and score,
/// and its synopsis.
struct EpisodeCard: View {
    @EnvironmentObject private var session: Session
    let episode: Item
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(8)) {
            Button(action: action) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: session.client?.poster(episode, height: Int(WideCard.size.height * 2)))
                        .frame(width: WideCard.size.width, height: WideCard.size.height)
                    if let progress = episode.userData?.playedPercentage, progress > 0, episode.userData?.played != true {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.25))
                                Rectangle().fill(Theme.brand500).frame(width: geometry.size.width * progress / 100)
                            }
                        }
                        .frame(height: Theme.px(4))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if episode.userData?.played == true {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: Theme.px(18)))
                            .foregroundStyle(.white, Theme.brand500)
                            .padding(Theme.px(8))
                    }
                }
                .frame(width: WideCard.size.width, height: WideCard.size.height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.px(12), style: .continuous))
            }
            .buttonStyle(CardStyle(radius: Theme.px(12)))
            .itemMenu(episode, onPage: true)
            VStack(alignment: .leading, spacing: Theme.px(3)) {
                Text([episode.indexNumber.map { "\($0)." }, episode.name].compactMap { $0 }.joined(separator: " "))
                    .font(Theme.font(15, .semibold))
                    .lineLimit(1)
                HStack(spacing: Theme.px(8)) {
                    if let runtime = episode.runtimeText { Text(runtime) }
                    if let score = episode.communityRating, score > 0 {
                        HStack(spacing: Theme.px(3)) {
                            Image(systemName: "star.fill").foregroundStyle(Theme.star).font(.system(size: Theme.px(10)))
                            Text(String(format: "%.1f", score))
                        }
                    }
                    if let left = episode.timeLeft { Text(left) }
                }
                .font(Theme.font(Theme.xs))
                .foregroundStyle(Theme.gray400)
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.gray400)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, Theme.px(2))
            .frame(width: WideCard.size.width, alignment: .leading)
        }
    }
}

/// A cast member: a round picture, their name and role.
struct PersonCard: View {
    @Environment(\.openRoute) private var openRoute
    let person: Person
    let url: URL?

    var body: some View {
        VStack(spacing: Theme.px(8)) {
            Button { openRoute(.person(person)) } label: {
                ZStack {
                    Circle().fill(Theme.gray900)
                    Text(initials).font(Theme.font(Theme.lg, .semibold)).foregroundStyle(Theme.gray400)
                    if let url {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase { image.resizable().aspectRatio(contentMode: .fill) }
                        }
                    }
                }
                .frame(width: Theme.px(96), height: Theme.px(96))
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: Theme.px(1)))
            }
            .buttonStyle(CircleCardStyle())
            Text(person.name ?? "")
                .font(Theme.font(Theme.xs, .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let role = person.role, !role.isEmpty {
                Text(role)
                    .font(Theme.font(Theme.xs))
                    .foregroundStyle(Theme.gray400)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: Theme.px(112))
    }

    private var initials: String {
        (person.name ?? "").split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}

/// A round picture's ring, round the circle.
struct CircleCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Ringed(label: configuration.label)
    }

    private struct Ringed<Label: View>: View {
        @Environment(\.isFocused) private var focused
        let label: Label

        var body: some View {
            label.overlay {
                if focused {
                    Circle().stroke(Theme.ring, lineWidth: Theme.ringWidth)
                        .padding(-(Theme.ringOffset + Theme.ringWidth / 2))
                }
            }
        }
    }
}
