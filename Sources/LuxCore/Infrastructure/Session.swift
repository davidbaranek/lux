import AuthenticationServices
import Foundation

/// The signed-in account, or none: restores it at launch, signs in through the server's account
/// page (MAS, OAuth), and signs out. The models read the account through it; the UI asks it for
/// the image pipeline, search and uploads.
@MainActor
public final class Session {
    public struct Configuration: Sendable {
        public var homeserver: String
        public var keychainService: String
        /// Nil: the build signs in with a password only.
        public var client: OAuthClient?
        /// Nil: the build registers no pusher.
        public var push: PushGateway?

        /// This build's, from its Info.plist (`AppIdentity`).
        public static let main = Configuration(
            homeserver: "matrix.org",
            keychainService: "\(AppIdentity.bundleId).session",
            client: AppIdentity.oauthClientURI.flatMap { uri in
                URL(string: "\(AppIdentity.bundleId):/callback").map { OAuthClient(name: appName, redirect: $0, uri: uri) }
            },
            push: AppIdentity.pushGateway.map { PushGateway(appId: "\(AppIdentity.bundleId).ios", url: $0) })

        /// What the server's pages and the account's devices call the app.
        public static let appName = "Lux"
    }

    /// The build has no OAuth client (`LUX_OAUTH_CLIENT_URI` in `Config/Lux.xcconfig`).
    public struct NoOAuthClient: LocalizedError {
        public var errorDescription: String? { String(localized: "This build can sign in with a password only.") }
    }

    /// The push gateway (Sygnal) that wakes the app through Apple's service: one app id per APNs
    /// environment, the sandbox's with `.dev` after it.
    public struct PushGateway: Sendable {
        public var appId: String
        public var url: URL
    }

    /// The app as the server's account page knows it.
    public struct OAuthClient: Sendable {
        public var name: String
        /// A custom scheme callback: MAS accepts one whose scheme is the reversed host of `uri`, or
        /// of a subdomain (`com.example.lux:/callback` for `https://example.com`).
        public var redirect: URL
        public var uri: URL
    }

    public let configuration: Configuration
    /// The app's settings on this device.
    public let preferences: Preferences
    /// Where the app keeps its files.
    private let paths: AppPaths
    /// The signed-in account and all that is its own; nil when signed out.
    private var current: AccountSession? {
        didSet {
            if current?.search !== oldValue?.search { searchChanges.send() }
            if current?.uploads !== oldValue?.uploads { uploadsChanges.send() }
        }
    }

    /// An account is signed in (it may still be opening).
    public var isSignedIn: Bool { current != nil }

    /// The account, once open: the models await it. Signed out, it fails at once.
    var account: Task<RustAccount, any Error> {
        current?.account ?? Task { throw SessionLost() }
    }

    /// Where the chat lists come from: the Rust core's view model over the account.
    var chatListSource: ChatListSource? { current?.chatListSource }

    /// A chat list at `place` with `filter`, in `order`, over the account; nil when signed out. It
    /// takes intents at once: before the account opens, they wait in the core, in order.
    func openChatList(place: Place, filter: ChatFilter?, order: ChatOrder, drafts: Set<String>) -> (any ChatListView)? {
        chatListSource.map { RustChatList($0, place: place, filter: filter, order: order, drafts: drafts) }
    }
    public var images: ImagePipeline? { current?.images }
    /// Photos and files on their way, from every chat (made with the account).
    public var uploads: Uploads? { current?.uploads }
    /// Another account's uploads, or none: signed in, out, or the account lost.
    public let uploadsChanges = Broadcast()
    /// The networks the server bridges, the account's logins on them and the history they bring
    /// (made with the account).
    public var networks: NetworksModel? { current?.networks }
    /// What this device needs for encryption, and the verifications other devices ask for (made
    /// with the account).
    public var security: SecurityModel? { current?.security }
    /// The account's own name and picture (made with the account).
    public var profile: ProfileModel? { current?.profile }
    /// Search: chats by name, messages from the encrypted index on this device.
    public var search: MessageSearch? { current?.search }
    /// The search index opened (a moment after the account) or closed.
    public let searchChanges = Broadcast()
    /// A message was scheduled from a chat: the list reads the waiting ones again.
    public let scheduledChanges = Broadcast()

    /// Originals opened from chats (photos, videos, files), kept in the caches with the thumbnails.
    public var originalsDirectory: URL { paths.originals }
    /// Attachments being sent, prepared from what the user picked.
    public var outgoingDirectory: URL { paths.outgoing }

    private let keychain: AccountKeychain
    /// The browser sheet of a sign-in in progress.
    private var authentication: WebAuthentication?

    public convenience init(configuration: Configuration = .main, preferences: Preferences) {
        self.init(configuration: configuration, paths: .main, preferences: preferences)
    }

