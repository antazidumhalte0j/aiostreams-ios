import SwiftUI

// Live TV, after the web app's (app/live-tv, features/live-tv/live-tv.ts): the server's channels by
// group, as a list with what's on now and next, or as a guide of the coming hours. Choosing a
// channel plays it live.

/// Channels played on this Apple TV, newest first, which the Recent group lists.
enum RecentChannels {
    private static let key = "live.recent"
    private static let limit = 30

    static var ids: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func note(_ id: String) {
        UserDefaults.standard.set(Array(([id] + ids.filter { $0 != id }).prefix(limit)), forKey: key)
    }
}

struct LiveTVView: View {
    let view: Item

    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @State private var groups: [ChannelGroup] = [ChannelGroup(id: ChannelGroup.all, name: "All channels")]
    @State private var group = UserDefaults.standard.string(forKey: "live.group") ?? ChannelGroup.all
    @State private var guide = UserDefaults.standard.string(forKey: "live.view") == "guide"
    @State private var channels: [Item] = []
    @State private var total = 0
    @State private var loaded = false
    @State private var loading = false
    /// Programmes by channel, from the half hour before now to six hours on.
    @State private var schedules: [String: [Item]] = [:]
    @State private var now = Date()
    @State private var choice: VersionChoice?

    private static let page = 100

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.px(20)) {
                PageTitle(text: "Live TV")
                controls
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, Theme.px(40))
                } else if channels.isEmpty {
                    Text("No channels in this group.")
                        .font(Theme.font(Theme.base))
                        .foregroundStyle(Theme.gray400)
                        .pagePadding()
                        .focusable()
                } else if guide {
                    GuideView(channels: channels, schedules: schedules, window: window, now: now, play: play)
                    if channels.count < total {
                        Button("More channels") { Task { await more() } }
                            .buttonStyle(SoftPillStyle())
                            .pagePadding()
                    }
                } else {
                    ForEach(channels) { channel in
                        ChannelRow(channel: channel, slots: slots(channel), now: now) { play(channel) }
                            .pagePadding()
                            .onAppear { if channel.id == channels.last?.id { Task { await more() } } }
                    }
                }
            }
            .padding(.bottom, Theme.px(64))
        }
        .edgeToEdge()
        .playFlow($choice)
        .task { await loadGroups() }
        .task(id: group) { await reload() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = Date()
            }
        }
    }

    // MARK: Groups and view

    private var controls: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.px(8)) {
                Button { setGuide(false) } label: { Label("List", systemImage: "list.bullet") }
                    .buttonStyle(SoftPillStyle(selected: !guide))
                Button { setGuide(true) } label: { Label("Guide", systemImage: "calendar.day.timeline.left") }
                    .buttonStyle(SoftPillStyle(selected: guide))
                Rectangle().fill(.white.opacity(0.15)).frame(width: Theme.px(1), height: Theme.px(24))
                    .padding(.horizontal, Theme.px(8))
                ForEach(groups) { item in
                    Button(item.name) { choose(item.id) }
                        .buttonStyle(SoftPillStyle(selected: item.id == group))
                }
            }
            .pagePadding()
            .padding(.vertical, Theme.px(8))
        }
        .edgeToEdge()
        .focusSection()
    }

    private func setGuide(_ on: Bool) {
        guide = on
        UserDefaults.standard.set(on ? "guide" : "list", forKey: "live.view")
    }

    private func choose(_ id: String) {
        group = id
        UserDefaults.standard.set(id, forKey: "live.group")
    }

    /// Favourites and Recent where there are any, then all channels, then the server's genres.
    private func loadGroups() async {
        guard let client = session.client, let userId = session.userId else { return }
        async let favourites: ItemsResult? = try? client.get("/LiveTv/Channels", [
            "userId": userId, "IsFavorite": "true", "Limit": "1", "EnableTotalRecordCount": "true",
        ])
        async let genres: ItemsResult? = try? client.get("/Genres", [
            "userId": userId, "ParentId": view.id, "SortBy": "SortName",
        ])
        var list: [ChannelGroup] = []
        if (await favourites?.totalRecordCount ?? 0) > 0 { list.append(ChannelGroup(id: ChannelGroup.favourites, name: "Favourites")) }
        if !RecentChannels.ids.isEmpty { list.append(ChannelGroup(id: ChannelGroup.recent, name: "Recent")) }
        list.append(ChannelGroup(id: ChannelGroup.all, name: "All channels"))
        list += (await genres?.items ?? []).map { ChannelGroup(id: $0.id, name: $0.name ?? "") }
        groups = list
        // A group that's gone, such as Favourites emptied elsewhere, goes back to all channels.
        if !list.contains(where: { $0.id == group }) { choose(ChannelGroup.all) }
    }

    // MARK: Channels

    private func reload() async {
        channels = []
        total = 0
        schedules = [:]
        loaded = false
        await more()
    }

    private func more() async {
        guard !loading, let client = session.client, let userId = session.userId else { return }
        if loaded && channels.count >= total { return }
        loading = true
        defer { loading = false }
        let asked = group
        var found: [Item] = []
        if group == ChannelGroup.recent {
            let ids = RecentChannels.ids
            let result: ItemsResult? = ids.isEmpty ? nil : try? await client.get("/Items", ["userId": userId, "Ids": ids.joined(separator: ",")])
            let byId = Dictionary((result?.items ?? []).map { ($0.id, $0) }) { first, _ in first }
            found = ids.compactMap { byId[$0] }.filter(\.isChannel)
            total = found.count
        } else {
            let result: ItemsResult? = try? await client.get("/LiveTv/Channels", [
                "userId": userId,
                "StartIndex": String(channels.count),
                "Limit": String(Self.page),
                "IsFavorite": group == ChannelGroup.favourites ? "true" : nil,
                "GenreIds": [ChannelGroup.favourites, ChannelGroup.all].contains(group) ? nil : group,
                "AddCurrentProgram": "true",
                "EnableTotalRecordCount": "true",
            ])
            found = result?.items ?? []
            total = result?.totalRecordCount ?? 0
            if found.isEmpty { total = channels.count }
        }
        guard asked == group else { return }
        channels += found
        loaded = true
        await loadSchedules(for: found.map(\.id))
    }

    /// The window the guide shows, from the last half hour.
    private var window: (start: Date, end: Date) {
        let step = 30.0 * 60
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / step).rounded(.down) * step)
        return (start, start.addingTimeInterval(6 * 3600))
    }

    private func loadSchedules(for ids: [String]) async {
        guard !ids.isEmpty, let client = session.client, let userId = session.userId else { return }
        let iso = ISO8601DateFormatter()
        let (start, end) = window
        for batch in stride(from: 0, to: ids.count, by: 50).map({ Array(ids[$0..<min($0 + 50, ids.count)]) }) {
            let result: ItemsResult? = try? await client.post("/LiveTv/Programs", body: [
                "UserId": userId,
                "ChannelIds": batch,
                "MinEndDate": iso.string(from: start),
                "MaxStartDate": iso.string(from: end),
                "SortBy": ["StartDate"],
                "Fields": ["Overview", "Genres"],
            ])
            for programme in result?.items ?? [] {
                guard let channel = programme.channelId else { continue }
                schedules[channel, default: []].append(programme)
            }
        }
    }

    /// What's on now and next: from the guide where it has the channel, else what the list sent.
    private func slots(_ channel: Item) -> (now: Slot?, next: Slot?) {
        let list = (schedules[channel.id] ?? []).filter { ($0.ends ?? .distantPast) > now }
        if let first = list.first {
            let current = (first.starts ?? .distantFuture) <= now ? first : nil
            let next = current == nil ? first : list.dropFirst().first
            return (current.map(Slot.init), next.map(Slot.init))
        }
        if let current = channel.currentProgram, (current.ends ?? .distantFuture) > now {
            return (Slot(name: current.name ?? "", start: current.starts, end: current.ends), nil)
        }
        return (nil, nil)
    }

    private func play(_ channel: Item) {
        RecentChannels.note(channel.id)
        choice = VersionChoice(item: channel, startMs: nil, mode: .straight)
    }
}

