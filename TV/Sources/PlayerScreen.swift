import AetherEngineFeatures
import SwiftUI

// The web app's player as a TV shows it: the title over the top, a purple progress bar with
// chapter marks, and a row of controls, which hide while the video plays. Hidden, the remote
// drives playback itself; shown, its buttons and the bar take focus.

struct PlayerScreen: View {
    let request: PlayRequest
    let close: () -> Void

    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @State private var model: PlayerModel?

    var body: some View {
        Group {
            if let model {
                PlayerChrome(model: model, close: finish)
            } else {
                Color.black
            }
        }
        .ignoresSafeArea()
        .onAppear {
            guard model == nil, let client = session.client else { return }
            let player = PlayerModel(
                request: request,
                client: client,
                audioLanguages: prefs.audioLanguages,
                subtitleLanguages: prefs.subtitleLanguages,
                look: prefs.subtitleLook,
                speakers: prefs.speakers
            )
            model = player
            player.start()
        }
    }

    private func finish() {
        model?.stop()
        close()
    }
}

private enum PlayerFocus: Hashable {
    case surface, bar, play, back, forward, tracks, chapters, speed, fit
}

private enum PlayerPanel: Hashable {
    case tracks, chapters, speed
}

private struct PlayerChrome: View {
    @ObservedObject var model: PlayerModel
    let close: () -> Void

    @State private var shown = true
    @State private var panel: PlayerPanel?
    @State private var hideTask: Task<Void, Never>?
    @State private var controlsTop: CGFloat?

    /// The share of the screen under the top of the controls, with a little room above them.
    private var liftShare: Double {
        guard let controlsTop else { return 0 }
        let height = UIScreen.main.bounds.height
        return height > 0 ? Double(1 - (controlsTop - Theme.px(8)) / height) : 0
    }
    @FocusState private var focus: PlayerFocus?
    /// A hold the press watcher reported, which only its letting go ends.
    @State private var pressHeld = false
    /// The last few left or right moves, which come quickly over and over while a direction is held.
    @State private var lastMove: (direction: Int, at: Date, count: Int)?
    @State private var moveHoldEnd: Task<Void, Never>?
    /// A swipe along the bar in progress, or just finished.
    @State private var swiping = false
    @State private var swipeSettled: Task<Void, Never>?

    private var canScrub: Bool {
        panel == nil && model.failure == nil && (!shown || focus == .bar || focus == .surface)
    }

