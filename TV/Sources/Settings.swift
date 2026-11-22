import AetherEngineFeatures
import CoreImage.CIFilterBuiltins
import SwiftUI

// Settings that follow the user, kept where the web app keeps them: its synced settings in
// Jellyfin's display preferences under the web app's own id and keys (lib/settings.ts), and
// the playback languages and subtitle mode in the user's Jellyfin configuration
// (lib/user-config.ts). A change on the TV shows in the web app on every other device.

@MainActor
final class Preferences: ObservableObject {
    /// The web app's synced settings, by its keys; a default is left out, as it leaves it.
    @Published private(set) var custom: [String: String] = [:]
    /// The user's Jellyfin configuration, sent back whole when it changes.
    @Published private(set) var configuration: [String: Any] = [:]
    @Published private(set) var loaded = false

    static let prefsId = "aiostreams-web"
    private static let savedMark = "saved"

    private var client: JellyfinClient?
    private var userId: String?
    private var pushTask: Task<Void, Never>?

    func load(client: JellyfinClient, userId: String) async {
        self.client = client
        self.userId = userId
        if let prefs = try? await client.json("GET", "/DisplayPreferences/\(Self.prefsId)", ["client": Self.prefsId, "userId": userId]),
           let saved = prefs["CustomPrefs"] as? [String: Any] {
            custom = saved.compactMapValues { $0 as? String }
        }
        Theme.apply(accent: accentColor, background: backgroundColor)
        AppLanguage.apply(text("language", "auto"))
        if let me = try? await client.json("GET", "/Users/Me") {
            configuration = me["Configuration"] as? [String: Any] ?? [:]
        }
        loaded = true
    }

    // MARK: Synced settings

    func text(_ key: String, _ fallback: String) -> String { custom[key] ?? fallback }

    /// Where Live TV shows, as the web app's setting: on home and in the navigation (`home`), in the
    /// navigation only (`nav`), or hidden (`off`), when channels also leave search.
    var liveTv: String { text("liveTv", "home") }

    /// The pages the background from artwork shows behind (the web app's `artBackground`): `item`
    /// for title pages, `browse` for Home, search and catalogs, `other` for the rest. Title pages
    /// where nothing is set; an earlier "1" was everywhere.
    var artPages: [String] {
        let all = ["item", "browse", "other"]
        guard let raw = custom["artBackground"] else { return ["item"] }
        if raw == "1" { return all }
        let parts = raw.split(separator: ",").map(String.init)
        return all.filter(parts.contains)
    }

    func setArtPages(_ pages: [String]) {
        let ordered = ["item", "browse", "other"].filter(pages.contains)
        let value = ordered == ["item"] ? nil : ordered.isEmpty ? "none" : ordered.joined(separator: ",")
        set("artBackground", value, fallback: "")
    }
    func flag(_ key: String, _ fallback: Bool) -> Bool { custom[key].map { $0 == "1" } ?? fallback }
    func number(_ key: String, _ fallback: Double) -> Double { custom[key].flatMap(Double.init) ?? fallback }

