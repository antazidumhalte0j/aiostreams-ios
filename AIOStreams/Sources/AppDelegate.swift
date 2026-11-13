import AVFoundation
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// Which way the screen may turn; full screen holds it in landscape.
    static var orientations: UIInterfaceOrientationMask = .allButUpsideDown

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Sound plays with the ringer switch on silent, and on in the background.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        AppLog.info("app", "started \(AppInfo.version) on \(AppInfo.deviceModel) iOS \(UIDevice.current.systemVersion)")
        return true
    }

    /// Background downloads finished or need attention while the app was closed: the queue takes
    /// their events and calls this when it has handled them.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == DownloadQueue.sessionID else { return completionHandler() }
        DownloadQueue.shared.backgroundCompletion = completionHandler
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppDelegate.orientations
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var root: RootViewController?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let root = RootViewController()
        window.rootViewController = root
        window.backgroundColor = .black
        window.makeKeyAndVisible()
        self.window = window
        self.root = root
        // An `aiostreams://` link that started the app waits for the page to ask for it.
        for context in connectionOptions.urlContexts {
            root.openLink(context.url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            root?.openLink(context.url)
        }
    }
}