struct ChannelGroup: Identifiable, Equatable {
    static let favourites = "favourites"
    static let recent = "recent"
    static let all = "all"

    let id: String
    let name: String
}

/// A programme's name and times.
struct Slot {
    var name: String
    var start: Date?
    var end: Date?

    init(name: String, start: Date?, end: Date?) {
        self.name = name
        self.start = start
        self.end = end
    }

    init(_ programme: Item) {
        self.init(name: programme.name ?? "", start: programme.starts, end: programme.ends)
    }
}

/// A channel's logo, fitted into its box, or its number where it has none.
struct ChannelLogo: View {
    @EnvironmentObject private var session: Session
    let channel: Item

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous).fill(Theme.gray800)
            if let tag = channel.tag("Primary"), let client = session.client {
                AsyncImage(url: client.image(channel.id, .primary, tag: tag, width: 240)) { phase in
                    if case .success(let image) = phase { image.resizable().scaledToFit() }
                }
                .padding(Theme.px(6))
            } else {
                Text(channel.channelNumber ?? String((channel.name ?? "?").prefix(2)))
                    .font(Theme.font(Theme.base, .semibold))
                    .foregroundStyle(Theme.gray300)
            }
        }
    }
}

/// One channel in the list: its logo, number and name, what's on with how far through it is, and what's next.
private struct ChannelRow: View {
    @EnvironmentObject private var prefs: Preferences
    let channel: Item
    let slots: (now: Slot?, next: Slot?)
    let now: Date
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: Theme.px(16)) {
                ChannelLogo(channel: channel)
                    .frame(width: Theme.px(96), height: Theme.px(54))
                VStack(alignment: .leading, spacing: Theme.px(2)) {
                    HStack(spacing: Theme.px(8)) {
                        if let number = channel.channelNumber {
                            Text(number).foregroundStyle(Theme.gray400).monospacedDigit()
                        }
                        Text(channel.name ?? "").lineLimit(1)
                    }
                    .font(Theme.font(Theme.base, .semibold))
                    if let current = slots.now {
                        Text(current.name).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray200).lineLimit(1)
                    }
                    if let next = slots.next {
                        Text("Next" + (next.start.map { " \(prefs.time($0))" } ?? "") + ": " + next.name)
                            .font(Theme.font(Theme.xs))
                            .foregroundStyle(Theme.gray400)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Theme.px(16))
                if let current = slots.now {
                    VStack(alignment: .trailing, spacing: Theme.px(6)) {
                        if let start = current.start, let end = current.end {
                            Text("\(prefs.time(start)) – \(prefs.time(end))")
                                .font(Theme.font(Theme.xs))
                                .foregroundStyle(Theme.gray400)
                                .monospacedDigit()
                        }
                        Capsule().fill(.white.opacity(0.15))
                            .frame(width: Theme.px(120), height: Theme.px(4))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Theme.brand500)
                                    .frame(width: Theme.px(120) * airedShare(from: current.start, to: current.end, now: now))
                            }
                    }
                }
            }
            .padding(.horizontal, Theme.px(16))
            .padding(.vertical, Theme.px(10))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RowStyle())
    }
}