    /// Saves a synced setting; the default is stored as nothing, as the web app stores it.
    func set(_ key: String, _ value: String?, fallback: String) {
        if let value, value != fallback { custom[key] = value } else { custom.removeValue(forKey: key) }
        if key == "accentColor" || key == "backgroundColor" { Theme.apply(accent: accentColor, background: backgroundColor) }
        if key == "language" { AppLanguage.apply(text("language", "auto")) }
        // Settles before it saves, as a run of presses would otherwise send each.
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.push()
        }
    }

    private func push() async {
        guard let client, let userId else { return }
        var prefs = custom
        prefs[Self.savedMark] = "1"
        let body: [String: Any] = ["Id": Self.prefsId, "Client": Self.prefsId, "CustomPrefs": prefs]
        do {
            _ = try await client.json("POST", "/DisplayPreferences/\(Self.prefsId)", ["client": Self.prefsId, "userId": userId], body: body)
        } catch {
            AppLog.warn("settings", "could not save: \(error.localizedDescription)")
        }
    }

    // MARK: Jellyfin configuration

    func configured<T>(_ key: String) -> T? { configuration[key] as? T }

    func configure(_ changes: [String: Any]) {
        configuration.merge(changes) { _, new in new }
        guard let client, let userId else { return }
        let body = configuration
        Task {
            do {
                _ = try await client.json("POST", "/Users/Configuration", ["userId": userId], body: body)
            } catch {
                AppLog.warn("settings", "could not save the configuration: \(error.localizedDescription)")
            }
        }
    }

    /// The languages tried in order: the server's list, else Jellyfin's one language.
    func languages(list: String, one: String) -> [String] {
        let all = (configuration[list] as? [String]) ?? []
        if !all.isEmpty { return all }
        return (configuration[one] as? String).map { [$0] } ?? []
    }

    // MARK: What the player uses

    var audioLanguages: [String] {
        languages(list: "AudioLanguages", one: "AudioLanguagePreference").filter { $0 != "OriginalLanguage" }
    }

    var subtitleMode: String { configuration["SubtitleMode"] as? String ?? "Default" }

    /// Subtitles in these languages start on their own, unless the mode keeps them off.
    var subtitleLanguages: [String] {
        guard ["Default", "Always", "Smart"].contains(subtitleMode) else { return [] }
        return languages(list: "SubtitleLanguages", one: "SubtitleLanguagePreference")
    }

    // MARK: Track choice, in the user's configuration as the web app keeps it

    /// The type rankings, where the server keeps them (nil where it doesn't, as the web app hides them then).
    var audioTypes: [AudioKind]? {
        (configuration["AudioTypes"] as? [String]).map { saved in
            let ranked = saved.compactMap(AudioKind.init(rawValue:))
            return ranked + AudioKind.allCases.filter { !ranked.contains($0) }
        }
    }

    var subtitleTypes: [SubtitleKind]? {
        (configuration["SubtitleTypes"] as? [String]).map { saved in
            let ranked = saved.compactMap(SubtitleKind.init(rawValue:))
            return ranked + SubtitleKind.allCases.filter { !ranked.contains($0) }
        }
    }

    var rememberAudio: Bool { configuration["RememberAudioSelections"] as? Bool ?? true }
    var rememberSubtitles: Bool { configuration["RememberSubtitleSelections"] as? Bool ?? true }
    /// The player's subtitle list shows only the user's languages, where the server has the setting.
    var listOnlyMyLanguages: Bool? { configuration["ListPreferredSubtitlesOnly"] as? Bool }

    /// The account's track rules, before a show's pick.
    func trackRules(audioLanguages: [String]? = nil) -> TrackRules {
        TrackRules(
            audioLanguages: audioLanguages ?? self.audioLanguages,
            subtitleLanguages: languages(list: "SubtitleLanguages", one: "SubtitleLanguagePreference"),
            subtitleMode: subtitleMode,
            audioTypes: audioTypes ?? AudioKind.allCases,
            subtitleTypes: subtitleTypes ?? SubtitleKind.allCases,
            playDefaultAudio: configuration["PlayDefaultAudioTrack"] as? Bool ?? true
        )
    }

    // MARK: Sound, kept on this Apple TV (the web app's device settings)

    /// `auto`, `stereo`, `5.1` or `7.1`: what the speakers or receiver take.
    @Published var audioChannels: String = UserDefaults.standard.string(forKey: "audio.channels") ?? "auto" {
        didSet { UserDefaults.standard.set(audioChannels, forKey: "audio.channels") }
    }
    /// Raises the centre channel by this many dB: 0, 3, 6, 9 or 12.
    @Published var dialogueBoost: Int = UserDefaults.standard.integer(forKey: "audio.dialogueBoost") {
        didSet { UserDefaults.standard.set(dialogueBoost, forKey: "audio.dialogueBoost") }
    }
    @Published var nightMode: Bool = UserDefaults.standard.bool(forKey: "audio.nightMode") {
        didSet { UserDefaults.standard.set(nightMode, forKey: "audio.nightMode") }
    }
    /// How fast playback runs while Select is held on the video: 1.5, 2 or 3.
    @Published var holdRate: Double = UserDefaults.standard.object(forKey: "controls.holdRate") as? Double ?? 2 {
        didSet { UserDefaults.standard.set(holdRate, forKey: "controls.holdRate") }
    }
    @Published var seekPreviews: Bool = UserDefaults.standard.object(forKey: "controls.thumbnails") as? Bool ?? true {
        didSet { UserDefaults.standard.set(seekPreviews, forKey: "controls.thumbnails") }
    }

    /// The TV's navigation: `rail`, the docked rail down the side, or `top`, tabs across the top,
    /// as the web app's TV navigation setting offers (kept on this Apple TV).
    @Published var tvNavigation: String = UserDefaults.standard.string(forKey: "interface.tvNavigation") ?? "rail" {
        didSet { UserDefaults.standard.set(tvNavigation, forKey: "interface.tvNavigation") }
    }

    /// Live TV: whether a channel switches the TV to its frame rate, and to its dynamic range, as
    /// films and episodes do with the Apple TV's Match Content on. Off, the TV keeps its mode, and
    /// channels start sooner, without the blank of a mode change.
    @Published var liveMatchFrameRate: Bool = UserDefaults.standard.object(forKey: "live.matchFrameRate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(liveMatchFrameRate, forKey: "live.matchFrameRate") }
    }
    /// HDR10 tone mapping's target, the TV's peak in nits; 0 is off (AetherEngine's videoProcessing).
    @Published var toneMapNits: Int = UserDefaults.standard.integer(forKey: "video.toneMapNits") {
        didSet { UserDefaults.standard.set(toneMapNits, forKey: "video.toneMapNits") }
    }
    /// The Glass settings (the web app's Theme > Glass), kept on this Apple TV.
    @Published var glassSurface: String = UserDefaults.standard.string(forKey: GlassSetting.surfaceKey) ?? "solid" {
        didSet { UserDefaults.standard.set(glassSurface, forKey: GlassSetting.surfaceKey) }
    }
    @Published var glassPanels: Bool = UserDefaults.standard.bool(forKey: GlassSetting.panelsKey) {
        didSet { UserDefaults.standard.set(glassPanels, forKey: GlassSetting.panelsKey) }
    }
    @Published var liveMatchDynamicRange: Bool = UserDefaults.standard.object(forKey: "live.matchDynamicRange") as? Bool ?? true {
        didSet { UserDefaults.standard.set(liveMatchDynamicRange, forKey: "live.matchDynamicRange") }
    }

    /// Milliseconds, -1000 to 1000; positive plays the sound later than the picture.
    @Published var audioDelayMs: Int = UserDefaults.standard.integer(forKey: "audio.delayMs") {
        didSet { UserDefaults.standard.set(audioDelayMs, forKey: "audio.delayMs") }
    }
    /// Milliseconds, -10000 to 10000; positive shows subtitles later. Where a title starts.
    @Published var subtitleDelayMs: Int = UserDefaults.standard.integer(forKey: "subtitle.delayMs") {
        didSet { UserDefaults.standard.set(subtitleDelayMs, forKey: "subtitle.delayMs") }
    }

    /// What the engine shapes the sound with, for these settings.
    var audioShaping: AudioShaping {
        AudioShaping(
            maxChannels: ["stereo": 2, "5.1": 6, "7.1": 8][audioChannels],
            dialogueGainDB: Double(dialogueBoost),
            compressor: nightMode ? .night : nil
        )
    }

    var heroSeconds: Double { number("heroSeconds", 9) }

    // MARK: Interface, under the web app's keys (lib/settings)

    /// Episodes not started show their pictures and names blurred until focused.
    var blurSpoilers: Bool { flag("blurSpoilers", false) }
    /// Search results in one grid, rather than a row each for movies and shows.
    var combineSearch: Bool { flag("combineSearch", false) }
    /// `rotate` through featured titles, or `follow` the focused card (`corner`: compactly).
    var heroMode: String { text("heroMode", "rotate") }
    /// Featured on home: what the hero draws from (`resume`, `next-up`, `view:<library id>`), up to
    /// four; nil for Automatic, empty for none. Stored as the web app stores it: a list, or `none`.
    var featured: [String]? {
        guard let raw = custom["featured"], raw != "auto" else { return nil }
        if raw == "none" { return [] }
        return raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    func setFeatured(_ sources: [String]?) {
        set("featured", sources.map { $0.isEmpty ? "none" : $0.joined(separator: ",") }, fallback: "auto")
    }
    /// `small`, `medium` or `large` posters.
    var posterSize: String { text("posterSize", "medium") }
    /// What shows under a poster: its title, its year, both or `none`.
    var posterLines: Set<String> {
        let raw = text("posterText", "title,year")
        return Set(raw.split(separator: ",").map(String.init).filter { ["title", "year"].contains($0) })
    }
    /// The theme's colours, `#rrggbb`, where the web app's theme set them.
    var accentColor: String? { custom["accentColor"].flatMap { $0.isEmpty ? nil : $0 } }
    var backgroundColor: String? { custom["backgroundColor"].flatMap { $0.isEmpty ? nil : $0 } }
    /// Changes when the theme or the language does, so the app draws itself again in them.
    var themeKey: String {
        "\(accentColor ?? "")|\(backgroundColor ?? "")|\(AppLanguage.resolve(text("language", "auto")))|\(tvNavigation)"
    }

    // MARK: Skipping and the next episode, under the web app's keys (lib/settings)

    /// `ask` offers a button, `skip` skips by itself, `none` leaves it, for Intro, Recap, Outro,
    /// Preview and Commercial.
    func segmentAction(_ type: String) -> String { text("segment\(type)", "ask") }

    /// When the next episode is offered: at the credits (`credits`), near the end (`end`), or `off`.
    var nextPrompt: String { text("nextPrompt", "credits") }
    /// Seconds before the end the offer comes, with no credits to go by.
    var nextLead: Double { number("nextLead", 30) }
    var nextCountdown: Double { number("nextCountdown", 15) }
    /// With no version in the same binge group, play the first rather than list them.
    var nextFallbackFirst: Bool { flag("nextFallbackFirst", true) }
    /// After this many episodes in a row with nobody pressing anything, ask first; 0 never asks.
    var stillWatching: Int { Int(number("stillWatching", 3)) }
    /// Where a file's chapters name an intro, credits, recap or preview, skip by them over the server's times.
    var chapterSkips: Bool { flag("chapterSkips", true) }
    /// Playing on passes over filler and recap episodes the server marks.
    var skipFillers: Bool { flag("skipFillers", true) }
    var skipRecaps: Bool { flag("skipRecaps", true) }
    /// An episode whose air date is still to come isn't played on to.
    var markUnaired: Bool { flag("markUnaired", true) }

    /// The player's own controls, kept on this Apple TV as the web app keeps them on each device.
    @Published var seekStep: Int = UserDefaults.standard.object(forKey: "controls.seekStep") as? Int ?? 10 {
        didSet { UserDefaults.standard.set(seekStep, forKey: "controls.seekStep") }
    }
    /// The time left rather than the whole length beside the position.
    @Published var showTimeLeft: Bool = UserDefaults.standard.bool(forKey: "controls.timeLeft") {
        didSet { UserDefaults.standard.set(showTimeLeft, forKey: "controls.timeLeft") }
    }
    /// The time of day in the player's top corner.
    @Published var showClock: Bool = UserDefaults.standard.object(forKey: "controls.clock") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showClock, forKey: "controls.clock") }
    }

    /// What the player needs of these, read as it starts.
    var playerRules: PlayerRules {
        PlayerRules(chapterSkips: chapterSkips, skipFillers: skipFillers, skipRecaps: skipRecaps, markUnaired: markUnaired)
    }

    /// Jellyfin's own setting, which the web app's switch changes.
    var autoplayNext: Bool { configuration["EnableNextEpisodeAutoPlay"] as? Bool ?? true }

    /// Play starts the first version rather than listing them (the web app's `autoPlayFirst`).
    var autoPlayFirst: Bool { flag("autoPlayFirst", false) }

    /// The speakers TrueHD Atmos and DTS:X are rendered for. Kept on this Apple TV, as it's about
    /// the receiver it's plugged into; nil plays them as their 7.1 channels.
    @Published var speakerChoice: String = UserDefaults.standard.string(forKey: "audio.speakers") ?? SpatialSpeakerLayout.l714.rawValue {
        didSet { UserDefaults.standard.set(speakerChoice, forKey: "audio.speakers") }
    }

    var speakers: SpatialSpeakerLayout? { SpatialSpeakerLayout(rawValue: speakerChoice) }

    /// Back on Home asks for a second press before leaving the app. Kept on this Apple TV.
    @Published var preventAccidentalExit: Bool = UserDefaults.standard.object(forKey: "app.preventAccidentalExit") as? Bool ?? true {
        didSet { UserDefaults.standard.set(preventAccidentalExit, forKey: "app.preventAccidentalExit") }
    }
    /// Underscan: the percent of the screen's width and height left empty on each side, 0 to 6.
    @Published var screenMargin: Int = UserDefaults.standard.integer(forKey: ScreenFit.key) {
        didSet {
            UserDefaults.standard.set(screenMargin, forKey: ScreenFit.key)
            ScreenFit.apply()
        }
    }

    /// Anime upscaling: anime plays through AetherEngine's line-art scaler. Kept on this Apple TV, as
    /// the web app keeps its own (`aiostreams-web-video-upscaling`).
    @Published var animeUpscaling: Bool = UserDefaults.standard.bool(forKey: "video.animeUpscaling") {
        didSet { UserDefaults.standard.set(animeUpscaling, forKey: "video.animeUpscaling") }
    }

    /// Card previews: focus resting on a poster in a row opens it out, with its trailer. Kept on this
    /// Apple TV, as the web app keeps its own on each device, and on by default on a TV as there.
    @Published var cardPreviews: Bool = UserDefaults.standard.object(forKey: "interface.cardPreviews") as? Bool ?? true {
        didSet { UserDefaults.standard.set(cardPreviews, forKey: "interface.cardPreviews") }
    }
    @Published var cardTrailers: Bool = UserDefaults.standard.object(forKey: "interface.cardTrailers") as? Bool ?? true {
        didSet { UserDefaults.standard.set(cardTrailers, forKey: "interface.cardTrailers") }
    }
    @Published var trailerSound: Bool = UserDefaults.standard.object(forKey: "interface.trailerSound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(trailerSound, forKey: "interface.trailerSound") }
    }

    /// Where the app opens, as the web app's start page setting: kept on this Apple TV.
    @Published var startPage: String = UserDefaults.standard.string(forKey: "app.startPage") ?? "home" {
        didSet { UserDefaults.standard.set(startPage, forKey: "app.startPage") }
    }

    /// `auto` follows the Apple TV; `12` or `24` as chosen. Synced, as the web app's `timeFormat`.
    var timeFormat: String { text("timeFormat", "auto") }

    /// A time of day in the chosen format.
    func time(_ date: Date) -> String {
        switch timeFormat {
        case "12":
            Self.twelve.locale = AppLanguage.locale
            return Self.twelve.string(from: date)
        case "24": return Self.twentyFour.string(from: date)
        default: return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: AppLanguage.locale))
        }
    }

    private static let twelve: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private static let twentyFour: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// The web app's subtitle style, in the overlay's units (lib/subtitles/style.ts).
    var subtitleLook: SubtitleLook {
        var look = SubtitleLook()
        look.scale = ["small": 0.8, "normal": 1, "large": 1.25, "huge": 1.5][text("subtitleSize", "normal")] ?? 1
        look.bold = flag("subtitleBold", false)
        look.color = JSON.color(text("subtitleColor", "#ffffff")) ?? .white
        look.outlineColor = JSON.color(text("subtitleOutlineColor", "#000000")) ?? .black
        look.outlineSize = ["none": 0, "thin": 1, "normal": 1.65, "thick": 3][text("subtitleOutline", "normal")] ?? 1.65
        look.shadowSize = flag("subtitleShadow", false) ? 3 : 0
        look.fontFamily = SubtitleLook.family(text("subtitleFont", "default"))
        let opacity = number("subtitleBackgroundOpacity", 0)
        let background = JSON.color(text("subtitleBackgroundColor", "#000000")) ?? .black
        look.backColor = background.withAlphaComponent(opacity / 100)
        look.box = opacity > 0
        look.forceStyle = flag("subtitleOverrideStyled", false)
        look.position = 100 - number("subtitlePosition", 0)
        return look
    }
}