    /// A move left or right, which reads as a hold once it repeats quickly, for remotes and
    /// directions that repeat their move while held. Returns whether it went to a scrub.
    private func moved(_ direction: Int) -> Bool {
        if pressHeld || swiping { return true }
        let now = Date()
        var count = 1
        if let last = lastMove, last.direction == direction, now.timeIntervalSince(last.at) < 0.4 {
            count = last.count + 1
        }
        lastMove = (direction, now, count)
        guard model.scrubbing || count >= 3, canScrub else { return false }
        model.startScrub(direction)
        moveHoldEnd?.cancel()
        moveHoldEnd = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, !pressHeld else { return }
            model.endScrub()
            lastMove = nil
            wake()
        }
        return true
    }

    var body: some View {
        ZStack {
            VideoSurface(model: model).ignoresSafeArea()

            // Holding left or right scrubs, while the controls are hidden or the bar has focus.
            PressHold(
                begin: { direction in
                    guard canScrub else { return false }
                    pressHeld = true
                    moveHoldEnd?.cancel()
                    model.startScrub(direction)
                    reveal(.bar)
                    return true
                },
                end: {
                    pressHeld = false
                    model.endScrub()
                    wake()
                }
            )
            .frame(width: 0, height: 0)

            // Swiping across the remote while paused, with the bar focused, slides along it.
            SwipeScrub(
                begin: {
                    guard model.paused, shown, focus == .bar, panel == nil, model.failure == nil,
                          !model.scrubbing else { return false }
                    swiping = true
                    swipeSettled?.cancel()
                    model.startSwipe()
                    return true
                },
                change: { model.swipe($0) },
                end: {
                    model.endSwipe()
                    // The focus engine's own moves from the swipe can trail it; those aren't skips.
                    swipeSettled = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        if !Task.isCancelled { swiping = false }
                    }
                    wake()
                }
            )
            .frame(width: 0, height: 0)

            // Takes the remote while the controls are hidden.
            Color.clear
                .contentShape(Rectangle())
                .focusable(!shown && panel == nil)
                .focused($focus, equals: .surface)
                .onMoveCommand { direction in
                    switch direction {
                    case .left: if !moved(-1) { model.skip(-10) }; reveal(.bar)
                    case .right: if !moved(1) { model.skip(10) }; reveal(.bar)
                    default: reveal(.play)
                    }
                }
                .onTapGesture { reveal(.play) }

            if model.waiting && model.failure == nil {
                ProgressView().scaleEffect(1.6)
            }
            if let failure = model.failure { failureCard(failure) }

            if shown {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }

            if let panel {
                HStack {
                    Spacer()
                    PlayerPanelView(model: model, panel: panel) { closePanel() }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .font(Theme.font(Theme.base))
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.2), value: shown)
        .animation(.easeOut(duration: 0.2), value: panel)
        .onPlayPauseCommand { model.togglePause(); wake() }
        .onExitCommand {
            if panel != nil { closePanel() }
            else if shown && model.failure == nil { hide() }
            else { close() }
        }
        .onAppear { focus = .play; wake() }
        .onChange(of: focus) { _, _ in if shown { wake() } }
        // The subtitles rise over the controls while they show, and settle back as they hide.
        .onChange(of: shown) { _, shown in model.liftSubtitles(shown ? liftShare : 0) }
        .onChange(of: model.finished) { _, done in if done { close() } }
        .onChange(of: model.paused) { _, paused in if paused { reveal(nil) } else { wake() } }
    }

    // MARK: Top

    private var topBar: some View {
        HStack(spacing: Theme.px(16)) {
            Image(systemName: "arrow.left").font(.system(size: Theme.px(20), weight: .medium))
            VStack(alignment: .leading, spacing: Theme.px(2)) {
                Text(model.request.item.isEpisode ? (model.request.item.seriesName ?? "") : (model.request.item.name ?? ""))
                    .font(Theme.font(17, .semibold))
                    .lineLimit(1)
                if model.request.item.isEpisode {
                    Text(model.request.item.displayTitle)
                        .font(Theme.font(Theme.sm))
                        .foregroundStyle(Theme.gray300)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Theme.px(32))
        .padding(.top, Theme.px(28))
        .padding(.bottom, Theme.px(48))
        .background(
            LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: Bottom

    private var bottomBar: some View {
        VStack(spacing: Theme.px(14)) {
            ProgressTrack(model: model, focused: focus == .bar)
                .focusable(shown && panel == nil)
                .focused($focus, equals: .bar)
                .onMoveCommand { direction in
                    switch direction {
                    case .left: if !moved(-1) { model.skip(-10) }
                    case .right: if !moved(1) { model.skip(10) }
                    case .down: if !swiping { focus = .play }
                    default: break
                    }
                    wake()
                }
                .onTapGesture { model.togglePause(); wake() }
            if model.scrubSpeed != 0 {
                HStack(spacing: Theme.px(8)) {
                    Image(systemName: model.scrubSpeed > 0 ? "forward.fill" : "backward.fill")
                    Text("\(abs(model.scrubSpeed))×").monospacedDigit()
                }
                .font(Theme.font(Theme.base, .semibold))
                .padding(.horizontal, Theme.px(14))
                .padding(.vertical, Theme.px(6))
                .background(Capsule().fill(.black.opacity(0.6)))
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            }
            HStack(spacing: Theme.px(8)) {
                Button { model.togglePause() } label: {
                    Image(systemName: model.paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(BigPlayStyle())
                .focused($focus, equals: .play)
                Button { model.skip(-10) } label: { Image(systemName: "gobackward.10") }
                    .buttonStyle(ControlIconStyle())
                    .focused($focus, equals: .back)
                Button { model.skip(10) } label: { Image(systemName: "goforward.10") }
                    .buttonStyle(ControlIconStyle())
                    .focused($focus, equals: .forward)
                HStack(spacing: 0) {
                    Text(clock(model.scrubTarget ?? model.position))
                    Text(" / " + clock(model.duration)).foregroundStyle(Theme.gray400)
                }
                .font(Theme.font(17, .medium))
                .monospacedDigit()
                .padding(.leading, Theme.px(12))
                Spacer()
                Button { open(.tracks) } label: { Image(systemName: "captions.bubble") }
                    .buttonStyle(ControlIconStyle())
                    .focused($focus, equals: .tracks)
                if !model.chapters.isEmpty {
                    Button { open(.chapters) } label: { Image(systemName: "list.bullet") }
                        .buttonStyle(ControlIconStyle())
                        .focused($focus, equals: .chapters)
                }
                Button { open(.speed) } label: { Image(systemName: "gauge.with.dots.needle.50percent") }
                    .buttonStyle(ControlIconStyle())
                    .focused($focus, equals: .speed)
                Button {
                    let all = PlayerModel.Fit.allCases
                    model.setFit(all[(all.firstIndex(of: model.fit)! + 1) % all.count])
                } label: {
                    Image(systemName: model.fit == .fit ? "rectangle.arrowtriangle.2.outward" : model.fit == .crop ? "crop" : "arrow.left.and.right.square")
                }
                .buttonStyle(ControlIconStyle())
                .focused($focus, equals: .fit)
            }
            .focusSection()
        }
        // Where the controls start, which the subtitles are kept above while they show.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).minY
        } action: { top in
            controlsTop = top
            if shown { model.liftSubtitles(liftShare) }
        }
        .padding(.horizontal, Theme.px(20))
        .padding(.bottom, Theme.px(16))
        .padding(.top, Theme.px(64))
        .background(
            LinearGradient(colors: [.black.opacity(0.9), .black.opacity(0.5), .clear], startPoint: .bottom, endPoint: .top)
        )
    }

    private func failureCard(_ failure: String) -> some View {
        VStack(spacing: Theme.px(12)) {
            Text("This version didn't play").font(Theme.font(Theme.xl, .semibold))
            Text(failure).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray300).multilineTextAlignment(.center)
            Text("Press Back to pick another version.").font(Theme.font(Theme.xs)).foregroundStyle(Theme.gray400)
        }
        .padding(Theme.px(32))
        .frame(maxWidth: Theme.px(560))
        .background(RoundedRectangle(cornerRadius: Theme.px(16)).fill(Color(white: 17 / 255).opacity(0.95)))
    }

    // MARK: Showing and hiding

    /// Shows the controls, focusing `target` where given.
    private func reveal(_ target: PlayerFocus?) {
        shown = true
        if let target { focus = target }
        wake()
    }

    private func hide() {
        hideTask?.cancel()
        shown = false
        focus = .surface
    }

    /// Hides the controls a few seconds after the last press, while the video plays.
    private func wake() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, !model.paused, panel == nil, model.failure == nil, !DemoMode.holdsControls,
                  model.scrubTarget == nil else { return }
            hide()
        }
    }

    private func open(_ which: PlayerPanel) {
        hideTask?.cancel()
        panel = which
    }

    private func closePanel() {
        let from = panel
        panel = nil
        switch from {
        case .tracks: focus = .tracks
        case .chapters: focus = .chapters
        case .speed: focus = .speed
        case nil: break
        }
        wake()
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds.isFinite ? max(seconds, 0) : 0)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The bar across the bottom: played in the accent, held ahead lighter, gaps at chapter starts.
private struct ProgressTrack: View {
    @ObservedObject var model: PlayerModel
    let focused: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let share = { (seconds: Double) -> CGFloat in
                model.duration > 0 ? CGFloat(min(max(seconds / model.duration, 0), 1)) * width : 0
            }
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white.opacity(0.35)).frame(width: share(model.buffered))
                Capsule().fill(Theme.ring).frame(width: share(model.scrubTarget ?? model.position))
                ForEach(model.chapters.dropFirst(), id: \.id) { chapter in
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: Theme.px(3))
                        .offset(x: share(chapter.startSeconds) - Theme.px(1.5))
                }
                Circle()
                    .fill(.white)
                    .frame(width: Theme.px(14), height: Theme.px(14))
                    .offset(x: share(model.scrubTarget ?? model.position) - Theme.px(7))
                    .opacity(focused || model.scrubTarget != nil ? 1 : 0)
            }
            .frame(height: focused ? Theme.px(8) : Theme.px(4))
            .frame(maxHeight: .infinity)
        }
        .frame(height: Theme.px(16))
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// The big white play button.
private struct BigPlayStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inner(label: configuration.label)
    }

    private struct Inner<Label: View>: View {
        @Environment(\.isFocused) private var focused
        let label: Label

        var body: some View {
            label
                .font(.system(size: Theme.px(20), weight: .bold))
                .foregroundStyle(.black)
                .frame(width: Theme.px(52), height: Theme.px(52))
                .background(Circle().fill(.white))
                .focusRing(focused)
        }
    }
}

