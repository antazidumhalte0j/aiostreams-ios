import AVFoundation
import SwiftUI

@main
struct AIOStreamsTVApp: App {
    @StateObject private var session = Session()
    @StateObject private var prefs = Preferences()

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        AppLog.info("app", "started \(AppInfo.version) on \(AppInfo.deviceModel) tvOS \(UIDevice.current.systemVersion)")
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch session.stage {
                case .needsServer: ServerView()
                case .needsSignIn: SignInView()
                case .signedIn: MainView()
                }
            }
            // The web app's theme colours, once they've loaded.
            .id(prefs.themeKey)
            .environmentObject(session)
            .environmentObject(prefs)
            .preferredColorScheme(.dark)
            // Screenshot mode only: the demo server's sign-in.
            .task { await DemoMode.start(session) }
            .tint(Theme.ring)
        }
    }
}

/// A message under a screen, for what went wrong.
struct ErrorText: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(Theme.font(Theme.sm))
                .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                .multilineTextAlignment(.center)
        }
    }
}

/// The sign-in screens' backdrop: the page's black with a faint glow from the top.
struct WelcomeBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(
                colors: [Color(red: 30 / 255, green: 32 / 255, blue: 70 / 255).opacity(0.8), .clear],
                center: .top,
                startRadius: 0,
                endRadius: Theme.px(620)
            )
        }
        .ignoresSafeArea()
    }
}