// MARK: - The page

/// A setting's choices, shown in a panel over the page.
private struct Chooser: Identifiable {
    let id = UUID()
    let title: String
    let options: [(label: String, value: String)]
    let current: String
    let choose: (String) -> Void
}

/// Jellyfin's three-letter codes, as its language settings take them, with each language's English
/// name and its two-letter code, for its name in the app's language.
private let languageOptions: [(String, String, String)] = [
    ("eng", "English", "en"), ("spa", "Spanish", "es"), ("fre", "French", "fr"), ("ger", "German", "de"),
    ("ita", "Italian", "it"), ("por", "Portuguese", "pt"), ("dut", "Dutch", "nl"), ("swe", "Swedish", "sv"),
    ("nor", "Norwegian", "no"), ("dan", "Danish", "da"), ("fin", "Finnish", "fi"), ("pol", "Polish", "pl"),
    ("cze", "Czech", "cs"), ("hun", "Hungarian", "hu"), ("rum", "Romanian", "ro"), ("gre", "Greek", "el"),
    ("tur", "Turkish", "tr"), ("rus", "Russian", "ru"), ("ukr", "Ukrainian", "uk"), ("ara", "Arabic", "ar"),
    ("heb", "Hebrew", "he"), ("hin", "Hindi", "hi"), ("tam", "Tamil", "ta"), ("tel", "Telugu", "te"),
    ("tha", "Thai", "th"), ("vie", "Vietnamese", "vi"), ("ind", "Indonesian", "id"), ("may", "Malay", "ms"),
    ("fil", "Filipino", "fil"), ("jpn", "Japanese", "ja"), ("kor", "Korean", "ko"), ("chi", "Chinese", "zh"),
]

/// A language's name: the list's English one in English, else the system's name for it in the
/// app's language, as the web app names them (languageName in lib/languages.ts).
private func languageName(_ code: String) -> String {
    if code == "OriginalLanguage" { return L("Original language") }
    let english = languageOptions.first { $0.0 == code }
    if AppLanguage.current.hasPrefix("en"), let english { return english.1 }
    return AppLanguage.locale.localizedString(forLanguageCode: english?.2 ?? code)
        .map { $0.prefix(1).uppercased(with: AppLanguage.locale) + $0.dropFirst() }
        ?? english?.1 ?? code
}

