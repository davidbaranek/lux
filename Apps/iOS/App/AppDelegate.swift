import LuxCore
import UIKit
import UserNotifications

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// The one account of the app, shared by its scene and by what the app does without one
    /// (a notification's action, when the system launched the app in the background for it).
    /// `-LuxDemo` (UI tests, screenshots): made-up chats, no account.
    static let session = LaunchOptions.isDemo ? Session.demo() : Session()
    /// Set before launching ends, so a notification that launched the app reaches it.
    static let notifications = Notifications(session: session)
    /// Registered before launching ends, as the system requires; none for the demo (no server).
    static let refresh: BackgroundRefresh? = LaunchOptions.isDemo ? nil : BackgroundRefresh(session: session)

    func application(_ application: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        _ = Self.notifications
        _ = Self.refresh
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Self.notifications.registered(token: token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.app.error("push registration: \(String(describing: error), privacy: .public)")
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let session = AppDelegate.session
    private let notifications = AppDelegate.notifications

    func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options _: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        // an account that cannot be opened after all (its sign-in revoked): back to signing in.
        session.onAccountLost = { [weak self] in self?.show(signedIn: false) }
        Task { await show(signedIn: session.restore()) }
    }

    private var backgroundUploads: BackgroundUploads?

    func sceneDidEnterBackground(_ scene: UIScene) {
        // the long work (index, photos, the model) and the sync end before iOS suspends the app:
        // a file held as it is suspended ends it. A background task gives the time to end them.
        endingWork = UIApplication.shared.beginBackgroundTask(withName: "leaving") { [weak self] in self?.endedWork() }
        let session = self.session
        Task {
            await ForegroundWork.shared.leave()
            // an upload in a continued processing task keeps the app running: its sync stays.
            if session.uploads?.isActive != true { await session.enterBackground() }
            endedWork()
        }
        // signed in: the chats refresh now and then while the app is away.
        if session.isSignedIn {
            AppDelegate.refresh?.schedule()
        }
    }

    /// The background task that ends the long work as the app leaves.
    private var endingWork = UIBackgroundTaskIdentifier.invalid

    private func endedWork() {
        guard endingWork != .invalid else { return }
        UIApplication.shared.endBackgroundTask(endingWork)
        endingWork = .invalid
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        session.enterForeground()
        ForegroundWork.shared.enter()
        notifications.showBadge()
    }

    private func show(signedIn: Bool) {
        guard let window else { return }
        // registered once, before any upload can ask for it (the account's uploads).
        if signedIn, backgroundUploads == nil, let uploads = session.uploads { backgroundUploads = BackgroundUploads(uploads: uploads) }
        if signedIn {
            let list = ChatListViewController(session: session, badge: { [notifications] in notifications.setBadge($0) }) { [weak self] in
                Task { await self?.session.signOut(); self?.show(signedIn: false) }
            }
            window.rootViewController = UINavigationController(rootViewController: list)
            notifications.openChat = { [weak list] room, thread in list?.openChat(roomId: room, thread: thread) }
            // another of the account's devices asks to verify: over whatever shows.
            session.security?.onRequest = { [weak window] verification in
                guard var top = window?.rootViewController else { return }
                while let presented = top.presentedViewController { top = presented }
                let sheet = UINavigationController(rootViewController: VerificationViewController(model: verification))
                sheet.isModalInPresentation = true
                top.present(sheet, animated: true)
            }
            // signed in, the list up: a moment later is when asking to notify makes sense (the
            // system asks only once). The demo has no server to push.
            if !LaunchOptions.isDemo {
                Task { [notifications] in
                    try? await Task.sleep(for: .seconds(2))
                    await notifications.enable()
                }
            }
        } else {
            notifications.openChat = nil
            session.security?.onRequest = nil
            notifications.setBadge(.empty)
            window.rootViewController = SignInViewController(session: session) { [weak self] in self?.show(signedIn: true) }
        }
    }
}