    init(configuration: Configuration, paths: AppPaths, preferences: Preferences) {
        // the core's runtime, before the first call into it.
        CoreRuntime.start()
        self.configuration = configuration
        self.preferences = preferences
        self.paths = paths
        keychain = AccountKeychain(service: configuration.keychainService)
    }

    /// The app went to the background: the sync stops, before the system suspends it (the caller
    /// holds the time for it, a background task, and waits for the task this gives). Queued at
    /// once, in turn with the moves to the front.
    @discardableResult
    public func enterBackground() -> Task<Void, Never>? {
        current?.enterBackground()
    }

    /// The app is back in front (or the Mac woke): the sync runs again and the lists catch up.
    /// Queued at once, after the moves told before it.
    public func enterForeground() {
        current?.enterForeground()
    }

    /// A chat's details screen, of a chat in `list`: it tells which place keeps the chat out of
    /// the inbox.
    public func details(of row: ChatRow, in list: ChatListModel? = nil) -> ChatDetailsModel {
        ChatDetailsModel(account: Task { [account] in try await account.value }, row: row, list: list, originals: originalsDirectory,
                         preferences: preferences) { [weak self] in self?.search?.photos }
    }

    /// Where the demo's encryption starts.
    public enum DemoEncryption: Sendable {
        case ready, unverified, noRecovery

        /// As the launch arguments ask (`-LuxDemoUnverified`, `-LuxDemoNoRecovery`).
        public static var launched: DemoEncryption {
            LaunchOptions.demoUnverified ? .unverified : LaunchOptions.demoNoRecovery ? .noRecovery : .ready
        }
    }

    /// Demo data, for measurements and screenshots with no account (`-LuxDemo`): the Rust core's
    /// made-up account with `rooms` chats of `messagesPerRoom` messages, its encryption starting at
    /// `encryption`; with `verificationRequestAfter`, another of its devices asks to verify that
    /// many seconds after the app listens. Its files are its own, in `folder` (a new temporary one
    /// unless given): demo sessions side by side (the tests) never share one. Its settings are
    /// `preferences`.
    public static func demo(rooms: Int = 2_000, messagesPerRoom: Int = 3_000, encryption: DemoEncryption = .launched,
                            verificationRequestAfter: Int? = LaunchOptions.demoVerificationRequest ? 4 : nil,
                            folder: URL = FileManager.default.temporaryDirectory
                                .appending(path: "lux-\(UUID().uuidString)", directoryHint: .isDirectory),
                            preferences: Preferences) -> Session {
        let session = Session(configuration: .main, paths: .inside(folder), preferences: preferences)
        let account = RustAccount.demo(rooms: rooms, messagesPerRoom: messagesPerRoom, encryption: encryption,
                                       verificationRequestAfter: verificationRequestAfter)
        let files = session.paths.account("demo")
        // the index of the most recent made-up chats is the demo's only store.
        let index = AccountSession.stores(files, key: { String(repeating: "0d", count: 32) }).index
        session.open(Task { account }, chatListSource: .open(account), files: files, stores: (index, index), maxChats: 150)
        return session
    }

    /// Opens the saved account, if there is one. False when signed out. The scene and a
    /// notification's action may both ask at launch: the account opens once.
    public func restore() async -> Bool {
        if current != nil { return true }
        if let restoring { return await restoring.value }
        let restoring = Task { await restoreOnce() }
        self.restoring = restoring
        defer { self.restoring = nil }
        return await restoring.value
    }

    /// A restore under way.
    private var restoring: Task<Bool, Never>?

    private func restoreOnce() async -> Bool {
        // the Keychain can block (a locked keychain, an access prompt): never on the main thread.
        Log.metrics.notice("launch: restore starts at \(Signposts.sinceProcessStart(), format: .fixed(precision: 3), privacy: .public) s")
        guard let stored = await Self.read(keychain) else { return false }
        Log.metrics.notice("launch: keychain read at \(Signposts.sinceProcessStart(), format: .fixed(precision: 3), privacy: .public) s")
        // the core opens the session only over its own encrypted store: it forgets an account
        // whose store it cannot open, and the app signs in again (`accountLost`).
        openAccount(stored)
        return true
    }

    /// Opens the kept account in the Rust core, behind the core's kept list (in the account's
    /// encrypted store, opened first). Search starts with the store: it reads messages through the
    /// account once it is open.
    private func openAccount(_ stored: KeptAccount) {
        let keychain = self.keychain, store = stored.store, stores = paths.accounts
        let files = paths.account(store)
        let opened = Self.stores(files, store: store)
        let opening = Task {
            guard let account = try await RustAccount.restore(stores: stores, keychain: keychain, store: store,
                                                              local: await opened.kept.value)
            else { throw SessionLost() }
            Log.metrics.notice("launch: account open at \(Signposts.sinceProcessStart(), format: .fixed(precision: 3), privacy: .public) s")
            return account
        }
        // the list kept in the store shows while the account opens.
        open(opening, chatListSource: .opening(kept: opened.kept, account: opening), files: files, stores: opened)
        Task { [weak self] in
            guard case .failure(let error) = await opening.result else { return }
            Log.app.error("restore failed: \(String(describing: error), privacy: .public)")
            self?.accountLost()
        }
    }