struct SettingsView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @State private var chooser: Chooser?
    @State private var picker: MultiChooser?
    /// The server lets another device sign in with a code this account approves.
    @State private var quickConnect = false
    @State private var askWho = Session.askWho
    /// Where sending a problem report got to.
    @State private var report: String?
    /// A newer release than this copy, which a sideloaded copy doesn't update to by itself.
    @State private var newer: String?
    @State private var approving = false

    @State private var page: SettingsPage
    @State private var donating = false
    /// The server has Live TV, which its setting only shows with.
    @State private var hasLiveTv = false
    @FocusState private var tab: SettingsPage?

    /// You in the navigation opens Account; Settings opens Playback.
    init(start: SettingsPage = .playback) {
        _page = State(initialValue: start)
    }
    @Namespace private var settingsScope

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(24)) {
            PageTitle(text: L("Settings"))
            HStack(alignment: .top, spacing: Theme.px(32)) {
                tabs
                    .frame(width: Theme.px(260))
                // The page chosen at the side: its heading, then its cards, as the web app's settings.
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.px(28)) {
                        header(page)
                        pageContent(page)
                    }
                    .padding(.trailing, pageMargin)
                    .padding(.bottom, Theme.px(64))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentMargins(.top, Theme.px(8), for: .scrollContent)
                .id(page)
                .focusSection()
            }
            .padding(.leading, pageInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusScope(settingsScope)
        .ignoresSafeArea()
        .task { await loadFeaturedOptions() }
        .task {
            guard let client = session.client, let userId = session.userId else { return }
            let views: ItemsResult? = try? await client.get("/UserViews", ["userId": userId])
            hasLiveTv = views?.items?.contains { $0.collectionType == "livetv" } == true
        }
        .task { if !DemoMode.active { newer = await UpdateCheck.newer() } }
        .task {
            guard let client = session.client else { return }
            let enabled: Bool? = try? await client.get("/QuickConnect/Enabled")
            quickConnect = enabled == true
        }
        .fullScreenCover(isPresented: $approving) {
            QuickConnectApproval { approving = false }
                .environmentObject(session)
                .presentationBackground(.clear)
        }
        .fullScreenCover(item: $chooser) { chooser in
            ChooserPanel(chooser: chooser) { self.chooser = nil }
                .presentationBackground(.clear)
        }
        .fullScreenCover(item: $picker) { picker in
            MultiChooserPanel(chooser: picker) { self.picker = nil }
                .presentationBackground(.clear)
        }
        .fullScreenCover(isPresented: $donating) {
            DonatePanel { donating = false }
                .presentationBackground(.clear)
        }
    }

    @ViewBuilder private func pageContent(_ page: SettingsPage) -> some View {
        switch page {
        case .playback:
            section(L("Versions"), note: L("Saved to your account, so the web app and your other devices use them too.")) {
                toggle(L("Auto-play the first version"), key: "autoPlayFirst", fallback: false)
                toggle(L("Find versions when a title opens"), key: "preloadVersions", fallback: false)
                note(L("Looks for versions as soon as a title's page opens, so Play and the version list don't wait. Each title you open is looked up, even if you don't play it."))
                note(prefs.autoPlayFirst
                    ? L("Play starts the first version, and resuming goes back to the version you were watching. Hold select on a title and choose Choose a version to pick instead.")
                    : L("Play lists the versions to choose from, but resuming goes back to the version you were watching. Hold select on a title and choose Play straight away to start the first."))
            }
            section(L("Skipping and the next episode"), note: L("Shared with the web app. Intros, recaps and credits come from your server, with Skip intro and credits on in its configuration.")) {
                ForEach([("Intro", L("Intros")), ("Recap", L("Recaps")), ("Outro", L("Credits")), ("Preview", L("Previews")), ("Commercial", L("Ads"))], id: \.0) { entry in
                    synced(entry.1, key: "segment\(entry.0)", fallback: "ask",
                           options: [(L("Show a skip button"), "ask"), (L("Skip automatically"), "skip"), (L("Don't skip"), "none")])
                }
                row(L("Play the next episode automatically"), value: prefs.autoplayNext ? L("On") : L("Off")) {
                    prefs.configure(["EnableNextEpisodeAutoPlay": !prefs.autoplayNext])
                }
                synced(L("Offer the next episode"), key: "nextPrompt", fallback: "credits",
                       options: [(L("At the credits"), "credits"), (L("Near the end"), "end"), (L("Never"), "off")])
                synced(L("Without credits, offer it"), key: "nextLead", fallback: "30",
                       options: [15, 30, 45, 60, 90, 120].map { (L("%ld seconds before the end", $0), String($0)) })
                synced(L("Countdown"), key: "nextCountdown", fallback: "15",
                       options: [5, 10, 15, 30].map { (L("%ld seconds", $0), String($0)) })
                toggle(L("Skip by the file's chapters"), key: "chapterSkips", fallback: true)
                toggle(L("Play the first version when none matches"), key: "nextFallbackFirst", fallback: true)
                toggle(L("Skip filler episodes"), key: "skipFillers", fallback: true)
                toggle(L("Skip recap episodes"), key: "skipRecaps", fallback: true)
                toggle(L("Wait for episodes to air"), key: "markUnaired", fallback: true)
                synced(L("Ask if you are still watching"), key: "stillWatching", fallback: "3",
                       options: [(L("Never"), "0")] + [2, 3, 4, 5, 8].map { (L("After %ld episodes", $0), String($0)) })
                note(L("The next episode plays in the version that matches the one you're watching. Where none does, the first plays, or with that off, the versions are listed. Back hides the offer."))
            }
        case .player:
            section(L("Controls"), note: L("Kept on this Apple TV.")) {
                row(L("Skip step"), value: L("%ld seconds", prefs.seekStep)) {
                    chooser = Chooser(title: L("Skip step"), options: [5, 10, 15, 30].map { (L("%ld seconds", $0), String($0)) },
                                      current: String(prefs.seekStep)) { prefs.seekStep = Int($0) ?? 10 }
                }
                row(L("Show time left"), value: prefs.showTimeLeft ? L("On") : L("Off")) { prefs.showTimeLeft.toggle() }
                row(L("Show the clock"), value: prefs.showClock ? L("On") : L("Off")) { prefs.showClock.toggle() }
                row(L("Held speed"), value: L("%@×", rateName(prefs.holdRate))) {
                    chooser = Chooser(title: L("Held speed"), options: [1.5, 2, 3].map { (L("%@×", rateName($0)), String($0)) },
                                      current: String(prefs.holdRate)) { prefs.holdRate = Double($0) ?? 2 }
                }
                note(L("How fast playback runs while you hold Select on the video."))
                row(L("Seek bar previews"), value: prefs.seekPreviews ? L("On") : L("Off")) { prefs.seekPreviews.toggle() }
            }
            section(L("Live TV"), note: L("Kept on this Apple TV. Each works with the Apple TV's own Match Content setting on.")) {
                row(L("Match frame rate"), value: prefs.liveMatchFrameRate ? L("On") : L("Off")) { prefs.liveMatchFrameRate.toggle() }
                row(L("Match dynamic range"), value: prefs.liveMatchDynamicRange ? L("On") : L("Off")) { prefs.liveMatchDynamicRange.toggle() }
                note(L("Off, the TV keeps the mode it's in when a channel starts, so channels start sooner, without the blank of a mode change."))
            }
            section(L("Video"), note: nil) {
                row(L("Anime upscaling"), value: prefs.animeUpscaling ? L("On") : L("Off")) {
                    prefs.animeUpscaling.toggle()
                }
                note(L("Anime up to 1080p is upscaled for your TV with Anime4K's line-art network, for sharper lines. Applies to titles with an anime database id, and only to SDR video. Changes take effect from the next title."))
                row(L("HDR10 tone mapping"), value: nitsName(prefs.toneMapNits)) {
                    chooser = Chooser(title: L("HDR10 tone mapping"),
                                      options: [0, 400, 600, 800, 1000, 1500, 2000].map { (nitsName($0), String($0)) },
                                      current: String(prefs.toneMapNits)) { prefs.toneMapNits = Int($0) ?? 0 }
                }
                note(L("For a TV dimmer than the film: HDR10 brighter than the peak you choose is rolled off by the app, so highlights keep their detail, and the TV is told not to dim it again. Pick your TV's peak brightness. Needs tvOS 26; Dolby Vision, HLG and SDR are left as they are. A title it maps has no Picture in Picture, and Atmos in Dolby Digital Plus plays without its heights."))
            }
        case .audio:
            // The web app's Audio and Subtitles pages: the account's languages and track choice.
            section(nil, note: L("Saved to your account, so the web app and your other devices use them too.")) {
                row(L("Audio language"), value: listLabel(prefs.languages(list: "AudioLanguages", one: "AudioLanguagePreference"), none: L("The file's default"))) {
                    chooseLanguage(L("Audio language"), list: "AudioLanguages", one: "AudioLanguagePreference", original: true)
                }
                if let types = prefs.audioTypes {
                    row(L("Audio types"), value: types.map(\.label).joined(separator: " › ")) {
                        rank(L("Audio types"), types.map { ($0.label, $0.rawValue) }) { prefs.configure(["AudioTypes": $0]) }
                    }
                    note(L("When a version has more than one kind of audio track, the first of these it has plays."))
                }
                configToggle(L("Remember picks per show"), key: "RememberAudioSelections", on: prefs.rememberAudio)
                note(L("An audio track you pick while watching a show sets the language for its other episodes. Picking what the settings above would play forgets it."))
            }
            // Only a build with the height channel components has anything to set here.
            // The web app's Output and Sound cards, kept on this Apple TV.
            section(L("Sound"), note: L("Kept on this Apple TV.")) {
                row(L("Channels"), value: channelName(prefs.audioChannels)) {
                    chooser = Chooser(title: L("Channels"), options: ["auto", "stereo", "5.1", "7.1"].map { (channelName($0), $0) },
                                      current: prefs.audioChannels) { prefs.audioChannels = $0 }
                }
                note(L("What your speakers or receiver take. Surround sound with more is mixed down, with its dialogue kept in."))
                row(L("Dialogue boost"), value: boostName(prefs.dialogueBoost)) {
                    chooser = Chooser(title: L("Dialogue boost"), options: [0, 3, 6, 9, 12].map { (boostName($0), String($0)) },
                                      current: String(prefs.dialogueBoost)) { prefs.dialogueBoost = Int($0) ?? 0 }
                }
                note(L("Raises the centre channel, where surround sound puts dialogue. Not for sound passed through."))
                row(L("Night mode"), value: prefs.nightMode ? L("On") : L("Off")) { prefs.nightMode.toggle() }
                note(L("Evens out loud and quiet scenes, for listening at a low volume. Not for sound passed through."))
                row(L("Delay: %@", delayName(prefs.audioDelayMs)), value: "") {
                    chooser = Chooser(title: L("Delay: %@", delayName(prefs.audioDelayMs)),
                                      options: stride(from: -1000, through: 1000, by: 50).map { (delayName($0), String($0)) },
                                      current: String(prefs.audioDelayMs)) { prefs.audioDelayMs = Int($0) ?? 0 }
                }
                note(L("Below zero plays the sound earlier, as for wireless headphones that lag behind the picture."))
            }
            if AetherEngine.OptionalComponent.trueHDObjectAudio.isBuiltIn || AetherEngine.OptionalComponent.dtsxObjectAudio.isBuiltIn {
                section(L("Atmos and DTS:X"), note: L("TrueHD Atmos and DTS:X play with their height channels, rendered for your speakers and sent to your receiver as Dolby MAT. Needs tvOS 26. DTS:X needs 7.1.4 or 9.1.6.")) {
                    row(L("Atmos and DTS:X speakers"), value: speakerName(prefs.speakerChoice)) {
                        var options: [(label: String, value: String)] = [(label: L("Off: play the 7.1 channels"), value: "off")]
                        for layout in SpatialSpeakerLayout.allCases {
                            options.append((label: speakerName(layout.rawValue), value: layout.rawValue))
                        }
                        chooser = Chooser(title: L("Atmos and DTS:X speakers"), options: options, current: prefs.speakerChoice) {
                            prefs.speakerChoice = $0
                        }
                    }
                }
            }
        case .subtitles:
            section(nil, note: nil) {
                row(L("Subtitle language"), value: listLabel(prefs.languages(list: "SubtitleLanguages", one: "SubtitleLanguagePreference"), none: L("Any"))) {
                    chooseLanguage(L("Subtitle language"), list: "SubtitleLanguages", one: "SubtitleLanguagePreference", original: false)
                }
                row(L("Subtitles"), value: modeName(prefs.subtitleMode)) {
                    chooser = Chooser(
                        title: L("Subtitles"),
                        options: ["Default", "Smart", "Always", "OnlyForced", "None"].map { (modeName($0), $0) },
                        current: prefs.subtitleMode
                    ) { prefs.configure(["SubtitleMode": $0]) }
                }
                if let types = prefs.subtitleTypes {
                    row(L("Subtitle types"), value: types.map(\.label).joined(separator: " › ")) {
                        rank(L("Subtitle types"), types.map { ($0.label, $0.rawValue) }) { prefs.configure(["SubtitleTypes": $0]) }
                    }
                    note(L("When a version has more than one subtitle in your language, the first of these it has shows. Commentary comes last."))
                }
                if let only = prefs.listOnlyMyLanguages {
                    configToggle(L("List only my languages"), key: "ListPreferredSubtitlesOnly", on: only)
                    note(L("The player's subtitle menu lists subtitles in your languages, ones without a language and the one on. The rest wait under More languages."))
                }
                configToggle(L("Remember picks per show"), key: "RememberSubtitleSelections", on: prefs.rememberSubtitles)
                note(L("Subtitles you pick or turn off while watching a show stay that way for its other episodes. Picking what the settings above would show forgets it."))
                row(L("Delay: %@", secondsName(prefs.subtitleDelayMs)), value: "") {
                    chooser = Chooser(title: L("Delay: %@", secondsName(prefs.subtitleDelayMs)),
                                      options: stride(from: -10000, through: 10000, by: 100).map { (secondsName($0), String($0)) },
                                      current: String(prefs.subtitleDelayMs)) { prefs.subtitleDelayMs = Int($0) ?? 0 }
                }
                note(L("Where every title's subtitles start. Below zero shows them earlier. The player's Timing panel still moves them while you watch."))
            }
            section(L("Subtitle style"), note: L("The same style as the web app's, on every device you sign in to.")) {
                synced(L("Size"), key: "subtitleSize", fallback: "normal",
                       options: [(L("Small"), "small"), (L("Normal"), "normal"), (L("Large"), "large"), (L("Huge"), "huge")])
                synced(L("Font"), key: "subtitleFont", fallback: "default",
                       options: [(L("The player's own"), "default"), (L("Sans serif"), "sans-serif"), (L("Serif"), "serif"),
                                 (L("Monospace"), "monospace"), (L("Casual"), "casual"), (L("Cursive"), "cursive")])
                synced(L("Text colour"), key: "subtitleColor", fallback: "#ffffff",
                       options: [(L("White"), "#ffffff"), (L("Yellow"), "#ffff00"), (L("Light grey"), "#d1d1d1"),
                                 (L("Cyan"), "#00ffff"), (L("Green"), "#00ff00")])
                toggle(L("Bold"), key: "subtitleBold", fallback: false)
                synced(L("Outline"), key: "subtitleOutline", fallback: "normal",
                       options: [(L("None"), "none"), (L("Thin"), "thin"), (L("Normal"), "normal"), (L("Thick"), "thick")])
                synced(L("Outline colour"), key: "subtitleOutlineColor", fallback: "#000000", options: subtitleColours)
                toggle(L("Shadow"), key: "subtitleShadow", fallback: false)
                synced(L("Background"), key: "subtitleBackgroundOpacity", fallback: "0",
                       options: [(L("None"), "0"), (L("Faint"), "25"), (L("Half"), "50"), (L("Strong"), "75"), (L("Solid"), "100")])
                if prefs.number("subtitleBackgroundOpacity", 0) > 0 {
                    synced(L("Background colour"), key: "subtitleBackgroundColor", fallback: "#000000", options: subtitleColours)
                }
                synced(L("Height"), key: "subtitlePosition", fallback: "0",
                       options: [(L("Lowest"), "-3"), (L("Normal"), "0"), (L("Raised a little"), "5"), (L("Raised"), "10"), (L("High"), "20")])
                toggle(L("Override styled subtitles"), key: "subtitleOverrideStyled", fallback: false)
                SubtitlePreview(look: prefs.subtitleLook)
                    .frame(width: Theme.px(480), height: Theme.px(270))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.px(12), style: .continuous))
                    .padding(Theme.px(12))
            }
        case .interface:
            section(L("Navigation"), note: L("Kept on this Apple TV.")) {
                row(L("Navigation"), value: prefs.tvNavigation == "top" ? L("Top bar") : L("Rail")) {
                    chooser = Chooser(title: L("Navigation"), options: [(L("Rail"), "rail"), (L("Top bar"), "top")],
                                      current: prefs.tvNavigation) { prefs.tvNavigation = $0 }
                }
                row(L("Start page"), value: Place(rawValue: prefs.startPage)?.name ?? Place.home.name) {
                    chooser = Chooser(
                        title: L("Start page"),
                        options: Place.startPages.map { ($0.name, $0.rawValue) },
                        current: prefs.startPage
                    ) { prefs.startPage = $0 }
                }
                row(L("Prevent accidental exit"), value: prefs.preventAccidentalExit ? L("On") : L("Off")) {
                    prefs.preventAccidentalExit.toggle()
                }
                note(prefs.preventAccidentalExit
                    ? L("Back on Home shows “Press Back again to leave”, and only a second press leaves the app.")
                    : L("Back on Home leaves the app straight away."))
                row(L("Screen margins"), value: prefs.screenMargin == 0 ? L("Off") : "\(prefs.screenMargin)%") {
                    chooser = Chooser(title: L("Screen margins"),
                                      options: (0...6).map { ($0 == 0 ? L("Off") : "\($0)%", String($0)) },
                                      current: String(prefs.screenMargin)) { prefs.screenMargin = Int($0) ?? 0 }
                }
                note(L("Shrinks the whole app towards the middle of the screen, for TVs and projectors that cut off its edges."))
            }
            // The web app's Language card: its language and clock, synced.
            section(L("Language"), note: L("Titles, synopses and version names stay in the language the server sends.")) {
                synced(L("App language"), key: "language", fallback: "auto",
                       options: [(L("System (%@)", AppLanguage.name(AppLanguage.system)), "auto")]
                           + AppLanguage.catalogues.map { (AppLanguage.name($0.id), $0.id) }
                               .sorted { $0.0.localizedCompare($1.0) == .orderedAscending })
                synced(L("Time format"), key: "timeFormat", fallback: "auto",
                       options: [(L("Automatic"), "auto"), (L("12-hour"), "12"), (L("24-hour"), "24")])
            }
        case .browsing:
            section(L("Home"), note: L("Shared with the web app.")) {
                row(L("Featured on home"), value: featuredLabel) { chooseFeatured() }
                synced(L("Hero"), key: "heroMode", fallback: "rotate",
                       options: [(L("Rotates through featured titles"), "rotate"), (L("Follows the selected card"), "follow"),
                                 (L("Follows the selected card, compact"), "corner")])
                synced(L("Hero turns every"), key: "heroSeconds", fallback: "9",
                       options: [5, 7, 9, 12, 15, 20, 30].map { (L("%ld seconds", $0), String($0)) })
                toggle(L("Merge continue watching and next up"), key: "mergeNextUp", fallback: false)
                if hasLiveTv {
                    synced(L("Live TV"), key: "liveTv", fallback: "home",
                           options: [(L("On home and in the navigation"), "home"), (L("In the navigation only"), "nav"),
                                     (L("Hidden"), "off")])
                    note(L("Hidden, channels also leave search and favourites."))
                }
            }
            section(L("Posters and grids"), note: nil) {
                synced(L("Poster size"), key: "posterSize", fallback: "medium",
                       options: [(L("Small"), "small"), (L("Medium"), "medium"), (L("Large"), "large")])
                synced(L("Poster text"), key: "posterText", fallback: "title,year",
                       options: [(L("Title and year"), "title,year"), (L("Title"), "title"), (L("Year"), "year"), (L("None"), "none")])
                toggle(L("Combine movie and show results"), key: "combineSearch", fallback: false)
                row(L("Card previews"), value: prefs.cardPreviews ? L("On") : L("Off")) { prefs.cardPreviews.toggle() }
                if prefs.cardPreviews {
                    row(L("Trailers in card previews"), value: prefs.cardTrailers ? L("On") : L("Off")) { prefs.cardTrailers.toggle() }
                    row(L("Trailer sound"), value: prefs.trailerSound ? L("On") : L("Off")) { prefs.trailerSound.toggle() }
                }
            }
            section(L("Episodes"), note: nil) {
                toggle(L("Blur episodes you haven't started"), key: "blurSpoilers", fallback: false)
            }
        case .theme:
            section(nil, note: L("Shared with the web app.")) {
                synced(L("Accent colour"), key: "accentColor", fallback: "",
                       options: [(L("Default"), ""), (L("Blue"), "#3b82f6"), (L("Sky"), "#0ea5e9"), (L("Teal"), "#14b8a6"),
                                 (L("Green"), "#22c55e"), (L("Amber"), "#f59e0b"), (L("Orange"), "#f97316"), (L("Red"), "#ef4444"),
                                 (L("Pink"), "#ec4899"), (L("Violet"), "#8b5cf6")])
                row(L("Background from artwork"), value: artPagesLabel) {
                    picker = MultiChooser(
                        title: L("Background from artwork"),
                        note: L("The artwork of the title you're on, blurred and darkened, behind these pages. The version list shows it with title pages."),
                        options: Self.artPageOptions,
                        chosen: prefs.artPages
                    ) { prefs.setArtPages($0) }
                }
                synced(L("Background"), key: "backgroundColor", fallback: "",
                       options: [(L("Default"), ""), (L("Black"), "#000000"), (L("Charcoal"), "#1c1c1f"), (L("Slate"), "#1e2836"),
                                 (L("Navy"), "#0a1846"), (L("Plum"), "#24102e"), (L("Forest"), "#0c2018"), (L("Maroon"), "#2a0c12")])
            }
            section(L("Glass"), note: L("Kept on this Apple TV.")) {
                row(L("Glass surface"), value: glassName(prefs.glassSurface == "liquid" && !GlassSetting.canRefract ? "frosted" : prefs.glassSurface)) {
                    chooser = Chooser(
                        title: L("Glass surface"),
                        options: (["solid", "frosted"] + (GlassSetting.canRefract ? ["liquid"] : [])).map { (glassName($0), $0) },
                        current: prefs.glassSurface
                    ) { prefs.glassSurface = $0 }
                }
                note(L("What the navigation, and glass panels over the artwork, sit on: the app's own colour, or glass that shows the page through it. Liquid glass also bends what's behind the navigation's edges, which costs more on a slow device."))
                if !prefs.artPages.isEmpty && prefs.glassSurface != "solid" {
                    row(L("Glass panels"), value: prefs.glassPanels ? L("On") : L("Off")) { prefs.glassPanels.toggle() }
                    note(L("Menus, lists, fields and cards over the artwork sit on the glass surface instead of its colour. Slower devices can feel the extra drawing."))
                }
            }
        case .account:
            section(nil, note: nil) {
                fact(L("Server"), session.serverName ?? session.client?.base.host ?? "")
                fact(L("Signed in as"), session.userName ?? "")
                if quickConnect {
                    row(L("Approve a Quick Connect code"), value: "") { approving = true }
                }
                row(L("Ask when the app opens"), value: askWho ? L("On") : L("Off")) {
                    askWho.toggle()
                    Session.askWho = askWho
                }
                note(L("Also when you come back to it after half an hour. Whoever was watching carries on without their PIN."))
                HStack(spacing: Theme.px(8)) {
                    Button(L("Switch user")) { session.signOut() }.buttonStyle(SoftPillStyle())
                    Button(L("Change server")) { session.forgetServer() }.buttonStyle(SoftPillStyle())
                }
                .padding(.top, Theme.px(4))
            }
        case .about:
            section(nil, note: nil) {
                fact(L("App"), "AIOStreams tvOS \(AppInfo.version)")
                if let newer {
                    fact(L("Update"), L("Version %@ is out. Install it the way you installed this copy.", newer))
                }
                fact(L("Player"), AppInfo.player)
                row(L("Report a problem"), value: report ?? "") { Task { await sendReport() } }
                note(L("Sends this Apple TV's details and the app's recent log to your server, where whoever runs it finds them among its logs. Passwords and tokens are left out."))
                note(L("An unofficial app, not affiliated with AIOStreams or AetherEngine. AGPL-3.0; AetherEngine is LGPL-3.0, FFmpeg LGPL-2.1+, libdovi and Anime4K (Copyright (c) 2019-2021 bloc97) MIT, and the Inter font is under the SIL Open Font License."))
            }
            // The web app's About links, each as a code to scan, as a TV opens no web pages.
            section(nil, note: nil) {
                LinkRow(name: L("Source code"), help: L("Where the app is made, and where to report a problem."),
                        url: "https://github.com/wizaarddlabs/aiostreams-ios")
                LinkRow(name: L("Documentation"), help: L("How to use the app and what each setting does."),
                        url: "https://aiostreams.org/apps")
            }
        }
    }

    // MARK: Tabs and cards, as the web app's settings (app/settings)

    /// The pages down the side, in the web app's two cards, Watching and App. Moving onto one opens it.
    private var tabs: some View {
        VStack(alignment: .leading, spacing: Theme.px(12)) {
            tabGroup(L("Watching"), SettingsPage.allCases.filter { $0.group == 0 })
            tabGroup(L("Look and feel"), SettingsPage.allCases.filter { $0.group == 1 })
            tabGroup(L("App"), SettingsPage.allCases.filter { $0.group == 2 })
            // As the web app's, below the tabs: its links, here as codes to scan.
            Button { donating = true } label: {
                Label(L("Donate"), systemImage: "heart")
                    .font(Theme.font(Theme.sm, .medium))
            }
            .buttonStyle(SoftPillStyle())
            .frame(maxWidth: .infinity)
        }
        .focusSection()
        .onChange(of: tab) { _, focused in if let focused { page = focused } }
    }

    private func tabGroup(_ title: String, _ pages: [SettingsPage]) -> some View {
        VStack(alignment: .leading, spacing: Theme.px(2)) {
            Text(title.uppercased(with: AppLanguage.locale))
                .font(Theme.font(Theme.xs, .semibold))
                .tracking(Theme.px(1))
                .foregroundStyle(Theme.gray400)
                .padding(.horizontal, Theme.px(12))
                .padding(.vertical, Theme.px(4))
            ForEach(pages) { item in
                Button { page = item } label: {
                    HStack(spacing: Theme.px(12)) {
                        Image(systemName: item.icon)
                            .font(.system(size: Theme.px(18)))
                            .frame(width: Theme.px(24))
                        Text(item.name).font(Theme.font(Theme.base, .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.px(12))
                    .frame(height: Theme.px(44))
                }
                .buttonStyle(SettingsTabStyle(selected: item == page))
                .focused($tab, equals: item)
                .prefersDefaultFocus(item == page, in: settingsScope)
            }
        }
        .padding(Theme.px(8))
        .background(SettingsCardShape())
    }

    /// The page's icon, name and what it holds, above its cards.
    private func header(_ page: SettingsPage) -> some View {
        HStack(spacing: Theme.px(12)) {
            Image(systemName: page.icon)
                .font(.system(size: Theme.px(24)))
                .foregroundStyle(Theme.ring)
                .frame(width: Theme.px(28), height: Theme.px(28))
                .padding(Theme.px(10))
                .background(
                    RoundedRectangle(cornerRadius: Theme.px(10), style: .continuous)
                        .fill(LinearGradient(colors: [Theme.brand500.opacity(0.1), Color.purple.opacity(0.1)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(RoundedRectangle(cornerRadius: Theme.px(10), style: .continuous)
                            .stroke(Theme.brand500.opacity(0.15), lineWidth: Theme.px(1)))
                )
            VStack(alignment: .leading, spacing: Theme.px(2)) {
                Text(page.name).font(Theme.font(Theme.xl, .semibold))
                Text(page.detail).font(Theme.font(Theme.base)).foregroundStyle(Theme.gray400)
            }
        }
    }

    /// A card: its title and note above, its rows inside with a line between each, a note kept
    /// with the row before it.
    private func section<Content: View>(_ title: String?, note: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.px(12)) {
            if title != nil || note != nil {
                VStack(alignment: .leading, spacing: Theme.px(2)) {
                    if let title { Text(title).font(Theme.font(Theme.base, .semibold)) }
                    if let note { Text(note).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray400) }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content()) { subviews in
                    ForEach(subviews.indices, id: \.self) { index in
                        if index > 0 && !subviews[index].containerValues.settingsNote {
                            Rectangle()
                                .fill(Color(white: 55 / 255).opacity(0.4))
                                .frame(height: Theme.px(2))
                        }
                        subviews[index]
                    }
                }
            }
            .padding(Theme.px(4))
            .background(SettingsCardShape())
        }
        .focusSection()
    }

    private func row(_ title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.px(16)) {
                Text(title).font(Theme.font(Theme.base, .medium))
                Spacer(minLength: Theme.px(16))
                Text(value).font(Theme.font(Theme.base)).foregroundStyle(Theme.gray400).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: Theme.px(12), weight: .semibold)).foregroundStyle(Theme.gray500)
            }
            .padding(.horizontal, Theme.px(12))
            .frame(minHeight: Theme.px(52))
        }
        .buttonStyle(RowStyle(radius: Theme.px(10)))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: Theme.px(16)) {
            Text(label).font(Theme.font(Theme.base, .semibold))
            Spacer(minLength: Theme.px(16))
            Text(value).font(Theme.font(Theme.base)).foregroundStyle(Theme.gray300).lineLimit(1)
        }
        .padding(.horizontal, Theme.px(12))
        .frame(minHeight: Theme.px(52))
    }

    private func synced(_ title: String, key: String, fallback: String, options: [(String, String)]) -> some View {
        let current = prefs.text(key, fallback)
        return row(title, value: options.first { $0.1 == current }?.0 ?? current) {
            chooser = Chooser(title: title, options: options.map { ($0.0, $0.1) }, current: current) {
                prefs.set(key, $0, fallback: fallback)
            }
        }
    }

    private func toggle(_ title: String, key: String, fallback: Bool) -> some View {
        let on = prefs.flag(key, fallback)
        return row(title, value: on ? L("On") : L("Off")) {
            prefs.set(key, on ? "0" : "1", fallback: fallback ? "1" : "0")
        }
    }

    private func listLabel(_ codes: [String], none: String) -> String {
        codes.isEmpty ? none : codes.map(languageName).joined(separator: ", ")
    }

    /// Puts the chosen language first, keeping the others the web app may have listed after it.
    private func chooseLanguage(_ title: String, list: String, one: String, original: Bool) {
        let current = prefs.languages(list: list, one: one)
        var options: [(label: String, value: String)] = [(original ? L("The file's default") : L("Any"), "")]
        if original { options.append((L("Original language"), "OriginalLanguage")) }
        options += languageOptions.map { (languageName($0.0), $0.0) }
        chooser = Chooser(title: title, options: options, current: current.first ?? "") { code in
            if code.isEmpty {
                prefs.configure([list: [String](), one: NSNull()])
            } else {
                let next = [code] + current.filter { $0 != code }
                prefs.configure([list: next, one: code])
            }
        }
    }

    // MARK: Problem report

    /// The app's details and recent log, as a client log on the server (Jellyfin's client log upload).
    private func sendReport() async {
        guard let client = session.client else { return }
        report = L("Sending…")
        let text = [
            "App: AIOStreams tvOS \(AppInfo.version)",
            "Device: \(AppInfo.deviceModel), tvOS \(UIDevice.current.systemVersion)",
            "Server: \(session.serverName ?? "?")\(session.isStock ? " (Jellyfin)" : " (AIOStreams)")",
            "Engine: \(AppInfo.player)",
            "Language: \(AppLanguage.current)",
            "",
            AppLog.recent,
        ].joined(separator: "\n")
        do {
            let answer = try await client.postText("/ClientLog/Document", text)
            report = L("Sent as %@", answer["FileName"] as? String ?? "?")
        } catch {
            report = error.localizedDescription
        }
    }

    // MARK: Featured on home

    /// The libraries the hero can draw from, with Continue watching and Next up.
    @State private var featuredOptions: [(label: String, value: String)] = []

    private var featuredLabel: String {
        guard let featured = prefs.featured else { return L("Automatic") }
        if featured.isEmpty { return L("None") }
        return featured.map { source in featuredOptions.first { $0.value == source }?.label ?? source }
            .joined(separator: ", ")
    }

    private func chooseFeatured() {
        picker = MultiChooser(
            title: L("Featured on home"),
            note: L("Up to %@, mixed together. Left empty, your first movie and show libraries are featured.", "4"),
            options: featuredOptions,
            chosen: prefs.featured ?? [],
            limit: 4
        ) { chosen in prefs.setFeatured(chosen.isEmpty ? nil : chosen) }
    }

    private func loadFeaturedOptions() async {
        guard let client = session.client, let userId = session.userId else { return }
        let views: ItemsResult? = try? await client.get("/UserViews", ["userId": userId])
        featuredOptions = [(L("Continue watching"), "resume"), (L("Next up"), "next-up")]
            + (views?.items ?? []).filter(isBrowsable).map { ($0.name ?? L("Library"), "view:\($0.id)") }
    }

    /// Help under the row before it, in the same card, with no line between.
    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(Theme.sm))
            .foregroundStyle(Theme.gray400)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.px(12))
            .padding(.bottom, Theme.px(12))
            .containerValue(\.settingsNote, true)
    }

    /// A switch in the user's Jellyfin configuration, which the web app shares.
    private func configToggle(_ title: String, key: String, on: Bool) -> some View {
        row(title, value: on ? L("On") : L("Off")) { prefs.configure([key: !on]) }
    }

    /// An order to pick from: the one chosen goes first, the rest keep theirs.
    private func rank(_ title: String, _ items: [(label: String, value: String)], save: @escaping ([String]) -> Void) {
        chooser = Chooser(
            title: title,
            options: items.enumerated().map { ("\($0.offset + 1). \($0.element.label)", $0.element.value) },
            current: items.first?.value ?? ""
        ) { first in save([first] + items.map(\.value).filter { $0 != first }) }
    }

    private var subtitleColours: [(String, String)] {
        [(L("Black"), "#000000"), (L("White"), "#ffffff"), (L("Light grey"), "#d1d1d1"), (L("Yellow"), "#ffff00"),
         (L("Cyan"), "#00ffff"), (L("Green"), "#00ff00")]
    }

    private func channelName(_ value: String) -> String {
        ["stereo": L("Stereo"), "5.1": L("5.1 surround"), "7.1": L("7.1 surround")][value] ?? L("Automatic")
    }

    private func rateName(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...1)).locale(AppLanguage.locale))
    }

    static var artPageOptions: [(label: String, value: String)] {
        [(L("Title pages"), "item"), (L("Home, search and catalogs"), "browse"), (L("Other pages, such as settings"), "other")]
    }

    private var artPagesLabel: String {
        let pages = prefs.artPages
        if pages.isEmpty { return L("Nowhere") }
        return Self.artPageOptions.filter { pages.contains($0.value) }.map(\.label).joined(separator: ", ")
    }

    private func glassName(_ value: String) -> String {
        switch value {
        case "frosted": return L("Frosted glass")
        case "liquid": return L("Liquid glass")
        default: return L("Solid")
        }
    }

    private func nitsName(_ nits: Int) -> String { nits == 0 ? L("Off") : L("%@ nits", String(nits)) }

    private func boostName(_ db: Int) -> String { db == 0 ? L("Off") : L("+%@ dB", String(db)) }

    private func secondsName(_ ms: Int) -> String {
        ms == 0 ? L("In sync") : String(format: "%+.1f s", Double(ms) / 1000)
    }

    private func delayName(_ ms: Int) -> String {
        ms == 0 ? L("In sync") : ms > 0 ? L("+%@ ms", String(ms)) : L("−%@ ms", String(-ms))
    }

    private func speakerName(_ value: String) -> String {
        value == "off" ? L("Off") : value == SpatialSpeakerLayout.l714.rawValue ? L("%@ (most Atmos setups)", value) : value
    }

    private func modeName(_ mode: String) -> String {
        switch mode {
        case "Smart": return L("Smart: when the audio isn't in your language")
        case "Always": return L("Always")
        case "OnlyForced": return L("Only forced")
        case "None": return L("Off")
        default: return L("Default")
        }
    }
}

