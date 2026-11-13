import SwiftUI

/// The places the rail leads to, in the web app's order (components/layout.tsx).
enum Place: String, CaseIterable, Identifiable {
    case account, home, discover, live, search, favourites, calendar, activity, settings

    var id: String { rawValue }

    static let main: [Place] = [.home, .discover, .live, .search, .favourites, .calendar, .activity]

    /// What the start page setting offers, as the web app's (lib/start-page.ts).
    static let startPages: [Place] = [.home, .discover, .live, .favourites, .calendar, .activity]

    var name: String {
        switch self {
        case .account: return "You"
        case .home: return "Home"
        case .discover: return "Discover"
        case .live: return "Live TV"
        case .search: return "Search"
        case .favourites: return "Favourites"
        case .calendar: return "Calendar"
        case .activity: return "Activity"
        case .settings: return "Settings"
        }
    }

    /// SF Symbols standing in for the web app's BoxIcons.
    var icon: String {
        switch self {
        case .account: return "person.crop.circle"
        case .home: return "house"
        case .discover: return "safari"
        case .live: return "play.tv"
        case .search: return "magnifyingglass"
        case .favourites: return "heart"
        case .calendar: return "calendar"
        case .activity: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

/// The web app's TV layout with its default navigation, the docked rail: icons down the
/// side that open out with names, over a shade, while the rail has focus.
struct MainView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    /// Opens on the start page; Live TV falls back to Home on a server without it.
    @State private var place: Place = Place(rawValue: UserDefaults.standard.string(forKey: "app.startPage") ?? "") ?? .home
    /// The server's Live TV library, which only a server with channels lists.
    @State private var liveView: Item?
    @State private var paths: [Place: NavigationPath] = [:]
    @FocusState private var railFocus: Place?
    /// What a card's menu asked to play, from any page.
    @State private var choice: VersionChoice?
    @Namespace private var railScope
    /// The whole screen, rail and page, which focus is re-picked within after a rail choice.
    @Namespace private var shellScope
    @Environment(\.resetFocus) private var resetFocus
    /// Briefly true after a rail choice, so focus leaves the rail for the page; and at launch,
    /// so the app opens with the rail shut and focus on Home.
    @State private var railLocked = true
    /// A first Back on Home, which a second within a couple of seconds follows to leave.
    @State private var exitArmed = false
    @State private var exitHint: Task<Void, Never>?

    private var open: Bool { railFocus != nil }

    /// Where the shade stops being solid: past the open rail's widest name.
    private static let solidShade = Theme.px(12 + 232 + 32)

    private func path(_ place: Place) -> Binding<NavigationPath> {
        Binding(get: { paths[place] ?? NavigationPath() }, set: { paths[place] = $0 })
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Theme.background.ignoresSafeArea()

            NavigationStack(path: path(place)) {
                page(place)
                    .routes()
                    .toolbar(.hidden, for: .navigationBar)
            }
            .id(place)
            // One area the focus can move into from the rail, wherever on the page it lands.
            .focusSection()
            // The page is where focus goes when the shell picks it again, rather than the rail.
            .prefersDefaultFocus(true, in: shellScope)
            .environment(\.openPlace, { place = $0 })
            .environment(\.openRoute, { route in
                var path = paths[place] ?? NavigationPath()
                path.append(route)
                paths[place] = path
            })
            .environment(\.playItem, { item, mode in
                Task { choice = await playChoice(for: item, session: session, mode: mode) }
            })
            .padding(.leading, Theme.px(80))

            // The rail's own column, which rows scrolled under it disappear beneath.
            Theme.background
                .frame(width: Theme.px(80))
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // The open rail's shade over the page beside it: solid under the names, so the page's
            // own text can't show through them, then fading out across the page.
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: Self.solidShade / Theme.px(576)),
                    .init(color: .black.opacity(0.7), location: 0.75),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: Theme.px(576))
            .opacity(open ? 1 : 0)
            .allowsHitTesting(false)
            .ignoresSafeArea()

            rail
        }
        .ignoresSafeArea()
        .focusScope(shellScope)
        .font(Theme.font(Theme.base))
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.2), value: open)
        .playFlow($choice) { NotificationCenter.default.post(name: .watchStateChanged, object: nil) }
        .task { await findLiveTV() }
        .task {
            await startOnPage()
            guard let client = session.client, let userId = session.userId else { return }
            await prefs.load(client: client, userId: userId)
            await openDemoScreen()
        }
        // Back from another place's first page goes Home; from Home, it leaves the app.
        .onExitCommand(perform: exitAction)
        .overlay(alignment: .bottom) {
            if exitArmed {
                Text("Press Back again to leave")
                    .font(Theme.font(Theme.base, .medium))
                    .padding(.horizontal, Theme.px(20))
                    .padding(.vertical, Theme.px(12))
                    .background(Capsule().fill(Color(white: 17 / 255).opacity(0.95)))
                    .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: Theme.px(1)))
                    .padding(.bottom, Theme.px(40))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: exitArmed)
    }

    @ViewBuilder private func page(_ place: Place) -> some View {
        switch place {
        case .home: HomeView()
        case .discover: LibrariesView()
        case .live:
            if let liveView { LiveTVView(view: liveView) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        case .search: SearchView()
        case .favourites: FavouritesView()
        case .calendar: CalendarView()
        case .activity: ActivityView()
        case .account, .settings: SettingsView()
        }
    }

    /// Shows Live TV in the rail when the server has it, and leaves it when the start page asked
    /// for Live TV on a server without.
    private func findLiveTV() async {
        guard let client = session.client, let userId = session.userId else { return }
        let views: ItemsResult? = try? await client.get("/UserViews", ["userId": userId])
        liveView = views?.items?.first { $0.collectionType == "livetv" }
        if liveView == nil && place == .live { place = .home }
    }

    /// Screenshot mode only: opens the screen the launch asked for.
    private func openDemoScreen() async {
        guard DemoMode.active else { return }
        let item = await DemoMode.item(session)
        switch DemoMode.screen {
        case "rail":
            try? await Task.sleep(for: .seconds(1))
            railFocus = .home
        case "settings":
            place = .settings
        case "title", "movie":
            if let item { paths[.home] = { var path = NavigationPath(); path.append(Route.item(item)); return path }() }
        case "versions":
            if let item { choice = VersionChoice(item: item, startMs: item.resumeMs, mode: .list) }
        case "player":
            if let item { choice = VersionChoice(item: item, startMs: nil, mode: .straight) }
        default:
            break
        }
    }

    /// Keeps the rail shut while Home loads its first rows, then lets it take focus again. Should
    /// focus have landed on the rail before the page had anything to focus, it's moved over.
    private func startOnPage() async {
        for wait in [300, 700, 1000] {
            try? await Task.sleep(for: .milliseconds(wait))
            if railFocus != nil { resetFocus(in: shellScope) }
        }
        railLocked = false
    }

    /// Moves focus from the rail to the page just chosen, so the rail closes without a press right.
    /// Focus is re-picked within the whole screen, where the page is the preferred default; a scope
    /// holding only the page wouldn't take focus from the rail. The rail is off meanwhile, so it
    /// can't be picked again, and a second try covers a page still appearing.
    private func leaveRail() {
        railLocked = true
        Task {
            for wait in [100, 350] {
                try? await Task.sleep(for: .milliseconds(wait))
                guard railFocus != nil else { break }
                resetFocus(in: shellScope)
            }
            try? await Task.sleep(for: .milliseconds(300))
            railLocked = false
        }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: Theme.px(4)) {
            BrandLogo(height: Theme.px(32))
                .frame(width: Theme.px(24), height: Theme.px(32))
                .padding(.horizontal, Theme.px(14))
                .padding(.bottom, Theme.px(24))
            entry(.account)
            Rectangle().fill(.white.opacity(0.1)).frame(height: Theme.px(1))
                .padding(.horizontal, Theme.px(12))
                .padding(.vertical, Theme.px(4))
            ForEach(Place.main.filter { $0 != .live || liveView != nil }) { entry($0) }
            Spacer(minLength: 0)
            entry(.settings)
        }
        .padding(.horizontal, Theme.px(12))
        .padding(.vertical, Theme.px(32))
        // The rail keeps its icons' width when it opens: its names are drawn beside the buttons,
        // not in them, so the page stays to their right and a press right reaches it.
        .frame(width: Theme.px(80), alignment: .leading)
        .frame(maxHeight: .infinity)
        .focusSection()
        .focusScope(railScope)
        // Off for a moment after a choice, which hands focus to the page; and in screenshot mode,
        // where the page takes focus as it does on a real Apple TV.
        .disabled(DemoMode.keepsRailShut || railLocked)
    }

    /// What Back does on a place's first page: from another place, go Home; on Home, leave,
    /// with "Prevent accidental exit" on only at a second press, as the Android TV app asks.
    private var exitAction: (() -> Void)? {
        guard paths[place]?.isEmpty ?? true else { return nil }
        if place != .home { return { place = .home } }
        // Left to the system, Back leaves the app.
        guard prefs.preventAccidentalExit, !exitArmed else { return nil }
        return {
            exitArmed = true
            exitHint?.cancel()
            exitHint = Task {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { exitArmed = false }
            }
        }
    }

    private func entry(_ item: Place) -> some View {
        // You and Settings open the same page; only the one chosen shows as current.
        let current = item == place
        return Button {
            if item == place {
                // Choosing the place you're on goes back to its first page.
                paths[item] = NavigationPath()
            }
            place = item
            leaveRail()
        } label: {
            RailEntry(item: item, current: current, open: open, avatar: avatarURL)
        }
        .buttonStyle(RailButtonStyle())
        .focused($railFocus, equals: item)
        .prefersDefaultFocus(current, in: railScope)
    }

    private var avatarURL: URL? {
        guard let client = session.client, let userId = session.userId else { return nil }
        return client.url("/Users/\(userId)/Images/Primary", ["fillHeight": "96", "quality": "90"])
    }
}