// MARK: - Guide

/// Channels down the side and the coming hours across, each programme as wide as it lasts. The
/// channels stay put while the hours scroll; both scroll up and down together.
private struct GuideView: View {
    @EnvironmentObject private var prefs: Preferences
    let channels: [Item]
    let schedules: [String: [Item]]
    let window: (start: Date, end: Date)
    let now: Date
    let play: (Item) -> Void

    @FocusState private var focused: String?

    private static let minute = Theme.px(4)
    private static let rowHeight = Theme.px(56)
    private static let gap = Theme.px(4)
    private static let channelWidth = Theme.px(200)

    private var width: CGFloat { CGFloat(window.end.timeIntervalSince(window.start) / 60) * Self.minute }

    private func x(_ date: Date) -> CGFloat {
        CGFloat(min(max(date.timeIntervalSince(window.start), 0), window.end.timeIntervalSince(window.start)) / 60) * Self.minute
    }

    /// The programme with focus, for the details above the grid.
    private var focusedProgramme: Item? {
        guard let focused else { return nil }
        for list in schedules.values { if let match = list.first(where: { $0.id == focused }) { return match } }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(16)) {
            details
                .frame(height: Theme.px(72), alignment: .topLeading)
                .pagePadding()
            HStack(alignment: .top, spacing: Self.gap) {
                VStack(spacing: Self.gap) {
                    Color.clear.frame(height: Theme.px(28))
                    ForEach(channels) { channel in
                        Button { play(channel) } label: {
                            HStack(spacing: Theme.px(10)) {
                                ChannelLogo(channel: channel)
                                    .frame(width: Theme.px(64), height: Theme.px(36))
                                Text(channel.channelNumber ?? channel.name ?? "")
                                    .font(Theme.font(Theme.sm, .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Theme.px(10))
                            .frame(width: Self.channelWidth, height: Self.rowHeight)
                        }
                        .buttonStyle(RowStyle(radius: Theme.px(8)))
                    }
                }
                .padding(.leading, pageMargin + pageInset)
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: Self.gap) {
                        timeline
                        ForEach(channels) { channel in
                            row(channel)
                        }
                    }
                    .padding(.trailing, pageMargin)
                    .padding(.vertical, Theme.px(4))
                }
                .scrollClipDisabled()
            }
        }
        .focusSection()
    }

    @ViewBuilder private var details: some View {
        if let programme = focusedProgramme {
            VStack(alignment: .leading, spacing: Theme.px(4)) {
                HStack(spacing: Theme.px(10)) {
                    Text(programme.name ?? "").font(Theme.font(Theme.lg, .semibold)).lineLimit(1)
                    if let start = programme.starts, let end = programme.ends {
                        Text("\(prefs.time(start)) – \(prefs.time(end))")
                            .font(Theme.font(Theme.sm))
                            .foregroundStyle(Theme.gray400)
                    }
                    if let channel = programme.channelName {
                        Text(channel).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray400)
                    }
                }
                if let overview = programme.overview {
                    Text(overview).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray300).lineLimit(2)
                }
            }
        } else {
            Text("Choose a programme on now to watch its channel.")
                .font(Theme.font(Theme.sm))
                .foregroundStyle(Theme.gray400)
        }
    }

    /// The half hours across the top, with a line where now is.
    private var timeline: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<12, id: \.self) { index in
                let time = window.start.addingTimeInterval(Double(index) * 1800)
                Text(prefs.time(time))
                    .font(Theme.font(Theme.xs, .medium))
                    .foregroundStyle(Theme.gray400)
                    .offset(x: x(time) + Theme.px(4))
            }
            Rectangle().fill(Theme.ring).frame(width: Theme.px(2), height: Theme.px(28)).offset(x: x(now))
        }
        .frame(width: width, height: Theme.px(28), alignment: .topLeading)
    }

    private struct Segment {
        var id: String
        var width: CGFloat
        var programme: Item?
    }

    /// The row laid out from the left: each programme as wide as its slot, with a space where
    /// the guide has nothing. Laid out rather than offset, so focus moves follow what's drawn.
    private func segments(_ programmes: [Item]) -> [Segment] {
        var list: [Segment] = []
        var cursor: CGFloat = 0
        for programme in programmes {
            let start = max(x(programme.starts ?? window.start), cursor)
            let end = x(programme.ends ?? window.end)
            guard end - start >= Theme.px(4) else { continue }
            if start > cursor { list.append(Segment(id: "gap-\(programme.id)", width: start - cursor)) }
            list.append(Segment(id: programme.id, width: end - start, programme: programme))
            cursor = end
        }
        return list
    }

    private func cell(_ programme: Item, channel: Item, width: CGFloat) -> some View {
        let airing = (programme.starts ?? .distantFuture) <= now && now < (programme.ends ?? .distantPast)
        return Button {
            if airing { play(channel) }
        } label: {
            VStack(alignment: .leading, spacing: Theme.px(2)) {
                Text(programme.name ?? "").font(Theme.font(Theme.sm, .medium)).lineLimit(1)
                if let begins = programme.starts {
                    Text(prefs.time(begins)).font(Theme.font(Theme.xs)).foregroundStyle(Theme.gray400)
                }
            }
            .padding(.horizontal, Theme.px(10))
            .frame(width: max(width - Self.gap, Theme.px(4)), height: Self.rowHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous)
                    .fill(airing ? Theme.brand500.opacity(0.25) : Color.white.opacity(0.05))
            )
        }
        .buttonStyle(RowStyle(radius: Theme.px(8)))
        .focused($focused, equals: programme.id)
        .padding(.trailing, Self.gap)
    }

    private func row(_ channel: Item) -> some View {
        let programmes = (schedules[channel.id] ?? []).filter {
            ($0.ends ?? .distantPast) > window.start && ($0.starts ?? .distantFuture) < window.end
        }
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous)
                .fill(.white.opacity(0.02))
                .frame(width: width, height: Self.rowHeight)
            if programmes.isEmpty {
                Text("No guide for this channel")
                    .font(Theme.font(Theme.sm))
                    .foregroundStyle(Theme.gray500)
                    .padding(.horizontal, Theme.px(12))
                    .frame(height: Self.rowHeight)
            }
            HStack(spacing: 0) {
                ForEach(segments(programmes), id: \.id) { segment in
                    if let programme = segment.programme {
                        cell(programme, channel: channel, width: segment.width)
                    } else {
                        Color.clear.frame(width: segment.width, height: Self.rowHeight)
                    }
                }
            }
        }
        .frame(width: width, height: Self.rowHeight, alignment: .topLeading)
    }
}