/// The settings' pages, as the web app's settings tabs, in its Watching and App groups.
enum SettingsPage: String, CaseIterable, Identifiable {
    case playback, player, audio, subtitles, interface, browsing, theme, account, about

    var id: String { rawValue }
    /// The web app's groups: Watching, Look and feel, App.
    var group: Int {
        switch self {
        case .playback, .player, .audio, .subtitles: return 0
        case .interface, .browsing, .theme: return 1
        case .account, .about: return 2
        }
    }

    var name: String {
        switch self {
        case .playback: return L("Playback")
        case .player: return L("Player")
        case .audio: return L("Audio")
        case .subtitles: return L("Subtitles")
        case .interface: return L("Interface")
        case .browsing: return L("Browsing")
        case .theme: return L("Theme")
        case .account: return L("Account")
        case .about: return L("About")
        }
    }

    var detail: String {
        switch self {
        case .playback: return L("Versions, next episode and skipping")
        case .player: return L("The player, its controls and video")
        case .audio: return L("Language and output")
        case .subtitles: return L("Language and how subtitles look")
        case .interface: return L("Language and navigation")
        case .browsing: return L("Home, posters, trailers and episodes")
        case .theme: return L("Colours and background")
        case .account: return L("Who you are signed in as")
        case .about: return L("Versions and links")
        }
    }