private struct RailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// One rail button: 48 px high and fully rounded, the current place filled, the focused one lighter.
private struct RailEntry: View {
    @Environment(\.isFocused) private var focused
    let item: Place
    let current: Bool
    let open: Bool
    let avatar: URL?

    /// An open entry's pill, icon and name together, as the web app's open rail draws it.
    private static let openWidth = Theme.px(232)
    private static let width = Theme.px(56)

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if item == .account {
                    AsyncImage(url: avatar) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "person.crop.circle.fill").resizable()
                        }
                    }
                    .frame(width: Theme.px(24), height: Theme.px(24))
                    .clipShape(Circle())
                } else {
                    Image(systemName: item.icon)
                        .font(.system(size: Theme.px(20), weight: current ? .semibold : .regular))
                }
            }
            .frame(width: Theme.px(24))
        }
        .padding(.horizontal, Theme.px(16))
        .frame(width: Self.width, height: Theme.px(48), alignment: .leading)
        .foregroundStyle(current || focused ? Color.white : Theme.gray400)
        // Drawn past the button's own frame, which focus moves are measured from. The page you're
        // on is filled; where the remote is gets the app's focus ring, so the two never look alike.
        .background(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(current ? 0.12 : 0))
                .frame(width: open ? Self.openWidth : Self.width, height: Theme.px(48))
                .overlay {
                    if focused {
                        Capsule()
                            .strokeBorder(Theme.ring, lineWidth: Theme.ringWidth)
                            .padding(-(Theme.ringWidth + Theme.ringOffset))
                    }
                }
        }
        .overlay(alignment: .leading) {
            if open {
                Text(item.name)
                    .font(Theme.font(Theme.base, .medium))
                    .foregroundStyle(current || focused ? Color.white : Theme.gray400)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: Theme.px(56))
                    .transition(.opacity)
            }
        }
    }
}

/// A place whose page comes in a later build.
struct ComingSoonView: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(12)) {
            Text(title).font(Theme.font(Theme.xl3, .bold))
            Text(text).font(Theme.font(Theme.base)).foregroundStyle(Theme.gray400)
            Text("Coming in a later build.").font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray500)
        }
        .padding(Theme.px(40))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Keeps focus somewhere on a page with nothing to press.
        .focusable()
    }
}