    /// The saved account could not be opened: the app goes back to signing in.
    public var onAccountLost: (() -> Void)?

    private func accountLost() {
        let lost = current
        current = nil
        onAccountLost?()
        Task { await lost?.closeStores() }
    }

    @concurrent
    private static func read(_ keychain: AccountKeychain) async -> KeptAccount? {
        bestEffort("keychain read") { try keychain.read() } ?? nil
    }

    /// The server to sign in to: the last one chosen, else Lux's own.
    public var homeserver: String {
        get { preferences.homeserver ?? configuration.homeserver }
        set { preferences.homeserver = newValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// How `homeserver` lets the app sign in. Throws when no Matrix server answers there.
    @concurrent
    public nonisolated func loginMethods(for homeserver: String) async throws -> LoginMethods {
        try await RustAccount.loginMethods(homeserver: homeserver)
    }

    /// Signs in on the server's account page, in a browser sheet over `anchor`.
    public func signIn(presentingFrom anchor: ASPresentationAnchor) async throws {
        guard let client = configuration.client else { throw NoOAuthClient() }
        let store = UUID().uuidString
        let files = paths.account(store)
        let opened = Self.stores(files, store: store)
        do {
            let pending = try await RustAccount.beginOAuth(homeserver: homeserver, client: client, stores: paths.accounts,
                                                           keychain: keychain, store: store, local: await opened.kept.value)
            do {
                guard let url = pending.url else { throw URLError(.badURL) }
                let web = WebAuthentication(anchor: anchor)
                authentication = web
                defer { authentication = nil }
                let callback = try await web.run(url: url, callbackScheme: client.redirect.scheme ?? "")
                let account = try await pending.finish(callback: callback)
                open(Task { account }, chatListSource: .open(account), files: files, stores: opened)
            } catch {
                await pending.cancel()
                throw error
            }
        } catch {
            Self.discard(files)
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { throw CancellationError() }
            throw error
        }
    }

    /// Signs in with a user name (`@anna:server`, or `anna`) and password, on a server that allows it.
    public func signIn(user: String, password: String) async throws {
        let store = UUID().uuidString
        let files = paths.account(store)
        let opened = Self.stores(files, store: store)
        do {
            let account = try await RustAccount.signIn(homeserver: homeserver, user: user, password: password,
                                                       deviceName: Self.deviceName, stores: paths.accounts, keychain: keychain,
                                                       store: store, local: await opened.kept.value)
            open(Task { account }, chatListSource: .open(account), files: files, stores: opened)
        } catch {
            Self.discard(files)
            throw error
        }
    }

    /// A sign-in that did not finish: its files go.
    private static func discard(_ files: AccountPaths) {
        do {
            try files.remove()
        } catch {
            Log.app.error("a sign-in's files stay: \(String(describing: error), privacy: .public)")
        }
    }

    /// What the account's device list calls this device.
    private static var deviceName: String {
        #if os(iOS)
        "Lux (iPhone)"
        #else
        "Lux (Mac)"
        #endif
    }

    // MARK: Push notifications

    /// The rooms of the chat on screen: their notifications show no banner (but a Matrix
    /// thread's reply, which the chat's own timeline does not show).
    public var roomsOnScreen: Set<String> = []
    /// The Matrix threads on screen, by their roots: their replies' notifications show no banner.
    public var threadsOnScreen: Set<String> = []

    /// What a notification of `room` (a reply in the thread of `thread`, if any) shows is on
    /// screen already: its thread, or its chat.
    public func showsMessage(of room: String, thread: String?) -> Bool {
        thread.map(threadsOnScreen.contains) ?? roomsOnScreen.contains(room)
    }

    /// Registers this device's push token with the account's server (each launch: the token
    /// may have changed, and the server renews the pusher).
    public func registerPusher(token: Data) async {
        guard let current, let push = configuration.push else { return }
        let pusher = Pusher(token: token, environment: .current, appId: push.appId, gateway: push.url,
                            appName: Configuration.appName, deviceName: Self.deviceName,
                            language: Locale.preferredLanguages.first ?? "en",
                            fallbackText: String(localized: "New message"))
        do {
            try await current.account.value.setPusher(pusher)
        } catch {
            Log.app.error("pusher: \(String(describing: error), privacy: .public)")
        }
    }

    /// Answers a notification: `text` to its room (its Matrix thread, if it came in one), sent
    /// before this returns.
    public func reply(roomId: String, threadRoot: String? = nil, text: String) async throws {
        try await account.value.sendNow(roomId: roomId, threadRoot: threadRoot, text: text)
    }

    /// Marks a notification's room (its Matrix thread, if it came in one) read up to its message.
    public func markRead(roomId: String, threadRoot: String? = nil, upTo eventId: String) async throws {
        try await account.value.markRead(roomId: roomId, threadRoot: threadRoot, upTo: eventId)
    }

    /// The notifications of what the sync brings while the app runs (the Mac shows them
    /// itself); an empty stream when signed out.
    public func liveNotifications() async -> AsyncStream<PushedMessage> {
        guard let account = await bestEffort("live notifications", { try await account.value }) else { return AsyncStream { $0.finish() } }
        return account.liveNotifications()
    }

    /// The system's background refresh: opens the kept account if the app was not running,
    /// syncs until the server answered (at most `within`), and stops the sync. The chat list
    /// and the store are then fresh for the next time the app opens. False when signed out or
    /// the server did not answer in time.
    public func refreshInBackground(within: Duration) async -> Bool {
        guard await restore(), let account = await bestEffort("background refresh", { try await account.value }) else { return false }
        return await account.refresh(within: within)
    }

    /// Ends the account's work, stops its sync (the chat list kept for the next launch) and closes
    /// its stores, the account kept: as the app ends, and a test's demo session as the test
    /// ends. No store is left open for the process's exit, where SQLCipher frees its ciphers'
    /// memory under a store's thread.
    public func close() async {
        guard let current else { return }
        await current.close()
        await current.enterBackground().value
        await current.closeStores()
        self.current = nil
    }

    /// The app ends: the long work (index, photos, the model) and the session close, waited for
    /// at most `limit`. A store's call still under way then holds the process's exit a moment
    /// (`lux-store`'s exit hold), as an exit nobody announced does.
    public func closeAsTheAppEnds(within limit: Duration) async {
        let closing = Task {
            await ForegroundWork.shared.leave()
            await close()
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await closing.value }
            group.addTask { _ = try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
    }

    /// As `closeAsTheAppEnds`, from a call the process exits after (the iPhone's
    /// `applicationWillTerminate`, a test bundle's end): it returns once the session has closed,
    /// or after `limit`, the main run loop running meanwhile, so the work on the main actor goes
    /// on.
    public func closeBeforeReturning(within limit: Duration) {
        Task { await closeAsTheAppEnds(within: limit) }
        let deadline = ContinuousClock.now + limit
        while isSignedIn, ContinuousClock.now < deadline {
            // false when no source is set up: the loop then goes round until the deadline.
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    public func signOut() async {
        guard let current else { return }
        await current.close()
        do {
            try await current.account.value.signOut()
        } catch {
            Log.app.error("sign-out: \(String(describing: error), privacy: .public)")
        }
        // closed before their files go.
        await current.closeStores()
        if let stored = bestEffort("keychain read", { try keychain.read() }) ?? nil {
            // the account's folders (its stores, its search index) and their key.
            Self.discard(paths.account(stored.store))
            SearchKey.delete(for: stored.store)
        }
        bestEffort("the kept account stays in the keychain") { try keychain.delete() }
        bestEffort("the media cache stays") { try FileManager.default.removeItemIfPresent(at: paths.media) }
        self.current = nil
        preferences.networksWelcomed = false
        preferences.recoverySetupOffered = false
    }

    /// The account and all that is its own, made whole.
    private func open(_ account: Task<RustAccount, any Error>, chatListSource: ChatListSource, files: AccountPaths,
                      stores: (kept: Task<LocalStore?, Never>, index: Task<LocalStore?, Never>), maxChats: Int? = nil) {
        current = AccountSession(
            account: account, chatListSource: chatListSource, server: homeserver, files: files, paths: paths,
            stores: stores, maxChats: maxChats, preferences: preferences,
            searchChanged: { [weak self] in self?.searchChanges.send() },
            ended: { [weak self] in
                await self?.signOut()
                self?.onAccountLost?()
            })
    }

    /// The account's stores, with their key from the Keychain: the core keeps its chat list in
    /// the kept one, the app its search index in the other.
    private static func stores(_ files: AccountPaths, store: String) -> (kept: Task<LocalStore?, Never>, index: Task<LocalStore?, Never>) {
        AccountSession.stores(files, key: { try await SearchKey.key(for: store) })
    }
}

/// The kept account is gone: its session left the Keychain, or the core forgot it over a store it
/// cannot open. The app signs in again.
private struct SessionLost: Error {}