    var icon: String {
        switch self {
        case .playback: return "play.circle"
        case .player: return "play.rectangle"
        case .audio: return "speaker.wave.2"
        case .subtitles: return "captions.bubble"
        case .interface: return "square.grid.2x2"
        case .browsing: return "rectangle.stack"
        case .theme: return "paintpalette"
        case .account: return "person"
        case .about: return "info.circle"
        }
    }
}

extension ContainerValues {
    /// A card's help line, which keeps to the row before it without a line between.
    @Entry var settingsNote: Bool = false
}

/// The web app's settings card: nearly black, with a faint edge.
private struct SettingsCardShape: View {
    var body: some View {
        GlassBackground(shape: RoundedRectangle(cornerRadius: Theme.px(14), style: .continuous),
                        fill: Color(red: 3 / 255, green: 7 / 255, blue: 18 / 255).opacity(0.7), panel: true)
            .overlay(RoundedRectangle(cornerRadius: Theme.px(14), style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: Theme.px(1)))
    }
}

/// A tab down the side: the open one filled, the focused one lighter, as the web app's on a TV.
private struct SettingsTabStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Focused { focused in
            configuration.label
                .foregroundStyle(selected || focused ? Color.white : Theme.gray300)
                .background(
                    RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous)
                        .fill(Color.white.opacity(focused ? 0.2 : selected ? 0.1 : 0))
                )
                .opacity(configuration.isPressed ? 0.8 : 1)
        }
    }
}

