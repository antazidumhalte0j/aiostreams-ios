import SwiftUI

// A person's page, after the web app's (app/person): their picture, name and what's known of them,
// then the films and shows they're in on this server, newest first.

struct PersonView: View {
    @EnvironmentObject private var session: Session
    let person: Person

    @State private var details: Item?
    @State private var movies: [Item] = []
    @State private var shows: [Item] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.px(32)) {
                header
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else if movies.isEmpty && shows.isEmpty {
                    Text("Nothing with \(person.name ?? "them") on this server.")
                        .font(Theme.font(Theme.base))
                        .foregroundStyle(Theme.gray400)
                        .pagePadding()
                        .focusable()
                }
                if !movies.isEmpty { section("Movies", movies) }
                if !shows.isEmpty { section("Shows", shows) }
            }
            .padding(.bottom, Theme.px(64))
        }
        .edgeToEdge()
        .task { if !loaded { await load() } }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.px(28)) {
            ZStack {
                Circle().fill(Theme.gray900)
                if let client = session.client, let tag = person.primaryImageTag {
                    AsyncImage(url: client.image(person.id, .primary, tag: tag, height: 360)) { phase in
                        if case .success(let image) = phase { image.resizable().aspectRatio(contentMode: .fill) }
                    }
                }
            }
            .frame(width: Theme.px(160), height: Theme.px(160))
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: Theme.px(1)))
            VStack(alignment: .leading, spacing: Theme.px(8)) {
                Text(person.name ?? "").font(Theme.font(Theme.xl3, .bold))
                if let born = parseDate(details?.premiereDate) {
                    Text("Born \(born.formatted(date: .long, time: .omitted))")
                        .font(Theme.font(Theme.sm))
                        .foregroundStyle(Theme.gray400)
                }
                if let overview = details?.overview, !overview.isEmpty {
                    Text(overview)
                        .font(Theme.font(Theme.base))
                        .foregroundStyle(Theme.gray300)
                        .lineLimit(6)
                        .frame(maxWidth: Theme.px(760), alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .pagePadding()
        .padding(.top, Theme.px(40))
    }

    private func section(_ title: String, _ items: [Item]) -> some View {
        VStack(alignment: .leading, spacing: Theme.px(8)) {
            Text(title).font(Theme.font(Theme.xl, .semibold)).pagePadding()
            PosterGrid(items: items)
        }
        .focusSection()
    }

    private func load() async {
        defer { loaded = true }
        guard let client = session.client, let userId = session.userId else { return }
        async let about: ItemsResult? = try? client.get("/Items", ["userId": userId, "Ids": person.id, "Fields": "Overview"])
        async let titles: ItemsResult? = try? client.get("/Items", [
            "userId": userId,
            "PersonIds": person.id,
            "Recursive": "true",
            "IncludeItemTypes": "Movie,Series",
            "SortBy": "PremiereDate,ProductionYear,SortName",
            "SortOrder": "Descending",
            "Limit": "200",
        ])
        details = await about?.items?.first
        let all = await titles?.items ?? []
        movies = all.filter { $0.type == "Movie" }
        shows = all.filter(\.isSeries)
    }
}
