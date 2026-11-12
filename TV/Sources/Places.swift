import SwiftUI

// Calendar and Activity, from the web app's pages/calendar.tsx and pages/history.tsx: what
// airs in the coming days, and what was watched, each grouped by day.

/// "Today", "Tomorrow", "Yesterday", or the weekday and date.
private func dayName(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInTomorrow(date) { return "Tomorrow" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
}

private let isoParser: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let isoPlain = ISO8601DateFormatter()

/// A Jellyfin date, which can carry more fractional digits than the parser takes.
func parseDate(_ text: String?) -> Date? {
    guard let text else { return nil }
    // Jellyfin gives seven fractional digits, more than the parser takes.
    if let date = isoParser.date(from: text) ?? isoPlain.date(from: text) { return date }
    let trimmed = text.replacingOccurrences(of: #"\.(\d{3})\d*"#, with: ".$1", options: .regularExpression)
    return isoParser.date(from: trimmed)
}

/// A day's heading and its row of stills.
private struct DayRow: View {
    let title: String
    let detail: String?
    let items: [Item]
    let play: (Item) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(12)) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.px(10)) {
                Text(title).font(Theme.font(Theme.lg, .semibold))
                if let detail { Text(detail).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray400) }
            }
            .pagePadding()
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.px(16)) {
                    ForEach(items) { item in
                        WideCard(item: item) { play(item) }
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

// MARK: - Calendar

struct CalendarView: View {
    @EnvironmentObject private var session: Session
    @State private var days: [(Date, [Item])] = []
    @State private var loaded = false
    @State private var choice: VersionChoice?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.px(32)) {
                PageTitle(text: "Calendar")
                if loaded && days.isEmpty {
                    Text("Nothing airs in the next two weeks.")
                        .font(Theme.font(Theme.base))
                        .foregroundStyle(Theme.gray400)
                        .focusable()
                }
                if !loaded { ProgressView().frame(maxWidth: .infinity) }
                ForEach(days.indices, id: \.self) { index in
                    let items = days[index].1
                    DayRow(title: dayName(days[index].0), detail: items.count == 1 ? "1 title" : "\(items.count) titles", items: items) { item in
                        if item.playable && item.locationType != "Virtual" {
                            Task { choice = await playChoice(for: item, session: session) }
                        }
                    }
                }
            }
            .padding(.bottom, Theme.px(64))
        }
        .edgeToEdge()
        .task { if !loaded { await load() } }
        .playFlow($choice)
    }

    private func load() async {
        guard let client = session.client, let userId = session.userId else { return }
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!
        let end = calendar.date(byAdding: .day, value: 15, to: start)!
        let iso = ISO8601DateFormatter()
        let result: ItemsResult? = try? await client.get("/Items", [
            "userId": userId,
            "IncludeItemTypes": "Episode,Movie",
            "Recursive": "true",
            "MinPremiereDate": iso.string(from: start),
            "MaxPremiereDate": iso.string(from: end),
            "SortBy": "PremiereDate",
            "Limit": "500",
            "Fields": "Overview",
        ])
        var grouped: [Date: [Item]] = [:]
        for item in result?.items ?? [] {
            guard let date = parseDate(item.premiereDate) else { continue }
            grouped[calendar.startOfDay(for: date), default: []].append(item)
        }
        days = grouped.keys.sorted().map { ($0, grouped[$0]!) }
        loaded = true
    }
}

// MARK: - Activity

struct HistoryEntry: Decodable {
    var kind: String?
    var played: Bool?
    var positionMs: Double?
    var durationMs: Double?
    var lastPlayedAt: Double?
    var sortAt: Double?
    var item: Item
}

struct HistoryPage: Decodable {
    var items: [HistoryEntry]
    var cursor: String?
}

struct ActivityView: View {
    @EnvironmentObject private var session: Session
    @State private var entries: [HistoryEntry] = []
    @State private var cursor: String?
    @State private var loaded = false
    @State private var loading = false
    @State private var choice: VersionChoice?

    /// Days in order; within a day, one card a show, its latest episode.
    private var days: [(Date?, [Item])] {
        var order: [Date?] = []
        var byDay: [Date?: [Item]] = [:]
        var seen: [Date?: Set<String>] = [:]
        for entry in entries {
            let when = (entry.lastPlayedAt ?? entry.sortAt).map { Date(timeIntervalSince1970: $0 / 1000) }
            let day = when.map { Calendar.current.startOfDay(for: $0) }
            if byDay[day] == nil { order.append(day); byDay[day] = [] }
            let key = entry.item.isEpisode ? (entry.item.seriesId ?? entry.item.id) : entry.item.id
            if seen[day, default: []].insert(key).inserted { byDay[day]?.append(entry.item) }
        }
        return order.map { ($0, byDay[$0] ?? []) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.px(32)) {
                PageTitle(text: "Activity")
                if loaded && entries.isEmpty {
                    Text("What you watch shows here.")
                        .font(Theme.font(Theme.base))
                        .foregroundStyle(Theme.gray400)
                        .focusable()
                }
                if !loaded { ProgressView().frame(maxWidth: .infinity) }
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    DayRow(title: day.0.map(dayName) ?? "Earlier", detail: nil, items: day.1) { item in
                        Task { choice = await playChoice(for: item, session: session) }
                    }
                    .onAppear { if index == days.count - 1 { Task { await more() } } }
                }
                if loading && loaded { ProgressView().frame(maxWidth: .infinity) }
            }
            .padding(.bottom, Theme.px(64))
        }
        .edgeToEdge()
        .task { if !loaded { await more() } }
        .refreshOnReturn {
            entries = []
            cursor = nil
            loaded = false
            await more()
        }
        .reloadOnWatchChange {
            entries = []
            cursor = nil
            loaded = false
            await more()
        }
        .playFlow($choice)
    }

    private func more() async {
        guard !loading, let client = session.client, let userId = session.userId else { return }
        if loaded && cursor == nil { return }
        loading = true
        defer { loading = false }
        let page: HistoryPage? = try? await client.get("/AIOStreams/History", ["userId": userId, "cursor": cursor])
        entries.append(contentsOf: page?.items ?? [])
        cursor = page?.cursor
        loaded = true
    }
}