/// A link as a code to scan with a phone, with its address beside it, since a TV opens no web pages.
enum QRCode {
    static func image(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct QRCodeView: View {
    let url: String
    var size: CGFloat = Theme.px(112)

    var body: some View {
        Group {
            if let image = QRCode.image(url) {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .padding(Theme.px(8))
        .background(RoundedRectangle(cornerRadius: Theme.px(10), style: .continuous).fill(.white))
    }
}

/// One of About's links: its name, what it's for and its address, with a code to scan. It takes
/// focus, so the page scrolls to it, though there's nothing to open.
private struct LinkRow: View {
    let name: String
    let help: String
    let url: String

    var body: some View {
        Button {} label: {
            HStack(spacing: Theme.px(16)) {
                VStack(alignment: .leading, spacing: Theme.px(4)) {
                    Text(name).font(Theme.font(Theme.base, .semibold))
                    Text(help).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray400)
                    Text(verbatim: url).font(Theme.font(Theme.xs)).foregroundStyle(Theme.gray500)
                }
                Spacer(minLength: Theme.px(16))
                QRCodeView(url: url, size: Theme.px(88))
            }
            .padding(Theme.px(12))
        }
        .buttonStyle(RowStyle(radius: Theme.px(10)))
    }
}

/// The web app's Donate, for AIOStreams' developer: GitHub Sponsors and Ko-fi as codes to scan.
private struct DonatePanel: View {
    let done: () -> Void
    private static let links = [("GitHub Sponsors", "https://github.com/sponsors/Viren070"), ("Ko-fi", "https://ko-fi.com/Viren070")]

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: Theme.px(24)) {
                Text(L("Donate")).font(Theme.font(Theme.xl, .semibold))
                HStack(spacing: Theme.px(48)) {
                    ForEach(Self.links, id: \.0) { link in
                        VStack(spacing: Theme.px(10)) {
                            QRCodeView(url: link.1, size: Theme.px(160))
                            Text(verbatim: link.0).font(Theme.font(Theme.base, .semibold))
                            Text(verbatim: link.1).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray400)
                        }
                    }
                }
                Button(L("Close"), action: done).buttonStyle(SoftPillStyle())
            }
            .padding(Theme.px(40))
            .background(SettingsCardShape())
        }
        .onExitCommand(perform: done)
    }
}

