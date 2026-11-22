import AetherEngineFeatures
import AVKit
import Combine
import SwiftUI

/// One engine for the app's life, as AetherEngine is built to be reused across titles.
@MainActor
enum SharedEngine {
    static let engine: AetherEngine = {
        do {
            let engine = try AetherEngine()
            // Nothing else here plays sound, so the session is released when playback ends.
            engine.deactivatesAudioSessionOnStop = true
            return engine
        } catch {
            fatalError("AetherEngine could not start: \(error)")
        }
    }()
}

/// Plays one request and reports it to the server as the web app's `PlaybackReporter` does.
@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var paused = false
    /// The title has played: until then the shared engine can still hold the last one's length
    /// and position, which the next episode's offer mustn't read.
    @Published private(set) var started = false
    @Published private(set) var waiting = true
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var audioTracks: [TrackInfo] = []
    @Published private(set) var subtitleTracks: [TrackInfo] = []
    @Published private(set) var activeAudio: Int?
    @Published private(set) var activeSubtitle: Int?
    @Published private(set) var failure: String?
    @Published private(set) var finished = false
    /// The file's chapters, or the server's where the file has none, with pictures where there are.
    @Published private(set) var chapters: [PlayerChapter] = []
    private var fileChapters: [ChapterInfo] = []
    private var serverChapters: [PlayerChapter] = []
    /// The server's trickplay sheet for this version, and the sheets fetched so far.
    private var trickplay: (sheet: TrickplaySheet, width: Int)?
    private var sheets: [Int: CGImage] = [:]
    /// How far ahead of the start the stream is held, in seconds.
    @Published private(set) var buffered: Double = 0
    @Published private(set) var speed: Double = 1
    @Published private(set) var fit: Fit = .fit
    /// The intros, recaps and credits the server knows for this title.
    @Published private(set) var segments: [MediaSegment] = []
    /// The episode after this one, which the up next offer plays.
    @Published private(set) var nextEpisode: Item?
    /// What the pause screen says about the title, read where the item came without it.
    @Published private(set) var overview: String?
    /// Seconds the subtitles are shown later (negative: earlier) than the file says.
    @Published private(set) var subtitleDelay: Double = 0
    /// Seconds the sound is held back (negative: brought forward) against the picture.
    @Published private(set) var audioDelay: Double = 0

    func setSubtitleDelay(_ seconds: Double) {
        subtitleDelay = (seconds * 10).rounded() / 10
        overlay.delay = subtitleDelay
    }

    func setAudioDelay(_ seconds: Double) {
        audioDelay = (seconds * 100).rounded() / 100
        engine.setAudioDelay(audioDelay)
    }

    enum Fit: String, CaseIterable {
        case fit = "Fit", crop = "Crop", stretch = "Stretch"

        var gravity: AVLayerVideoGravity {
            switch self {
            case .fit: return .resizeAspect
            case .crop: return .resizeAspectFill
            case .stretch: return .resize
            }
        }
    }

    let engine: AetherEngine
    let overlay: SubtitleOverlayView
    let request: PlayRequest
    /// A channel or another source with no end: played at its live edge, with no seeking.
    let isLive: Bool
    private let client: JellyfinClient
    private var bag = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var progressTimer: Timer?
    private var reported = false
    private var stopped = false

    /// The account's track rules with the show's pick, and whether a pick here is remembered.
    let tracks: TrackRules
    private let baseTracks: TrackRules
    private let remember: (audio: Bool, subtitles: Bool)
    private let audioShaping: AudioShaping
    private let defaultAudioDelay: Double
    private let defaultSubtitleDelay: Double
    /// Live TV's display matching: whether a channel switches the TV's frame rate, and its range.
    private let liveDisplay: (rate: Bool, range: Bool)
    /// Display criteria this player wrote itself, which it clears as it stops.
    private var wroteCriteria = false
    /// The audio stream picked before the load, where the server describes the streams.
    private var audioStreamIndex: Int32?
    private let speakers: SpatialSpeakerLayout?
    private let animeUpscaling: Bool
    /// HDR10 tone mapping's target in nits, 0 for off.
    private let toneMapNits: Int
    private let rules: PlayerRules
    /// The server's segments, before the file's chapters are weighed against them.
    private var serverSegments: [MediaSegment] = []
    private let userId: String?
    /// The audio's language the subtitles were picked against, for those that arrive later.
    private var heardLanguage: String?
    /// Addon subtitles asked for once the title plays, by the server's stream index, with their tracks.
    private var laterStreams: [MediaStream] = []
    private var laterTrackIDs: [Int: Int] = [:]
    /// A subtitle chosen in the player or by a remote, which a later pick leaves alone.
    private var subtitleChosen = false

    init(request: PlayRequest, client: JellyfinClient, tracks: TrackRules = TrackRules(), baseTracks: TrackRules = TrackRules(),
         remember: (audio: Bool, subtitles: Bool) = (true, true), audioShaping: AudioShaping = AudioShaping(),
         audioDelay: Double = 0, subtitleDelay: Double = 0,
         liveDisplay: (rate: Bool, range: Bool) = (true, true),
         look: SubtitleLook = SubtitleLook(), speakers: SpatialSpeakerLayout? = .l714, animeUpscaling: Bool = false, toneMapNits: Int = 0,
         userId: String? = nil, rules: PlayerRules = PlayerRules()) {
        self.request = request
        isLive = request.source.isInfiniteStream == true || request.item.isChannel
        self.client = client
        self.tracks = tracks
        self.baseTracks = baseTracks
        self.remember = remember
        self.audioShaping = audioShaping
        defaultAudioDelay = audioDelay
        defaultSubtitleDelay = subtitleDelay
        self.liveDisplay = liveDisplay
        self.speakers = speakers
        self.animeUpscaling = animeUpscaling
        self.toneMapNits = toneMapNits
        self.rules = rules
        self.userId = userId
        engine = SharedEngine.engine
        overlay = SubtitleOverlayView()
        overlay.look = look
        baseLook = look
        observe()
    }

    private func observe() {
        engine.$state
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .playing:
                    self.started = true
                    self.setPaused(false)
                case .paused: self.setPaused(true)
                case .ended: self.finished = true
                case .error(let message):
                    AppLog.warn("player", "error: \(message)")
                    // An origin that answers byte ranges with other bytes, as IPTV catch-up archives
                    // do: once more, read straight through from its start (AE#958).
                    if self.engine.errorInfo?.kind == .sourceFabricatesRanges, !self.sequential, !self.stopped {
                        AppLog.warn("player", "origin fabricates ranges; loading again as sequential")
                        self.sequential = true
                        self.loadTask = nil
                        self.start()
                        return
                    }
                    self.failure = message
                default: break
                }
            }
            .store(in: &bag)
        Publishers.CombineLatest3(engine.$isBuffering, engine.$isSeeking, engine.$hasFirstFrameReadyForDisplay)
            .sink { [weak self] buffering, seeking, ready in self?.waiting = buffering || seeking || !ready }
            .store(in: &bag)
        engine.clock.$currentTime
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.position = $0 }
            .store(in: &bag)
        engine.$duration.sink { [weak self] in
            self?.duration = $0
            // The last chapter runs to the end, which a later duration moves.
            self?.combineSegments()
        }.store(in: &bag)
        engine.$mediaChapters.sink { [weak self] in
            self?.fileChapters = $0
            self?.mergeChapters()
        }.store(in: &bag)
        engine.clock.$bufferedPosition
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.buffered = $0 }
            .store(in: &bag)
        engine.$audioTracks.sink { [weak self] in self?.audioTracks = $0 }.store(in: &bag)
        engine.$subtitleTracks.sink { [weak self] in self?.subtitleTracks = $0 }.store(in: &bag)
        engine.$activeAudioTrackIndex.sink { [weak self] in self?.activeAudio = $0 }.store(in: &bag)
        engine.$activeSubtitleTrackIndex.sink { [weak self] in self?.activeSubtitle = $0 }.store(in: &bag)
        engine.$subtitleCues.sink { [weak self] in self?.overlay.setCues($0) }.store(in: &bag)
        engine.clock.$sourceTime.sink { [weak self] in self?.overlay.setTime($0) }.store(in: &bag)
        Publishers.CombineLatest(engine.$sourceVideoWidth, engine.$sourceVideoHeight)
            .sink { [weak self] width, height in
                guard let self else { return }
                let aspect = self.engine.sourceVideoPixelAspectRatio
                self.overlay.videoSize = CGSize(width: Double(width) * (aspect > 0 ? aspect : 1), height: Double(height))
            }
            .store(in: &bag)
    }

    /// Read straight through, from byte 0 only: a catch-up programme, whose archive answers byte
    /// ranges with other bytes, or a source the engine found doing so. No seeking within it.
    private var sequential = false

    /// A programme a channel keeps, played from its start.
    private var isCatchUp: Bool {
        request.item.type == "Program" || (request.item.channelId != nil && !request.item.isChannel)
    }

    /// The title's length, which a sequential read can't measure by itself.
    private var declaredDuration: Double? {
        if let ticks = request.item.runTimeTicks, ticks > 0 { return Double(ticks) / 10_000_000 }
        if let start = request.item.starts, let end = request.item.ends, end > start { return end.timeIntervalSince(start) }
        return nil
    }

    func start() {
        guard loadTask == nil else { return }
        if isCatchUp, !isLive { sequential = true }
        guard let url = client.streamURL(itemId: request.item.id, source: request.source) else {
            failure = L("This version has no address to play.")
            return
        }
        var options = LoadOptions()
        options.httpHeaders = request.source.requiredHttpHeaders ?? [:]
        // IPTV panels can refuse a player library's own user agent: a live stream that names none
        // is sent VLC's, as the official apps' players send it (the web app's `liveHeaders`).
        if isLive, !options.httpHeaders.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            options.httpHeaders["User-Agent"] = "VLC/3.0.21 LibVLC/3.0.21"
        }
        // The engine writes the display criteria itself, following the Apple TV's Match Content setting.
        options.matchContentEnabled = Self.window?.avDisplayManager.isDisplayCriteriaMatchingEnabled ?? true
        // Serves Dolby Vision profile 8 as profile 5 on a TV without Dolby Vision; ignored on one with it.
        options.forceDolbyVisionOnNonDVDisplay = true
        options.externalSubtitles = serverSubtitles()
        // The tracks the web app would start with: the account's languages and track types, with
        // the show's pick first. Where the server describes the version's streams, the pick is made
        // here; otherwise the engine matches the languages itself.
        let streams = request.source.mediaStreams ?? []
        options.preferredAudioLanguages = tracks.audioLanguages
        let audio = tracks.audioStream(in: streams)
        audioStreamIndex = audio?.index.map(Int32.init)
        let heard = (audio ?? streams.first { $0.type == "Audio" && $0.isDefault == true }
                     ?? streams.first { $0.type == "Audio" })?.language
        heardLanguage = heard
        if streams.contains(where: { $0.type == "Subtitle" }) {
            options.preferredSubtitleLanguages = []
            if let subtitle = tracks.subtitleStream(in: streams, audioLanguage: heard), let index = subtitle.index {
                let external = serverStreams()
                options.initialSubtitleTrackID = subtitle.isExternal == true
                    ? external.firstIndex(of: subtitle).map { AetherEngine.externalSubtitleTrackIDBase + $0 }
                    : index
                options.preferredSubtitleLanguages = subtitle.language.map { [$0] } ?? []
            }
        } else {
            options.preferredSubtitleLanguages = ["None", "OnlyForced"].contains(tracks.subtitleMode) ? [] : tracks.subtitleLanguages
        }
        // Sound shaped as the Apple TV's settings ask, and its usual delay.
        options.audioShaping = audioShaping
        options.audioDelaySeconds = defaultAudioDelay
        // TrueHD Atmos and DTS:X with their heights, rendered for the receiver's speakers and sent to it
        // as Dolby MAT (tvOS 26 and later); off, they play as their 7.1 channels.
        options.objectAudioRendering = speakers.map { .render($0) } ?? .off
        options.isLive = isLive
        if sequential, !isLive {
            options.sequentialOrigin = true
            options.declaredDurationSeconds = declaredDuration
        }
        // HDR10 brighter than the TV is rolled off to its peak (the engine passes the rest by).
        if toneMapNits > 0, !request.isTrailer {
            options.videoProcessing = VideoProcessingOptions(targetPeakNits: Double(toneMapNits))
        }
        if isLive {
            // With either match off, the app writes the TV's mode itself, or leaves it as it is.
            if !(liveDisplay.rate && liveDisplay.range) { options.displayCriteriaOwner = .host }
        }

        // The engine is shared: a title starts at the usual delay, whatever the last one was set to.
        audioDelay = defaultAudioDelay
        if defaultSubtitleDelay != 0 { setSubtitleDelay(defaultSubtitleDelay) }
        overview = request.item.overview
        Task { [weak self] in await self?.loadExtras() }
        AppLog.info("player", "load \(request.item.id) source=\(request.source.ownId) host=\(url.host ?? "?")")
        loadTask = Task { [weak self] in
            guard let self else { return }
            var loadOptions = options
            do {
                // Anime upscaling, decided before the load so the first frame is already upscaled.
                if self.animeUpscaling, !self.request.isTrailer, await self.isAnime() {
                    loadOptions.upscalesLowResolutionVideo = true
                    loadOptions.upscaleScaler = .lineArt
                    AppLog.info("player", "anime upscaling on")
                }
                let start = self.isLive || self.sequential ? nil : self.request.startMs.map { $0 / 1000 }
                try await self.engine.load(url: url, startPosition: start, options: loadOptions,
                                           audioSourceStreamIndex: self.audioStreamIndex)
                // A channel whose sound the engine's own reader identified none of plays silent there:
                // once more on AVPlayer, which reads the live playlist itself.
                if self.isLive, !loadOptions.nativeRemoteHLS, self.engine.videoRoute != .remoteBypass,
                   !self.engine.audioTracks.isEmpty, self.engine.audioTracks.allSatisfy({ $0.channels <= 0 }) {
                    AppLog.warn("player", "live audio unidentified, loading again on AVPlayer")
                    loadOptions.nativeRemoteHLS = true
                    try await self.engine.load(url: url, startPosition: nil, options: loadOptions,
                                               audioSourceStreamIndex: self.audioStreamIndex)
                }
                if self.isLive, self.liveDisplay.rate != self.liveDisplay.range { self.matchLiveDisplay() }
                // The configuration's subtitle addons, asked for now the title plays rather than before.
                if !self.isLive, !self.request.isTrailer { Task { [weak self] in await self?.addLaterSubtitles() } }
                // A watch party's title waits for the group to start it; anything else plays.
                if let entry = self.request.partyEntry {
                    self.party = PartyFollower(model: self, playlistItemId: entry)
                } else {
                    self.engine.play()
                }
                if self.isLive, self.request.partyEntry == nil { self.nudgeIfFrozen() }
                self.report("/Sessions/Playing")
                self.progressTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report("/Sessions/Playing/Progress", event: "TimeUpdate") }
                }
            } catch is CancellationError {
            } catch {
                AppLog.warn("player", "load failed: \(error)")
                self.failure = error.localizedDescription
            }
        }
    }

    /// The segments and the next episode, alongside the load.
    private func loadExtras() async {
        guard !isLive, !request.isTrailer, let userId else { return }
        let item = request.item
        // The overview for the pause screen, and the server's chapters and trickplay pictures.
        let found: ItemsResult? = try? await client.get("/Items", ["userId": userId, "Ids": item.id, "Fields": "Overview,Chapters,Trickplay"])
        if let full = found?.items?.first {
            if overview == nil { overview = full.overview }
            serverChapters = (full.chapters ?? []).enumerated().map { index, chapter in
                PlayerChapter(
                    id: index,
                    name: chapter.name ?? "",
                    start: Double(chapter.startPositionTicks ?? 0) / 10_000_000,
                    image: chapter.imageTag.map { client.url("/Items/\(item.id)/Images/Chapter/\(index)", ["tag": $0, "maxWidth": "480"]) }
                )
            }
            mergeChapters()
            // The narrowest sheet at least 320 wide, as the web app picks, for this version.
            let widths = full.trickplay?.first { $0.key.lowercased() == request.source.id.lowercased() }?.value ?? [:]
            let sorted = widths.values.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
            if let sheet = sorted.first(where: { ($0.width ?? 0) >= 320 }) ?? sorted.last,
               let width = sheet.width, width > 0, (sheet.tileWidth ?? 0) > 0, (sheet.tileHeight ?? 0) > 0,
               (sheet.interval ?? 0) > 0 {
                trickplay = (sheet, width)
            }
        }
        let marked: SegmentsResult? = try? await client.get("/MediaSegments/\(item.id)", ["userId": userId])
        serverSegments = (marked?.items ?? []).filter { $0.end > $0.start }
        combineSegments()
        // From a playlist, its next title plays on, in place of a show's next episode.
        if let next = request.queue.first(where: { $0.playable && $0.locationType != "Virtual" }) {
            nextEpisode = next
            return
        }
        // The episode after this one, as the web app finds it; one not yet out isn't offered.
        guard item.isEpisode, let series = item.seriesId else { return }
        let around: ItemsResult? = try? await client.get("/Shows/\(series)/Episodes", ["userId": userId, "AdjacentTo": item.id])
        var episodes = around?.items ?? []
        // Filler and recap episodes the server marks are passed over, as the settings say.
        let rules = rules
        let skipped = { (episode: Item) in
            episode.id != item.id
                && ((rules.skipFillers && episode.aiostreams?.filler == true) || (rules.skipRecaps && episode.aiostreams?.recap == true))
        }
        // A run of skipped episodes needs the rest of the show.
        if episodes.contains(where: skipped) {
            let all: ItemsResult? = try? await client.get("/Shows/\(series)/Episodes", ["userId": userId])
            episodes = all?.items ?? episodes
        }
        guard let at = episodes.firstIndex(where: { $0.id == item.id }) else { return }
        for next in episodes[(at + 1)...] {
            // Not out yet, or (with Mark unaired) out only on a date still to come: nothing to play on to.
            let airsLater = rules.markUnaired && (parseDate(next.premiereDate) ?? .distantPast) > Date()
            if next.locationType == "Virtual" || airsLater { return }
            if !skipped(next) {
                nextEpisode = next
                return
            }
        }
    }

    /// The file's chapters where it has them, else the server's (as the web app uses them since v0.15.0).
    private func mergeChapters() {
        if fileChapters.isEmpty {
            chapters = serverChapters
        } else {
            chapters = fileChapters.map { PlayerChapter(id: $0.id, name: $0.name, start: $0.startSeconds, image: nil) }
        }
        combineSegments()
    }

    /// A picture of the video at `seconds`: a frame from the engine where it can make one, else the
    /// server's trickplay thumbnail.
    func picture(at seconds: Double) async -> CGImage? {
        if engine.supportsCacheBackedStills, let frame = await engine.scrubThumbnail(atSeconds: seconds, maxWidth: 480) {
            return frame
        }
        return await trickplayPicture(at: seconds)
    }

    /// One thumbnail cut from the server's trickplay sheet that holds `seconds`.
    private func trickplayPicture(at seconds: Double) async -> CGImage? {
        guard let chosen = trickplay, let height = chosen.sheet.height, let across = chosen.sheet.tileWidth,
              let down = chosen.sheet.tileHeight, let interval = chosen.sheet.interval, interval > 0 else { return nil }
        let (sheet, width) = chosen
        var index = Int(seconds * 1000) / interval
        if let count = sheet.thumbnailCount, count > 0 { index = min(index, count - 1) }
        let perSheet = across * down
        let at = index / perSheet
        if sheets[at] == nil {
            let url = client.url("/Videos/\(request.item.id)/Trickplay/\(width)/\(at).jpg",
                                 ["MediaSourceId": request.source.id, "ApiKey": client.token])
            guard let fetched = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: fetched.0)?.cgImage else { return nil }
            sheets[at] = image
        }
        guard let image = sheets[at] else { return nil }
        let tile = index % perSheet
        let scale = CGFloat(image.width) / CGFloat(width * across)
        let rect = CGRect(x: CGFloat((tile % across) * width) * scale, y: CGFloat((tile / across) * height) * scale,
                          width: CGFloat(width) * scale, height: CGFloat(height) * scale)
        return image.cropping(to: rect)
    }

    /// The server's segments and the ones the file's chapters name: for each kind, the chapters'
    /// where Skip by the file's chapters is on, else the server's, the other filling what's left.
    private func combineSegments() {
        let named = MediaSegment.named(chapters: chapters.map { (title: $0.name, start: $0.start) }, duration: duration)
        var kinds = Set<String>()
        var combined: [MediaSegment] = []
        for source in rules.chapterSkips ? [named, serverSegments] : [serverSegments, named] {
            let added = source.filter { !kinds.contains($0.type) }
            kinds.formUnion(added.map(\.type))
            combined += added
        }
        segments = combined.sorted { $0.start < $1.start }
    }

    /// Anime by the web app's test: an anime database id on the title, its season or its show. A
    /// season can carry them from the server's anime database when its show has none.
    private func isAnime() async -> Bool {
        guard !isLive, let userId else { return false }
        let item = request.item
        let ids = [item.id, item.seasonId, item.seriesId].compactMap { $0 }
        let result: ItemsResult? = try? await client.get("/Items", [
            "userId": userId, "Ids": ids.joined(separator: ","), "Fields": "ProviderIds,Genres,Tags",
        ])
        return (result?.items ?? []).contains(where: \.hasAnimeIds)
    }

    /// The server's external subtitle streams, in the order they're registered with the engine.
    private func serverStreams() -> [MediaStream] {
        (request.source.mediaStreams ?? []).filter { stream in
            stream.type == "Subtitle" && stream.isExternal == true
                && stream.deliveryUrl.flatMap { client.absolute($0) } != nil
        }
    }

    /// The configuration's subtitle addons' files for this version, asked for once it plays: each
    /// one new to it becomes a track, and where the settings would pick one of them and nothing was
    /// chosen meanwhile, it shows.
    private func addLaterSubtitles() async {
        guard let userId,
              let named = try? await client.playbackInfo(userId: userId, itemId: request.item.id,
                                                         sourceId: request.source.ownId, addonSubtitles: true),
              let match = named.mediaSources?.first(where: { $0.ownId == request.source.ownId }) ?? named.mediaSources?.first,
              !stopped else { return }
        let known = Set(serverStreams().compactMap(\.deliveryUrl))
        let fresh = (match.mediaStreams ?? []).filter { stream in
            stream.type == "Subtitle" && stream.isExternal == true
                && stream.deliveryUrl.map { !known.contains($0) && client.absolute($0) != nil } == true
        }
        guard !fresh.isEmpty else { return }
        let shownBefore = engine.activeSubtitleTrackIndex
        for stream in fresh {
            guard let address = stream.deliveryUrl, let url = client.absolute(address) else { continue }
            let track = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(
                url: url, name: stream.displayTitle ?? stream.title, language: stream.language,
                isForced: stream.isForced ?? false, httpHeaders: [:]))
            laterStreams.append(stream)
            if let index = stream.index { laterTrackIDs[index] = track.id }
        }
        AppLog.info("player", "\(fresh.count) addon subtitles added")
        // Adding a track can make the engine pick by language; the settings' own pick decides.
        guard !subtitleChosen, !["None", "OnlyForced"].contains(tracks.subtitleMode) else {
            if engine.activeSubtitleTrackIndex != shownBefore {
                if let shownBefore { engine.selectSubtitleTrack(index: shownBefore) } else { engine.clearSubtitle() }
            }
            return
        }
        let all = (request.source.mediaStreams ?? []) + fresh
        if let pick = tracks.subtitleStream(in: all, audioLanguage: heardLanguage),
           let index = pick.index, fresh.contains(where: { $0.index == index }), let id = laterTrackIDs[index] {
            engine.selectSubtitleTrack(index: id)
        } else if engine.activeSubtitleTrackIndex != shownBefore {
            if let shownBefore { engine.selectSubtitleTrack(index: shownBefore) } else { engine.clearSubtitle() }
        }
    }

    /// The configuration's subtitle addons' files, registered as tracks the user can pick.
    private func serverSubtitles() -> [ExternalSubtitleTrack] {
        serverStreams().compactMap { stream in
            guard let address = stream.deliveryUrl, let url = client.absolute(address) else { return nil }
            return ExternalSubtitleTrack(
                url: url,
                name: stream.displayTitle ?? stream.title,
                language: stream.language,
                isForced: stream.isForced ?? false,
                httpHeaders: [:]
            )
        }
    }

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
    }

    private func setPaused(_ value: Bool) {
        let changed = value != paused
        paused = value
        if changed, reported { report("/Sessions/Playing/Progress", event: value ? "Pause" : "Unpause") }
    }

    func togglePause() {
        // In a watch party, the group pauses and plays, for everyone.
        if inParty {
            WatchParty.shared.request(["type": WatchParty.shared.timeline?.playing == true ? "Pause" : "Unpause"])
            return
        }
        engine.togglePlayPause()
    }

    /// Following a watch party's title: its commands drive the player, and its controls ask the group.
    private(set) var party: PartyFollower?
    var inParty: Bool { party != nil && WatchParty.shared.live }

    /// Switches the TV to the channel's frame rate or its dynamic range, whichever Live TV matches,
    /// keeping the other as the TV has it. The engine writes both together, so this writes them.
    private func matchLiveDisplay() {
        guard let manager = Self.window?.avDisplayManager, manager.isDisplayCriteriaMatchingEnabled else { return }
        let width = Int32(max(engine.sourceVideoWidth, 16)), height = Int32(max(engine.sourceVideoHeight, 16))
        let hdr = liveDisplay.range && engine.sourceVideoFormat != .sdr
        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: hdr ? kCMFormatDescriptionColorPrimaries_ITU_R_2020 : kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            kCMFormatDescriptionExtension_YCbCrMatrix: hdr ? kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 : kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
        ]
        if hdr {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = engine.sourceVideoFormat == .hlg
                ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG : kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        }
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: hdr ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                       width: width, height: height, extensions: extensions as CFDictionary,
                                       formatDescriptionOut: &description)
        guard let description else { return }
        let current = Float(Self.window?.screen.maximumFramesPerSecond ?? 60)
        let rate = liveDisplay.rate ? Float(engine.sourceVideoFrameRate ?? Double(current)) : current
        manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: rate, formatDescription: description)
        wroteCriteria = true
    }

    /// A channel that loads but doesn't move a few seconds later is paused and played once, which
    /// starts most that stall at their first frame.
    private func nudgeIfFrozen() {
        let from = position
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !self.stopped, !self.paused, self.position - from < 1 else { return }
            AppLog.warn("player", "live channel moved \(self.position - from) s in 6 s; pausing and playing it once")
            self.engine.pause()
            try? await Task.sleep(for: .milliseconds(500))
            guard !self.stopped else { return }
            self.engine.play()
        }
    }

    /// A seek the party's timeline asks for, past the controls that would ask the group.
    func followSeek(_ seconds: Double) {
        let target = min(max(seconds, 0), max(duration - 1, 0))
        position = target
        Task { await engine.seek(to: target) }
    }

    // MARK: Holding left or right

    /// Where a held left or right, or a swipe, has scrubbed to, while it lasts.
    @Published private(set) var scrubTarget: Double? {
        didSet {
            if let scrubTarget { wantPreview(scrubTarget) } else if oldValue != nil { endPreviews() }
        }
    }
    /// A frame from where the scrub would land, shown over the bar.
    @Published private(set) var preview: CGImage?
    private var previewBusy = false
    private var previewWanted: Double?

    /// The scrub is over: its frame goes, and the engine closes the decoders that made the frames,
    /// which on a 4K title cost 100 to 160 MB each.
    private func endPreviews() {
        preview = nil
        let engine = engine
        Task { await engine.releaseScrubPreviewDecoders() }
    }

    /// Asks the engine for a frame at `seconds`; while one is being made, only the latest ask waits.
    private func wantPreview(_ seconds: Double) {
        // From the engine where it holds the bytes, else the server's trickplay; else the time alone.
        guard scrubPreviews, engine.supportsCacheBackedStills || trickplay != nil else { return }
        previewWanted = seconds
        guard !previewBusy else { return }
        previewBusy = true
        Task { [weak self] in
            guard let self else { return }
            let image = await self.picture(at: seconds)
            self.previewBusy = false
            guard self.scrubTarget != nil else { return }
            if let image { self.preview = image }
            if let wanted = self.previewWanted, wanted != seconds { self.wantPreview(wanted) }
        }
    }
    /// How many times faster than playback the scrub moves, for its badge; negative backwards.
    @Published private(set) var scrubSpeed = 0
    private var scrubTask: Task<Void, Never>?
    private var scrubDirection = 0
    var scrubbing: Bool { scrubTask != nil }

    /// Scrubs while left or right is held, faster the longer it's held: 10x, then 30x after
    /// 1.5 s, 60x after 3 s and 120x from 5 s. Letting go seeks there once.
    /// Asking again in the same direction carries on; the other way turns round from where it got to.
    func startScrub(_ direction: Int) {
        if scrubTask != nil && scrubDirection == direction { return }
        scrubTask?.cancel()
        scrubDirection = direction
        scrubTarget = scrubTarget ?? position
        let tick = 0.2
        scrubTask = Task { [weak self] in
            var held = 0.0
            while !Task.isCancelled {
                guard let self else { return }
                let rate: Double = held < 1.5 ? 10 : held < 3 ? 30 : held < 5 ? 60 : 120
                self.scrubSpeed = direction * Int(rate)
                let next = (self.scrubTarget ?? self.position) + Double(direction) * rate * tick
                self.scrubTarget = min(max(next, 0), max(self.duration - 1, 0))
                held += tick
                try? await Task.sleep(for: .milliseconds(Int(tick * 1000)))
            }
        }
    }

    func endScrub() {
        scrubTask?.cancel()
        scrubTask = nil
        scrubDirection = 0
        if let target = scrubTarget { seek(to: target) }
        scrubTarget = nil
        scrubSpeed = 0
    }

    // MARK: Swiping while paused

    private var swipeFrom: Double?

    /// A swipe across the remote while paused: the whole surface is a quarter of the video,
    /// and never less than two minutes, so a few quick swipes cross any of it.
    func startSwipe() {
        swipeFrom = scrubTarget ?? position
        scrubTarget = swipeFrom
    }

    func swipe(_ share: Double) {
        guard let swipeFrom else { return }
        let span = max(duration / 4, 120)
        scrubTarget = min(max(swipeFrom + share * span, 0), max(duration - 1, 0))
    }

    /// Lifting the finger seeks there once; playback stays paused.
    func endSwipe() {
        swipeFrom = nil
        if let target = scrubTarget { seek(to: target) }
        scrubTarget = nil
    }

    func seek(to seconds: Double) {
        let target = min(max(seconds, 0), max(duration - 1, 0))
        if inParty {
            WatchParty.shared.request(["type": "Seek", "positionMs": target * 1000])
            return
        }
        position = target
        Task { await engine.seek(to: target) }
    }

    func setSpeed(_ value: Double) {
        // Everyone in a watch party plays at the same speed.
        guard party == nil else { return }
        speed = value
        engine.setRate(Float(heldRate ?? value))
    }

    /// Held speed: faster while Select is held on the video, back to the speed set once it's let go.
    @Published private(set) var heldRate: Double?

    func hold(_ rate: Double?) {
        guard party == nil else { return }
        heldRate = rate
        engine.setRate(Float(rate ?? speed))
    }

    /// Seek bar previews: frames of where a scrub would land, which cost a little data each.
    var scrubPreviews = true

    // MARK: Subtitle lift

    /// The user's subtitle style, which the lift raises from.
    private var baseLook = SubtitleLook()
    /// The share of the screen the subtitles are kept above now.
    private var lift: Double = 0
    private var liftTask: Task<Void, Never>?

    /// Keeps the subtitles above `share` of the screen's height, which the controls cover, or back
    /// to their own height at 0, sliding over the web app's 300 ms (SUBTITLE_LIFT_MS).
    func liftSubtitles(_ share: Double) {
        let target = min(max(share, 0), 0.9)
        guard abs(target - lift) > 0.001 else { return }
        liftTask?.cancel()
        let from = lift
        let start = Date()
        liftTask = Task { [weak self] in
            while !Task.isCancelled {
                let done = min(1, Date().timeIntervalSince(start) / 0.3)
                // The web app's ease, 1 - (1 - t)^3.
                let value = from + (target - from) * (1 - pow(1 - done, 3))
                self?.applyLift(value)
                if done >= 1 { return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func applyLift(_ value: Double) {
        lift = value
        var look = baseLook
        // Percent from the top where the bottom line sits: the higher of the user's own and the controls'.
        look.position = min(baseLook.position, 100 - value * 100)
        overlay.look = look
    }

    func setFit(_ value: Fit) {
        fit = value
        engine.videoGravity = value.gravity
        overlay.gravity = value.gravity
    }

    func skip(_ seconds: Double) {
        seek(to: position + seconds)
    }

    func selectAudio(_ id: Int) {
        engine.selectAudioTrack(index: id)
        // Kept for the show's other episodes; picking what the settings would play forgets it.
        if remember.audio, let userId, let language = LanguageCodes.normal(audioTracks.first(where: { $0.id == id })?.language) {
            let usual = LanguageCodes.normal(LanguageCodes.first(baseTracks.audioLanguages, in: audioTracks, language: \.language)?.first?.language)
            ShowPicks.shared.save(for: request.item, audio: .some(language == usual ? nil : language), subtitle: nil,
                                  client: client, userId: userId)
        }
        report("/Sessions/Playing/Progress", event: "AudioTrackChange")
    }

    /// A track named by the server's stream index, as a remote names it: the file's own streams by
    /// their index, the server's subtitle files by their place among them; below zero, no subtitles.
    func selectServerTrack(audio: Bool, index: Int) {
        if audio {
            if audioTracks.contains(where: { $0.id == index }) { selectAudio(index) }
            return
        }
        guard index >= 0 else { return selectSubtitle(nil) }
        let streams = request.source.mediaStreams ?? []
        if let stream = streams.first(where: { $0.index == index }), stream.isExternal == true {
            if let at = serverStreams().firstIndex(of: stream) { selectSubtitle(AetherEngine.externalSubtitleTrackIDBase + at) }
        } else if let later = laterTrackIDs[index] {
            selectSubtitle(later)
        } else if subtitleTracks.contains(where: { $0.id == index }) {
            selectSubtitle(index)
        }
    }

    func selectSubtitle(_ id: Int?) {
        subtitleChosen = true
        if let id { engine.selectSubtitleTrack(index: id) } else { engine.clearSubtitle() }
        if remember.subtitles, let userId {
            let track = id.flatMap { id in subtitleTracks.first { $0.id == id } }
            let pick: String?
            if let track {
                let language = LanguageCodes.normal(track.language) ?? ""
                let kind = SubtitleKind.of(title: track.name, forced: track.isForced, hearingImpaired: track.isHearingImpaired)
                pick = kind.map { $0 == .normal ? language : "\(language):\($0.rawValue)" } ?? language
            } else {
                pick = "off"
            }
            // Picking what the settings would show forgets the pick.
            let usual = LanguageCodes.first(baseTracks.subtitleLanguages, in: subtitleTracks, language: \.language)?.first
            let wouldShow = !["None", "OnlyForced"].contains(baseTracks.subtitleMode)
            let same = track.map { $0.id == usual?.id && wouldShow } ?? !wouldShow
            ShowPicks.shared.save(for: request.item, audio: nil, subtitle: .some(same ? nil : pick), client: client, userId: userId)
        }
        report("/Sessions/Playing/Progress", event: "SubtitleTrackChange")
    }

    private func body(_ extra: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = [
            "ItemId": request.item.id,
            "MediaSourceId": request.source.ownId,
            "PositionTicks": Int64(position * 1000 * JellyfinClient.ticksPerMs),
            "IsPaused": paused,
            "CanSeek": !isLive,
            "PlayMethod": "DirectPlay",
        ]
        // The length the player measured, for a title whose runtime the server doesn't know (v2.38).
        if !isLive, duration.isFinite, duration > 0 {
            body["RunTimeTicks"] = Int64(duration * 1000 * JellyfinClient.ticksPerMs)
        }
        if let session = request.playSessionId { body["PlaySessionId"] = session }
        return body.merging(extra) { _, new in new }
    }

    private func report(_ path: String, event: String? = nil) {
        guard !stopped, !request.isTrailer else { return }
        if path == "/Sessions/Playing" { reported = true }
        let payload = body(event.map { ["EventName": $0] } ?? [:])
        let client = client
        Task { await client.fire(path, body: payload) }
    }

    /// Saves the position on the server and hands the screen back to the app.
    func stop() {
        guard !stopped else { return }
        if wroteCriteria { Self.window?.avDisplayManager.preferredDisplayCriteria = nil }
        party?.stop()
        party = nil
        progressTimer?.invalidate()
        loadTask?.cancel()
        if reported {
            let payload = body()
            let client = client
            Task { await client.fire("/Sessions/Playing/Stopped", body: payload) }
        }
        stopped = true
        bag.removeAll()
        overlay.clear()
        // The plain stop returns the TV to its default mode for the app's own screens.
        engine.stop()
    }
}

/// The engine's picture with the subtitles over it.
struct VideoSurface: UIViewRepresentable {
    let model: PlayerModel

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        let video = AetherPlayerView()
        for view in [video, model.overlay] as [UIView] {
            view.frame = container.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(view)
        }
        model.engine.bind(view: video)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}


/// A chapter as the player lists it: from the file, or from the server with its picture.
struct PlayerChapter: Identifiable, Hashable {
    let id: Int
    let name: String
    let start: Double
    let image: URL?
}
