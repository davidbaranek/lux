import LuxCore
import UIKit
import UserNotifications

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// The one account of the app, shared by its scene and by what the app does without one
    /// (a notification's action, when the system launched the app in the background for it).
    /// `-LuxDemo` (UI tests, screenshots): made-up chats, no account.
    static let session = LaunchOptions.isDemo ? Session.demo(preferences: .shared) : Session(preferences: .shared)
    /// Set before launching ends, so a notification that launched the app reaches it.
    static let notifications = Notifications(session: session)
    /// Registered before launching ends, as the system requires; none for the demo (no server).
    static let refresh: BackgroundRefresh? = LaunchOptions.isDemo ? nil : BackgroundRefresh(session: session)
    /// Uploads go on in the background, whichever account sends them; registered before
    /// launching ends.
    static let uploads = BackgroundUploads(session: session)
    /// Search reads what it has left while the iPhone charges; registered before launching ends.
    static let reading = ReadingWhileCharging(session: session)

    func application(_ application: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        _ = Self.notifications
        _ = Self.refresh
        _ = Self.uploads
        _ = Self.reading
        return true
    }

    /// The system ends the app while it runs in the background (a suspended app is ended without
    /// notice, which a store's write-ahead log survives): UIKit exits the process once this
    /// returns, and the account's session closes first, within the seconds the system gives.
    func applicationWillTerminate(_ application: UIApplication) {
        Self.session.closeBeforeReturning(within: .seconds(4))
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

    func sceneDidEnterBackground(_ scene: UIScene) {
        // the sync and the long work (index, photos, the model) end before iOS suspends the app,
        // under a background task. The sync first and at once: it closes the stores in the App
        // Group, and a lock held there as the app is suspended ends it (0xdead10cc). The long
        // work's files are the app's own; loading the model cannot be cut short, and the stores
        // do not wait for it.
        endingWork = UIApplication.shared.beginBackgroundTask(withName: "leaving") { [weak self] in self?.endedWork() }
        // an upload in a continued processing task keeps the app running: its sync stays, and
        // stops as the task ends. Uploads the system does not run (yet) wait for the app's return.
        let paused = AppDelegate.uploads.keepsAppRunning ? nil : session.enterBackground()
        Task {
            await LongWork.shared.leave()
            await paused?.value
            endedWork()
        }
        // signed in: the chats refresh now and then while the app is away.
        if session.isSignedIn {
            AppDelegate.refresh?.schedule()
            // and what search has left is read while the iPhone charges.
            AppDelegate.reading.schedule()
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
        // the long work starts (the first time too), or goes on from a background task's reading.
        LongWork.shared.enter()
        notifications.showBadge()
    }

    private func show(signedIn: Bool) {
        guard let window else { return }
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