struct ServerView: View {
    @EnvironmentObject private var session: Session
    @State private var address = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        ZStack {
            WelcomeBackground()
            VStack(spacing: Theme.px(24)) {
                BrandLogo(height: Theme.px(64))
                Text("Connect to your server")
                    .font(Theme.font(Theme.xl2, .semibold))
                    .foregroundStyle(Theme.gray200)
                Text("Use the address from your configure page: Save & Install → Jellyfin apps → Connect. With a share alias it's short, like your-instance/jellyfin/u/alias.")
                    .font(Theme.font(Theme.sm))
                    .foregroundStyle(Theme.gray400)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: Theme.px(560))
                TextField("Server address", text: $address)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(Theme.font(Theme.base))
                    .frame(maxWidth: Theme.px(560))
                    .onSubmit(connect)
                Button(working ? "Connecting…" : "Connect", action: connect)
                    .buttonStyle(PrimaryPillStyle())
                    .disabled(working || address.trimmingCharacters(in: .whitespaces).isEmpty)
                ErrorText(text: error)
            }
            .foregroundStyle(.white)
        }
    }

    private func connect() {
        guard !working else { return }
        working = true
        error = nil
        Task {
            do {
                try await session.connect(to: address)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// "Who's watching?", as the web app asks on a TV: the configuration's users, then a password
/// where one is set; or Quick Connect, or a name typed in.
struct SignInView: View {
    private enum Mode: Equatable {
        case pick
        case password(PublicUser)
        case manual
        case quickConnect
    }

    @EnvironmentObject private var session: Session
    @State private var mode: Mode = .pick
    @State private var users: [PublicUser] = []
    @State private var loaded = false
    @State private var quickConnectEnabled = false
    @State private var code: String?
    @State private var name = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @State private var poll: Task<Void, Never>?

    var body: some View {
        ZStack {
            WelcomeBackground()
            VStack(spacing: Theme.px(28)) {
                BrandLogo(height: Theme.px(64))
                switch mode {
                case .pick: picker
                case .password(let user): passwordForm(user)
                case .manual: manualForm
                case .quickConnect: quickConnectPanel
                }
                ErrorText(text: error)
            }
            .foregroundStyle(.white)
        }
        .task { await load() }
        .onDisappear { poll?.cancel() }
        .onChange(of: mode) { _, mode in
            error = nil
            if mode == .quickConnect { startQuickConnect() } else { poll?.cancel() }
        }
        .onExitCommand(perform: mode == .pick ? nil : { mode = .pick })
    }

    private var picker: some View {
        VStack(spacing: Theme.px(28)) {
            Text(users.isEmpty && loaded ? "Sign in" : "Who's watching?")
                .font(Theme.font(Theme.xl2, .semibold))
                .foregroundStyle(Theme.gray200)
            if !users.isEmpty {
                HStack(spacing: Theme.px(40)) {
                    ForEach(users) { user in
                        Button {
                            name = user.name ?? ""
                            password = ""
                            if user.hasPassword == false { signIn() } else { mode = .password(user) }
                        } label: {
                            UserAvatar(user: user, url: avatarURL(user))
                        }
                        .buttonStyle(AvatarStyle())
                    }
                }
                .focusSection()
            } else if !loaded {
                ProgressView()
            }
            HStack(spacing: Theme.px(8)) {
                Button("Other user") { name = ""; password = ""; mode = .manual }
                if quickConnectEnabled { Button("Quick Connect") { mode = .quickConnect } }
                Button("Change server") { session.forgetServer() }
            }
            .buttonStyle(SoftPillStyle())
            .padding(.top, Theme.px(8))
            .focusSection()
        }
    }

    private func passwordForm(_ user: PublicUser) -> some View {
        VStack(spacing: Theme.px(20)) {
            UserAvatar(user: user, url: avatarURL(user))
            Text("Password for \(user.name ?? "this user")")
                .font(Theme.font(Theme.xl, .semibold))
                .foregroundStyle(Theme.gray200)
            Text("If the user has a PIN, add it after the password with a /, like password/1234.")
                .font(Theme.font(Theme.sm))
                .foregroundStyle(Theme.gray400)
            SecureField("Password", text: $password)
                .font(Theme.font(Theme.base))
                .frame(maxWidth: Theme.px(440))
                .onSubmit(signIn)
            HStack(spacing: Theme.px(12)) {
                Button(working ? "Signing in…" : "Sign in", action: signIn)
                    .buttonStyle(PrimaryPillStyle())
                    .disabled(working)
                Button("Back") { mode = .pick }.buttonStyle(SecondaryPillStyle())
            }
        }
    }

    private var manualForm: some View {
        VStack(spacing: Theme.px(20)) {
            Text("Sign in")
                .font(Theme.font(Theme.xl2, .semibold))
                .foregroundStyle(Theme.gray200)
            TextField("Name", text: $name)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(Theme.font(Theme.base))
                .frame(maxWidth: Theme.px(440))
            SecureField("Password, and /PIN if the user has one", text: $password)
                .font(Theme.font(Theme.base))
                .frame(maxWidth: Theme.px(440))
                .onSubmit(signIn)
            HStack(spacing: Theme.px(12)) {
                Button(working ? "Signing in…" : "Sign in", action: signIn)
                    .buttonStyle(PrimaryPillStyle())
                    .disabled(working || name.isEmpty)
                Button("Back") { mode = .pick }.buttonStyle(SecondaryPillStyle())
            }
        }
    }

    private var quickConnectPanel: some View {
        VStack(spacing: Theme.px(20)) {
            Text("Quick Connect")
                .font(Theme.font(Theme.xl2, .semibold))
                .foregroundStyle(Theme.gray200)
            if let code {
                Text(code)
                    .font(Theme.font(64, .bold))
                    .monospacedDigit()
                    .kerning(Theme.px(8))
            } else {
                ProgressView().frame(height: Theme.px(80))
            }
            Text("On your configure page, open Save & Install → Jellyfin apps → Connect, type this code into the Quick Connect box and approve it.")
                .font(Theme.font(Theme.sm))
                .foregroundStyle(Theme.gray400)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Theme.px(560))
            Button("Back") { mode = .pick }.buttonStyle(SoftPillStyle())
        }
    }

    private func avatarURL(_ user: PublicUser) -> URL? {
        guard let client = session.client, let tag = user.primaryImageTag else { return nil }
        return client.url("/Users/\(user.id)/Images/Primary", ["tag": tag, "fillHeight": "240", "quality": "90"])
    }

    private func load() async {
        guard let client = session.client else { return }
        // A picker address lists its users, as a Jellyfin server does.
        users = (try? await client.get("/Users/Public") as [PublicUser]) ?? []
        quickConnectEnabled = (try? await client.get("/QuickConnect/Enabled") as Bool) ?? false
        loaded = true
        if users.isEmpty { mode = quickConnectEnabled ? .quickConnect : .manual }
    }

    private func startQuickConnect() {
        guard let client = session.client else { return }
        poll?.cancel()
        code = nil
        poll = Task {
            do {
                let started: QuickConnectState = try await client.post("/QuickConnect/Initiate")
                code = started.code
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(4))
                    let state: QuickConnectState = try await client.get("/QuickConnect/Connect", ["Secret": started.secret])
                    if state.authenticated == true {
                        let result: AuthResult = try await client.post(
                            "/Users/AuthenticateWithQuickConnect",
                            body: ["Secret": started.secret]
                        )
                        session.signIn(result)
                        return
                    }
                }
            } catch is CancellationError {
            } catch {
                // A code lasts a few minutes; a new one replaces it.
                if !Task.isCancelled {
                    AppLog.info("signin", "quick connect: \(error.localizedDescription)")
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled, mode == .quickConnect { startQuickConnect() }
                }
            }
        }
    }

    private func signIn() {
        guard let client = session.client, !working, !name.isEmpty else { return }
        working = true
        error = nil
        Task {
            do {
                let result: AuthResult = try await client.post(
                    "/Users/AuthenticateByName",
                    body: ["Username": name, "Pw": password]
                )
                poll?.cancel()
                session.signIn(result)
            } catch let failure as JellyfinError where failure.status == 401 {
                error = "That password doesn't match."
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// A user's picture, or their initial on a colour of their own, with their name under it.
struct UserAvatar: View {
    let user: PublicUser
    let url: URL?

    private static let colours: [Color] = [
        Color(red: 0.76, green: 0.71, blue: 0.89), Color(red: 0.72, green: 0.87, blue: 0.95),
        Color(red: 1.0, green: 0.85, blue: 0.88), Color(red: 0.82, green: 0.95, blue: 0.84),
        Color(red: 0.99, green: 0.89, blue: 0.72),
    ]

    var body: some View {
        VStack(spacing: Theme.px(12)) {
            ZStack {
                Circle().fill(Self.colours[user.id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.colours.count])
                Text(String((user.name ?? "?").prefix(1)).uppercased())
                    .font(Theme.font(44, .bold))
                    .foregroundStyle(.black.opacity(0.75))
                if let url {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase { image.resizable().aspectRatio(contentMode: .fill) }
                    }
                }
            }
            .frame(width: Theme.px(112), height: Theme.px(112))
            .clipShape(Circle())
            Text(user.name ?? "User")
                .font(Theme.font(15))
                .foregroundStyle(Theme.gray200)
        }
    }
}

/// The ring goes round the picture alone, not its name.
private struct AvatarStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AvatarFocus(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct AvatarFocus<Label: View>: View {
        @Environment(\.isFocused) private var focused
        let label: Label
        let pressed: Bool

        var body: some View {
            label
                .overlay(alignment: .top) {
                    if focused {
                        Circle()
                            .stroke(Theme.ring, lineWidth: Theme.ringWidth)
                            .frame(width: Theme.px(112) + 2 * Theme.ringOffset + Theme.ringWidth,
                                   height: Theme.px(112) + 2 * Theme.ringOffset + Theme.ringWidth)
                            .offset(y: -(Theme.ringOffset + Theme.ringWidth / 2))
                    }
                }
                .scaleEffect(focused ? 1.05 : 1)
                .opacity(pressed ? 0.85 : 1)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}