/// A bare icon in the control row, lit and ringed when focused.
private struct ControlIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inner(label: configuration.label)
    }

    private struct Inner<Label: View>: View {
        @Environment(\.isFocused) private var focused
        let label: Label

        var body: some View {
            label
                .font(.system(size: Theme.px(22), weight: .regular))
                .foregroundStyle(focused ? Color.white : Color.white.opacity(0.85))
                .frame(width: Theme.px(44), height: Theme.px(44))
                .background(Circle().fill(focused ? Color.white.opacity(0.16) : .clear))
                .focusRing(focused)
        }
    }
}

/// A list beside the video: audio and subtitles, chapters, or speed.
private struct PlayerPanelView: View {
    @ObservedObject var model: PlayerModel
    let panel: PlayerPanel
    let done: () -> Void

    private static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.px(20)) {
                switch panel {
                case .tracks:
                    group("Subtitles") {
                        row("Off", on: model.activeSubtitle == nil) { model.selectSubtitle(nil) }
                        ForEach(model.subtitleTracks) { track in
                            row(label(track), on: track.id == model.activeSubtitle) { model.selectSubtitle(track.id) }
                        }
                    }
                    group("Audio") {
                        ForEach(model.audioTracks) { track in
                            row(label(track), on: track.id == model.activeAudio) { model.selectAudio(track.id) }
                        }
                    }
                case .chapters:
                    group("Chapters") {
                        ForEach(model.chapters, id: \.id) { chapter in
                            row(chapter.name.isEmpty ? "Chapter \(chapter.id + 1)" : chapter.name,
                                detail: clock(chapter.startSeconds),
                                on: false) {
                                model.seek(to: chapter.startSeconds)
                                done()
                            }
                        }
                    }
                case .speed:
                    group("Speed") {
                        ForEach(Self.speeds, id: \.self) { value in
                            row(value == 1 ? "Normal" : String(format: "%g×", value), on: abs(model.speed - value) < 0.01) {
                                model.setSpeed(value)
                            }
                        }
                    }
                }
            }
            .padding(Theme.px(20))
        }
        .frame(width: Theme.px(400))
        .frame(maxHeight: .infinity)
        .background(Color(white: 11 / 255).opacity(0.95))
        .focusSection()
        .onExitCommand(perform: done)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.px(4)) {
            Text(title)
                .font(Theme.font(Theme.sm, .semibold))
                .foregroundStyle(Theme.gray400)
                .padding(.horizontal, Theme.px(12))
                .padding(.bottom, Theme.px(4))
            content()
        }
    }

    private func row(_ text: String, detail: String? = nil, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.px(10)) {
                Image(systemName: "checkmark")
                    .font(.system(size: Theme.px(13), weight: .semibold))
                    .opacity(on ? 1 : 0)
                Text(text).font(Theme.font(15)).lineLimit(1)
                Spacer(minLength: Theme.px(8))
                if let detail {
                    Text(detail).font(Theme.font(Theme.xs)).foregroundStyle(Theme.gray400).monospacedDigit()
                }
            }
            .padding(.horizontal, Theme.px(12))
            .frame(height: Theme.px(40))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PanelRowStyle())
    }

    private func label(_ track: TrackInfo) -> String {
        var parts: [String] = []
        if !track.name.isEmpty { parts.append(track.name) }
        if let language = track.language, !language.isEmpty, !track.name.localizedCaseInsensitiveContains(language) {
            parts.append(Locale.current.localizedString(forLanguageCode: language) ?? language)
        }
        if track.isForced { parts.append("Forced") }
        if track.isExternal { parts.append("Addon") }
        return parts.isEmpty ? "Track \(track.id)" : parts.joined(separator: " · ")
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct PanelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inner(label: configuration.label)
    }

    private struct Inner<Label: View>: View {
        @Environment(\.isFocused) private var focused
        let label: Label

        var body: some View {
            label
                .foregroundStyle(focused ? Color.black : Color.white)
                .background(
                    RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous)
                        .fill(focused ? Color.white : Color.clear)
                )
        }
    }
}