/// A line of subtitle in the chosen style, over a dark picture.
private struct SubtitlePreview: UIViewRepresentable {
    let look: SubtitleLook

    func makeUIView(context: Context) -> SubtitleOverlayView {
        let view = SubtitleOverlayView()
        view.backgroundColor = UIColor(white: 0.12, alpha: 1)
        view.setCues([SubtitleCuePreview.cue])
        view.setTime(1)
        return view
    }

    func updateUIView(_ view: SubtitleOverlayView, context: Context) {
        view.look = look
    }
}

/// The preview's one line, showing for as long as the preview does.
private enum SubtitleCuePreview {
    static let cue = SubtitleCue(id: 0, startTime: 0, endTime: .greatestFiniteMagnitude, body: .text(L("This is how subtitles will look.")))
}

/// A setting that takes several choices, in the order they're picked, up to a limit.
struct MultiChooser: Identifiable {
    let id = UUID()
    let title: String
    var note: String?
    let options: [(label: String, value: String)]
    let chosen: [String]
    var limit = Int.max
    let choose: ([String]) -> Void
}

/// Choices that each turn on and off, saved as they change; Back closes it.
struct MultiChooserPanel: View {
    let chooser: MultiChooser
    let done: () -> Void
    @State private var chosen: [String] = []
    @FocusState private var focused: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(alignment: .leading, spacing: Theme.px(12)) {
                Text(chooser.title).font(Theme.font(Theme.xl, .semibold)).padding(.horizontal, Theme.px(8))
                if let note = chooser.note {
                    Text(note).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray400).padding(.horizontal, Theme.px(8))
                }
                ScrollView {
                    VStack(spacing: Theme.px(4)) {
                        ForEach(chooser.options, id: \.value) { option in
                            let on = chosen.contains(option.value)
                            Button {
                                if on {
                                    chosen.removeAll { $0 == option.value }
                                } else if chosen.count < chooser.limit {
                                    chosen.append(option.value)
                                }
                                chooser.choose(chosen)
                            } label: {
                                HStack(spacing: Theme.px(10)) {
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: Theme.px(16), weight: .semibold))
                                        .foregroundStyle(on ? Theme.ring : Theme.gray500)
                                    Text(option.label).font(Theme.font(Theme.base))
                                    Spacer()
                                }
                                .padding(.horizontal, Theme.px(14))
                                .frame(height: Theme.px(44))
                                .opacity(on || chosen.count < chooser.limit ? 1 : 0.5)
                            }
                            .buttonStyle(RowStyle(radius: Theme.px(8)))
                            .focused($focused, equals: option.value)
                        }
                    }
                    .padding(Theme.px(8))
                }
                .scrollClipDisabled()
            }
            .padding(Theme.px(20))
            .frame(width: Theme.px(520))
            .frame(maxHeight: Theme.px(640))
            .background(GlassBackground(shape: RoundedRectangle(cornerRadius: Theme.px(16), style: .continuous),
                                        fill: Color(white: 17 / 255), panel: true))
            .overlay(RoundedRectangle(cornerRadius: Theme.px(16), style: .continuous).stroke(.white.opacity(0.1), lineWidth: Theme.px(1)))
        }
        .foregroundStyle(.white)
        .onAppear {
            chosen = chooser.chosen
            focused = chooser.options.first?.value
        }
        .onExitCommand(perform: done)
    }
}

/// A list of choices over the dimmed page.
private struct ChooserPanel: View {
    let chooser: Chooser
    let done: () -> Void
    @FocusState private var focused: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(alignment: .leading, spacing: Theme.px(12)) {
                Text(chooser.title).font(Theme.font(Theme.xl, .semibold)).padding(.horizontal, Theme.px(8))
                ScrollView {
                    VStack(spacing: Theme.px(4)) {
                        ForEach(chooser.options, id: \.value) { option in
                            Button {
                                chooser.choose(option.value)
                                done()
                            } label: {
                                HStack(spacing: Theme.px(10)) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: Theme.px(13), weight: .semibold))
                                        .opacity(option.value == chooser.current ? 1 : 0)
                                    Text(option.label).font(Theme.font(Theme.base))
                                    Spacer()
                                }
                                .padding(.horizontal, Theme.px(14))
                                .frame(height: Theme.px(44))
                            }
                            .buttonStyle(RowStyle(radius: Theme.px(8)))
                            .focused($focused, equals: option.value)
                        }
                    }
                    .padding(Theme.px(8))
                }
                .scrollClipDisabled()
            }
            .padding(Theme.px(20))
            .frame(width: Theme.px(480))
            .frame(maxHeight: Theme.px(600))
            .background(GlassBackground(shape: RoundedRectangle(cornerRadius: Theme.px(16), style: .continuous),
                                        fill: Color(white: 17 / 255), panel: true))
            .overlay(RoundedRectangle(cornerRadius: Theme.px(16), style: .continuous).stroke(.white.opacity(0.1), lineWidth: Theme.px(1)))
        }
        .foregroundStyle(.white)
        .onAppear { focused = chooser.current }
        .onExitCommand(perform: done)
    }
}

/// The synced playback settings the player follows.
struct PlayerRules {
    var chapterSkips = true
    var skipFillers = true
    var skipRecaps = true
    var markUnaired = true
}

/// Signs another device in to this account: the code it shows, typed here, as the web app's Account
/// settings approve it (POST /QuickConnect/Authorize).
private struct QuickConnectApproval: View {
    @EnvironmentObject private var session: Session
    let done: () -> Void
    @State private var code = ""
    @State private var state: String?
    @State private var working = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(alignment: .leading, spacing: Theme.px(14)) {
                Text(L("Approve a Quick Connect code")).font(Theme.font(Theme.xl, .semibold))
                Text(L("Enter the code the other device shows to sign it in to this account."))
                    .font(Theme.font(Theme.sm))
                    .foregroundStyle(Theme.gray400)
                TextField(L("Code"), text: $code)
                    .keyboardType(.numberPad)
                    .font(Theme.font(Theme.lg))
                if let state {
                    Text(state).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray300)
                }
                HStack(spacing: Theme.px(8)) {
                    Button(working ? L("Approving…") : L("Approve")) { Task { await approve() } }
                        .buttonStyle(SoftPillStyle(selected: true))
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || working)
                    Button(L("Close"), action: done).buttonStyle(SoftPillStyle())
                }
            }
            .padding(Theme.px(24))
            .frame(width: Theme.px(520), alignment: .leading)
            .background(GlassBackground(shape: RoundedRectangle(cornerRadius: Theme.px(16), style: .continuous),
                                        fill: Color(white: 17 / 255), panel: true))
            .overlay(RoundedRectangle(cornerRadius: Theme.px(16), style: .continuous).stroke(.white.opacity(0.1), lineWidth: Theme.px(1)))
        }
        .foregroundStyle(.white)
        .onExitCommand(perform: done)
    }

    private func approve() async {
        guard let client = session.client else { return }
        working = true
        defer { working = false }
        let entered = code.filter { !$0.isWhitespace }
        do {
            try await client.call("POST", "/QuickConnect/Authorize", ["code": entered, "userId": session.userId])
            state = L("Approved. The other device is signing in.")
            code = ""
        } catch {
            state = L("That code wasn't approved. Check it and try again.")
        }
    }
}
