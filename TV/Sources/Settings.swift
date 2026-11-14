import AetherEngineFeatures
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
        if let me = try? await client.json("GET", "/Users/Me") {
            configuration = me["Configuration"] as? [String: Any] ?? [:]
        }
        loaded = true
    }

    // MARK: Synced settings

    func text(_ key: String, _ fallback: String) -> String { custom[key] ?? fallback }
    func flag(_ key: String, _ fallback: Bool) -> Bool { custom[key].map { $0 == "1" } ?? fallback }
    func number(_ key: String, _ fallback: Double) -> Double { custom[key].flatMap(Double.init) ?? fallback }

    /// Saves a synced setting; the default is stored as nothing, as the web app stores it.
    func set(_ key: String, _ value: String?, fallback: String) {
        if let value, value != fallback { custom[key] = value } else { custom.removeValue(forKey: key) }
        if key == "accentColor" || key == "backgroundColor" { Theme.apply(accent: accentColor, background: backgroundColor) }
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

    var heroSeconds: Double { number("heroSeconds", 9) }

    // MARK: Interface, under the web app's keys (lib/settings)

    /// Episodes not started show their pictures and names blurred until focused.
    var blurSpoilers: Bool { flag("blurSpoilers", false) }
    /// Search results in one grid, rather than a row each for movies and shows.
    var combineSearch: Bool { flag("combineSearch", false) }
    /// `rotate` through featured titles, or `follow` the focused card (`corner`: compactly).
    var heroMode: String { text("heroMode", "rotate") }
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
    /// Changes when the theme does, so the app draws itself again in its colours.
    var themeKey: String { "\(accentColor ?? "")|\(backgroundColor ?? "")" }

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
    /// Pausing and skipping bring the controls up.
    @Published var showOnPauseAndSkip: Bool = UserDefaults.standard.object(forKey: "controls.showOnPauseAndSkip") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showOnPauseAndSkip, forKey: "controls.showOnPauseAndSkip") }
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

    /// Anime upscaling: anime plays through AetherEngine's line-art scaler. Kept on this Apple TV, as
    /// the web app keeps its own (`aiostreams-web-video-upscaling`).
    @Published var animeUpscaling: Bool = UserDefaults.standard.bool(forKey: "video.animeUpscaling") {
        didSet { UserDefaults.standard.set(animeUpscaling, forKey: "video.animeUpscaling") }
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
        case "12": return Self.twelve.string(from: date)
        case "24": return Self.twentyFour.string(from: date)
        default: return date.formatted(date: .omitted, time: .shortened)
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

/// Jellyfin's three-letter codes, as its language settings take them.
private let languageOptions: [(String, String)] = [
    ("eng", "English"), ("spa", "Spanish"), ("fre", "French"), ("ger", "German"), ("ita", "Italian"),
    ("por", "Portuguese"), ("dut", "Dutch"), ("swe", "Swedish"), ("nor", "Norwegian"), ("dan", "Danish"),
    ("fin", "Finnish"), ("pol", "Polish"), ("cze", "Czech"), ("hun", "Hungarian"), ("rum", "Romanian"),
    ("gre", "Greek"), ("tur", "Turkish"), ("rus", "Russian"), ("ukr", "Ukrainian"), ("ara", "Arabic"),
    ("heb", "Hebrew"), ("hin", "Hindi"), ("tam", "Tamil"), ("tel", "Telugu"), ("tha", "Thai"),
    ("vie", "Vietnamese"), ("ind", "Indonesian"), ("may", "Malay"), ("fil", "Filipino"),
    ("jpn", "Japanese"), ("kor", "Korean"), ("chi", "Chinese"),
]

private func languageName(_ code: String) -> String {
    if code == "OriginalLanguage" { return "Original language" }
    return languageOptions.first { $0.0 == code }?.1
        ?? Locale.current.localizedString(forLanguageCode: code)
        ?? code
}

struct SettingsView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @State private var chooser: Chooser?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.px(28)) {
                PageTitle(text: "Settings")
                section("Playback", note: "Saved to your account, so the web app and your other devices use them too.") {
                    row("Audio language", value: listLabel(prefs.languages(list: "AudioLanguages", one: "AudioLanguagePreference"), none: "The file's default")) {
                        chooseLanguage("Audio language", list: "AudioLanguages", one: "AudioLanguagePreference", original: true)
                    }
                    row("Subtitle language", value: listLabel(prefs.languages(list: "SubtitleLanguages", one: "SubtitleLanguagePreference"), none: "Any")) {
                        chooseLanguage("Subtitle language", list: "SubtitleLanguages", one: "SubtitleLanguagePreference", original: false)
                    }
                    toggle("Auto-play the first version", key: "autoPlayFirst", fallback: false)
                    Text(prefs.autoPlayFirst
                        ? "Play starts the first version, and resuming goes back to the version you were watching. Hold select on a title and choose Choose a version to pick instead."
                        : "Play lists the versions to choose from, but resuming goes back to the version you were watching. Hold select on a title and choose Play straight away to start the first.")
                        .font(Theme.font(Theme.sm))
                        .foregroundStyle(Theme.gray400)
                        .padding(.horizontal, Theme.px(16))
                    row("Subtitles", value: modeName(prefs.subtitleMode)) {
                        chooser = Chooser(
                            title: "Subtitles",
                            options: ["Default", "Smart", "Always", "OnlyForced", "None"].map { (modeName($0), $0) },
                            current: prefs.subtitleMode
                        ) { prefs.configure(["SubtitleMode": $0]) }
                    }
                }
                section("Skipping and the next episode", note: "Shared with the web app. Intros, recaps and credits come from your server, with Skip intro and credits on in its configuration.") {
                    ForEach([("Intro", "Intros"), ("Recap", "Recaps"), ("Outro", "Credits"), ("Preview", "Previews"), ("Commercial", "Ads")], id: \.0) { entry in
                        synced(entry.1, key: "segment\(entry.0)", fallback: "ask",
                               options: [("Show a skip button", "ask"), ("Skip automatically", "skip"), ("Don't skip", "none")])
                    }
                    row("Play the next episode automatically", value: prefs.autoplayNext ? "On" : "Off") {
                        prefs.configure(["EnableNextEpisodeAutoPlay": !prefs.autoplayNext])
                    }
                    synced("Offer the next episode", key: "nextPrompt", fallback: "credits",
                           options: [("At the credits", "credits"), ("Near the end", "end"), ("Never", "off")])
                    synced("Without credits, offer it", key: "nextLead", fallback: "30",
                           options: [15, 30, 45, 60, 90, 120].map { ("\($0) seconds before the end", String($0)) })
                    synced("Countdown", key: "nextCountdown", fallback: "15",
                           options: [5, 10, 15, 30].map { ("\($0) seconds", String($0)) })
                    toggle("Skip by the file's chapters", key: "chapterSkips", fallback: true)
                    toggle("Play the first version when none matches", key: "nextFallbackFirst", fallback: true)
                    toggle("Skip filler episodes", key: "skipFillers", fallback: true)
                    toggle("Skip recap episodes", key: "skipRecaps", fallback: true)
                    toggle("Wait for episodes to air", key: "markUnaired", fallback: true)
                    synced("Ask if you're still watching", key: "stillWatching", fallback: "3",
                           options: [("Never", "0")] + [2, 3, 4, 5, 8].map { ("After \($0) episodes", String($0)) })
                    Text("The next episode plays in the version that matches the one you're watching. Where none does, the first plays, or with that off, the versions are listed. Back hides the offer.")
                        .font(Theme.font(Theme.sm))
                        .foregroundStyle(Theme.gray400)
                        .padding(.horizontal, Theme.px(16))
                }
                section("Theme", note: "Shared with the web app.") {
                    synced("Accent colour", key: "accentColor", fallback: "",
                           options: [("Default", ""), ("Blue", "#3b82f6"), ("Sky", "#0ea5e9"), ("Teal", "#14b8a6"),
                                     ("Green", "#22c55e"), ("Amber", "#f59e0b"), ("Orange", "#f97316"), ("Red", "#ef4444"),
                                     ("Pink", "#ec4899"), ("Violet", "#8b5cf6")])
                    synced("Background", key: "backgroundColor", fallback: "",
                           options: [("Default", ""), ("Black", "#000000"), ("Charcoal", "#18181b"), ("Slate", "#0f172a"),
                                     ("Navy", "#0b1026")])
                }
                section("Player controls", note: "Kept on this Apple TV.") {
                    row("Skip step", value: "\(prefs.seekStep) seconds") {
                        chooser = Chooser(title: "Skip step", options: [5, 10, 15, 30].map { ("\($0) seconds", String($0)) },
                                          current: String(prefs.seekStep)) { prefs.seekStep = Int($0) ?? 10 }
                    }
                    row("Show the time left", value: prefs.showTimeLeft ? "On" : "Off") { prefs.showTimeLeft.toggle() }
                    row("Show the clock", value: prefs.showClock ? "On" : "Off") { prefs.showClock.toggle() }
                    row("Show the controls on pause and skip", value: prefs.showOnPauseAndSkip ? "On" : "Off") {
                        prefs.showOnPauseAndSkip.toggle()
                    }
                }
                section("Video", note: nil) {
                    row("Anime upscaling", value: prefs.animeUpscaling ? "On" : "Off") {
                        prefs.animeUpscaling.toggle()
                    }
                    Text("Anime up to 1080p is upscaled for your TV with Anime4K's line-art network, for sharper lines. Applies to titles with an anime database id, and only to SDR video. Changes take effect from the next title.")
                        .font(Theme.font(Theme.sm))
                        .foregroundStyle(Theme.gray400)
                        .padding(.horizontal, Theme.px(16))
                }
                section("Subtitle style", note: "The same style as the web app's, on every device you sign in to.") {
                    synced("Size", key: "subtitleSize", fallback: "normal",
                           options: [("Small", "small"), ("Normal", "normal"), ("Large", "large"), ("Huge", "huge")])
                    synced("Font", key: "subtitleFont", fallback: "default",
                           options: [("The player's own", "default"), ("Sans serif", "sans-serif"), ("Serif", "serif"),
                                     ("Monospace", "monospace"), ("Casual", "casual"), ("Cursive", "cursive")])
                    synced("Text colour", key: "subtitleColor", fallback: "#ffffff",
                           options: [("White", "#ffffff"), ("Yellow", "#ffff00"), ("Light grey", "#d1d1d1"),
                                     ("Cyan", "#00ffff"), ("Green", "#00ff00")])
                    toggle("Bold", key: "subtitleBold", fallback: false)
                    synced("Outline", key: "subtitleOutline", fallback: "normal",
                           options: [("None", "none"), ("Thin", "thin"), ("Normal", "normal"), ("Thick", "thick")])
                    toggle("Shadow", key: "subtitleShadow", fallback: false)
                    synced("Background", key: "subtitleBackgroundOpacity", fallback: "0",
                           options: [("None", "0"), ("Faint", "25"), ("Half", "50"), ("Strong", "75"), ("Solid", "100")])
                    synced("Height", key: "subtitlePosition", fallback: "0",
                           options: [("Lowest", "-3"), ("Normal", "0"), ("Raised a little", "5"), ("Raised", "10"), ("High", "20")])
                    toggle("Override styled subtitles", key: "subtitleOverrideStyled", fallback: false)
                    SubtitlePreview(look: prefs.subtitleLook)
                        .frame(width: Theme.px(480), height: Theme.px(270))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.px(12), style: .continuous))
                        .padding(.top, Theme.px(8))
                }
                // Only a build with the height channel components has anything to set here.
                if AetherEngine.OptionalComponent.trueHDObjectAudio.isBuiltIn || AetherEngine.OptionalComponent.dtsxObjectAudio.isBuiltIn {
                    section("Audio", note: "TrueHD Atmos and DTS:X play with their height channels, rendered for your speakers and sent to your receiver as Dolby MAT. Needs tvOS 26. DTS:X needs 7.1.4 or 9.1.6.") {
                        row("Atmos and DTS:X speakers", value: speakerName(prefs.speakerChoice)) {
                            var options: [(label: String, value: String)] = [(label: "Off: play the 7.1 channels", value: "off")]
                            for layout in SpatialSpeakerLayout.allCases {
                                options.append((label: speakerName(layout.rawValue), value: layout.rawValue))
                            }
                            chooser = Chooser(title: "Atmos and DTS:X speakers", options: options, current: prefs.speakerChoice) {
                                prefs.speakerChoice = $0
                            }
                        }
                    }
                }
                section("Interface", note: nil) {
                    row("Start page", value: Place(rawValue: prefs.startPage)?.name ?? "Home") {
                        chooser = Chooser(
                            title: "Start page",
                            options: Place.startPages.map { ($0.name, $0.rawValue) },
                            current: prefs.startPage
                        ) { prefs.startPage = $0 }
                    }
                    toggle("Merge continue watching and next up", key: "mergeNextUp", fallback: false)
                    toggle("Combine movie and show results", key: "combineSearch", fallback: false)
                    toggle("Blur episodes not started", key: "blurSpoilers", fallback: false)
                    synced("Hero", key: "heroMode", fallback: "rotate",
                           options: [("Rotates through featured titles", "rotate"), ("Follows the selected card", "follow"),
                                     ("Follows the selected card, compact", "corner")])
                    synced("Poster size", key: "posterSize", fallback: "medium",
                           options: [("Small", "small"), ("Medium", "medium"), ("Large", "large")])
                    synced("Poster text", key: "posterText", fallback: "title,year",
                           options: [("Title and year", "title,year"), ("Title", "title"), ("Year", "year"), ("None", "none")])
                    synced("Time format", key: "timeFormat", fallback: "auto",
                           options: [("Automatic", "auto"), ("12-hour", "12"), ("24-hour", "24")])
                    row("Prevent accidental exit", value: prefs.preventAccidentalExit ? "On" : "Off") {
                        prefs.preventAccidentalExit.toggle()
                    }
                    Text(prefs.preventAccidentalExit
                        ? "Back on Home shows “Press Back again to leave”, and only a second press leaves the app."
                        : "Back on Home leaves the app straight away.")
                        .font(Theme.font(Theme.sm))
                        .foregroundStyle(Theme.gray400)
                        .padding(.horizontal, Theme.px(16))
                    synced("Hero turns every", key: "heroSeconds", fallback: "9",
                           options: [5, 7, 9, 12, 15, 20, 30].map { ("\($0) seconds", String($0)) })
                }
                section("Account", note: nil) {
                    fact("Server", session.serverName ?? session.client?.base.host ?? "")
                    fact("Signed in as", session.userName ?? "")
                    HStack(spacing: Theme.px(8)) {
                        Button("Switch user") { session.signOut() }.buttonStyle(SoftPillStyle())
                        Button("Change server") { session.forgetServer() }.buttonStyle(SoftPillStyle())
                    }
                    .padding(.top, Theme.px(4))
                }
                section("About", note: nil) {
                    fact("App", "AIOStreams tvOS \(AppInfo.version)")
                    fact("Player", AppInfo.player)
                    Text("An unofficial app, not affiliated with AIOStreams or AetherEngine. AGPL-3.0; AetherEngine is LGPL-3.0, FFmpeg LGPL-2.1+, libdovi and Anime4K (Copyright (c) 2019-2021 bloc97) MIT, and the Inter font is under the SIL Open Font License.")
                        .font(Theme.font(Theme.sm))
                        .foregroundStyle(Theme.gray400)
                }
            }
            .frame(maxWidth: Theme.px(760), alignment: .leading)
            .pagePadding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Theme.px(64))
        }
        .edgeToEdge()
        .fullScreenCover(item: $chooser) { chooser in
            ChooserPanel(chooser: chooser) { self.chooser = nil }
                .presentationBackground(.clear)
        }
    }

    // MARK: Rows

    private func section<Content: View>(_ title: String, note: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.px(8)) {
            Text(title).font(Theme.font(Theme.lg, .semibold))
            if let note { Text(note).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray400) }
            VStack(alignment: .leading, spacing: Theme.px(6)) { content() }
                .padding(.top, Theme.px(6))
        }
        .focusSection()
    }

    private func row(_ title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(Theme.font(Theme.base))
                Spacer(minLength: Theme.px(16))
                Text(value).font(Theme.font(Theme.base)).foregroundStyle(Theme.gray400).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: Theme.px(12), weight: .semibold)).foregroundStyle(Theme.gray500)
            }
            .padding(.horizontal, Theme.px(16))
            .frame(height: Theme.px(48))
        }
        .buttonStyle(RowStyle())
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
        return row(title, value: on ? "On" : "Off") {
            prefs.set(key, on ? "0" : "1", fallback: fallback ? "1" : "0")
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.gray400)
            Spacer()
            Text(value)
        }
        .font(Theme.font(Theme.base))
        .padding(.horizontal, Theme.px(16))
        .frame(height: Theme.px(40))
    }

    private func listLabel(_ codes: [String], none: String) -> String {
        codes.isEmpty ? none : codes.map(languageName).joined(separator: ", ")
    }

    /// Puts the chosen language first, keeping the others the web app may have listed after it.
    private func chooseLanguage(_ title: String, list: String, one: String, original: Bool) {
        let current = prefs.languages(list: list, one: one)
        var options: [(label: String, value: String)] = [(original ? "The file's default" : "Any", "")]
        if original { options.append(("Original language", "OriginalLanguage")) }
        options += languageOptions.map { ($0.1, $0.0) }
        chooser = Chooser(title: title, options: options, current: current.first ?? "") { code in
            if code.isEmpty {
                prefs.configure([list: [String](), one: NSNull()])
            } else {
                let next = [code] + current.filter { $0 != code }
                prefs.configure([list: next, one: code])
            }
        }
    }

    private func speakerName(_ value: String) -> String {
        value == "off" ? "Off" : value + (value == SpatialSpeakerLayout.l714.rawValue ? " (most Atmos setups)" : "")
    }

    private func modeName(_ mode: String) -> String {
        switch mode {
        case "Smart": return "Smart: when the audio isn't in your language"
        case "Always": return "Always"
        case "OnlyForced": return "Only forced"
        case "None": return "Off"
        default: return "Default"
        }
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
    static let cue = SubtitleCue(id: 0, startTime: 0, endTime: .greatestFiniteMagnitude, body: .text("This is how subtitles will look."))
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
            .background(RoundedRectangle(cornerRadius: Theme.px(16), style: .continuous).fill(Color(white: 17 / 255)))
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
