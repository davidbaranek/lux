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
    /// The account in the Rust core, open or still opening (its kept list shows meanwhile); nil
    /// when signed out.
    private var opening: Task<RustAccount, any Error>?
    private var watchingSessionEnd: Task<Void, Never>?
    /// Where the chat lists come from: the Rust core's view model over the account.
    private(set) var chatListSource: ChatListSource?
    public private(set) var images: ImagePipeline?

    /// An account is signed in (it may still be opening).
    public var isSignedIn: Bool { opening != nil }

    /// The account, once open: the models await it. Signed out, it fails at once.
    var account: Task<RustAccount, any Error> {
        opening ?? Task { throw SessionLost() }
    }

    /// The app went to the background: the sync stops, before the system suspends it.
    public func enterBackground() {
        guard let opening else { return }
        Task { try? await opening.value.pauseSync() }
    }

    /// The app is back in front (or the Mac woke): the sync runs again and the lists catch up.
    public func enterForeground() {
        guard let opening else { return }
        Task { try? await opening.value.resumeSync() }
    }

    /// A chat's details screen, of a chat in `list`: it tells which place keeps the chat out of
    /// the inbox.
    public func details(of row: ChatRow, in list: ChatListModel? = nil) -> ChatDetailsModel {
        ChatDetailsModel(account: account, row: row, list: list, originals: originalsDirectory) { [weak self] in self?.search?.photos }
    }

    /// The chat that shows a room (its own, or the merged chat it is in); nil when the list has
    /// none (a notification's room not synced yet).
    public func chat(ofRoom roomId: String) async -> ChatRow? {
        try? await account.value.chats(ofRooms: [roomId])[roomId]
    }

    /// Search: chats by name, messages from the encrypted index on this device.
    public private(set) var search: MessageSearch? {
        didSet { searchChanges.send() }
    }
    /// The search index opened (a moment after the account) or closed.
    public let searchChanges = Broadcast()
    /// Photos and files on their way, from every chat (made with the account).
    public private(set) var uploads: Uploads?
    /// The networks the server bridges, the account's logins on them and the history they bring
    /// (made with the account).
    public private(set) var networks: NetworksModel?
    /// What this device needs for encryption, and the verifications other devices ask for (made
    /// with the account).
    public private(set) var security: SecurityModel?
    /// The account's own name and picture (made with the account).
    public private(set) var profile: ProfileModel?
    /// A message was scheduled from a chat: the list reads the waiting ones again.
    public let scheduledChanges = Broadcast()

    private let keychain: AccountKeychain
    private let storeRoot: URL
    private let mediaDirectory: URL
    /// Originals opened from chats (photos, videos, files), kept in the caches with the thumbnails.
    public var originalsDirectory: URL { mediaDirectory.appendingPathComponent("originals", isDirectory: true) }
    /// Attachments being sent, prepared from what the user picked.
    public var outgoingDirectory: URL { mediaDirectory.appendingPathComponent("outgoing", isDirectory: true) }
    /// The browser sheet of a sign-in in progress.
    private var authentication: WebAuthentication?

    public init(configuration: Configuration = .main) {
        // the core's runtime, before the first call into it.
        CoreRuntime.start()
        self.configuration = configuration
        keychain = AccountKeychain(service: configuration.keychainService)
        storeRoot = SharedContainer.appRoot
        mediaDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lux-media", isDirectory: true)
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
    /// many seconds after the app listens.
    public static func demo(rooms: Int = 2_000, messagesPerRoom: Int = 3_000, encryption: DemoEncryption = .launched,
                            verificationRequestAfter: Int? = LaunchOptions.demoVerificationRequest ? 4 : nil) -> Session {
        let session = Session()
        session.open(RustAccount.demo(rooms: rooms, messagesPerRoom: messagesPerRoom, encryption: encryption,
                                      verificationRequestAfter: verificationRequestAfter))
        // a fresh index of the most recent made-up chats each run.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lux-demo-search/index.sqlite")
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        session.store = Self.openStore(file: file, key: { String(repeating: "0d", count: 32) })
        session.startSearch(maxChats: 150)
        return session
    }

    /// Opens the saved account, if there is one. False when signed out. The scene and a
    /// notification's action may both ask at launch: the account opens once.
    public func restore() async -> Bool {
        if opening != nil { return true }
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
        let keychain = self.keychain, store = stored.store, stores = storeRoot
        let local = openStore(store: store)
        let opening = Task {
            guard let account = try await RustAccount.restore(stores: stores, keychain: keychain, store: store, local: await local.value)
            else { throw SessionLost() }
            Log.metrics.notice("launch: account open at \(Signposts.sinceProcessStart(), format: .fixed(precision: 3), privacy: .public) s")
            return account
        }
        open(opening)
        // the list kept in the store shows while the account opens.
        chatListSource = .opening(kept: local, account: opening)
        startSearch()
        Task { [weak self] in
            guard case .failure(let error) = await opening.result else { return }
            Log.app.error("restore failed: \(String(describing: error), privacy: .public)")
            self?.accountLost()
        }
    }

    /// The saved account could not be opened: the app goes back to signing in.
    public var onAccountLost: (() -> Void)?

    private func accountLost() {
        watchingSessionEnd?.cancel()
        watchingSessionEnd = nil
        opening = nil
        chatListSource = nil
        images = nil
        uploads = nil
        networks = nil
        security = nil
        profile = nil
        search = nil
        store = nil
        onAccountLost?()
    }

    @concurrent
    private static func read(_ keychain: AccountKeychain) async -> KeptAccount? {
        try? keychain.read()
    }

    /// The server to sign in to: the last one chosen, else Lux's own.
    public var homeserver: String {
        get { Preferences.shared.homeserver ?? configuration.homeserver }
        set { Preferences.shared.homeserver = newValue.trimmingCharacters(in: .whitespacesAndNewlines) }
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
        let directory = storeRoot.appendingPathComponent(store, isDirectory: true)
        let local = await openStore(store: store).value
        let pending = try await RustAccount.beginOAuth(homeserver: homeserver, client: client, stores: storeRoot,
                                                       keychain: keychain, store: store, local: local)
        do {
            guard let url = pending.url else { throw URLError(.badURL) }
            let web = WebAuthentication(anchor: anchor)
            authentication = web
            defer { authentication = nil }
            let callback = try await web.run(url: url, callbackScheme: client.redirect.scheme ?? "")
            open(try await pending.finish(callback: callback))
            startSearch()
        } catch {
            await pending.cancel()
            self.store = nil
            try? FileManager.default.removeItem(at: directory)
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { throw CancellationError() }
            throw error
        }
    }

    /// Signs in with a user name (`@anna:server`, or `anna`) and password, on a server that allows it.
    public func signIn(user: String, password: String) async throws {
        let store = UUID().uuidString
        let directory = storeRoot.appendingPathComponent(store, isDirectory: true)
        do {
            let local = await openStore(store: store).value
            let account = try await RustAccount.signIn(homeserver: homeserver, user: user, password: password,
                                                       deviceName: Self.deviceName, stores: storeRoot, keychain: keychain,
                                                       store: store, local: local)
            open(account)
            startSearch()
        } catch {
            self.store = nil
            try? FileManager.default.removeItem(at: directory)
            throw error
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
        guard let opening, let push = configuration.push else { return }
        let pusher = Pusher(token: token, environment: .current, appId: push.appId, gateway: push.url,
                            appName: Configuration.appName, deviceName: Self.deviceName,
                            language: Locale.preferredLanguages.first ?? "en",
                            fallbackText: String(localized: "New message"))
        do {
            try await opening.value.setPusher(pusher)
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
        guard let account = try? await account.value else { return AsyncStream { $0.finish() } }
        return account.liveNotifications()
    }

    /// The system's background refresh: opens the kept account if the app was not running,
    /// syncs until the server answered (at most `seconds`), and stops the sync. The chat list
    /// and the store are then fresh for the next time the app opens. False when signed out or
    /// the server did not answer in time.
    public func refreshInBackground(within seconds: Double) async -> Bool {
        guard await restore(), let account = try? await account.value else { return false }
        return await account.refresh(within: seconds)
    }

    /// The system's background processing task for photo search (while it charges): opens the
    /// kept account if the app was not running, and its stores without the sync, reads the
    /// photos not read yet, and closes the stores again unless the app came to the front. True
    /// when every photo is read; the task's expiry cancels it (`stopReadingPhotos`).
    public func readPhotosInBackground() async -> Bool {
        guard await restore(), let account = try? await account.value,
              let search = await openedSearch() else { return false }
        await account.beginBackgroundWork()
        return await search.photos.readAll()
    }

    /// The background task ran out of time: the reading stops where it is.
    public func stopReadingPhotos() async {
        await search?.photos.stop()
    }

    /// The search, once its store has opened (a moment after the account).
    private func openedSearch() async -> MessageSearch? {
        if let search { return search }
        guard let opening = store, await opening.value != nil else { return nil }
        let (opened, announce) = AsyncStream<Void>.makeStream()
        let following = searchChanges.observe { announce.yield() }
        defer { withExtendedLifetime(following) {} }
        if let search { return search }
        for await _ in opened {
            if let search { return search }
        }
        return nil
    }

    public func signOut() async {
        await search?.stop()
        search = nil
        store = nil
        try? await opening?.value.signOut()
        if let stored = try? keychain.read() {
            // the search index is in the account's folder; its key goes too.
            try? FileManager.default.removeItem(at: storeRoot.appendingPathComponent(stored.store))
            SearchKey.delete(for: stored.store)
        }
        try? keychain.delete()
        try? FileManager.default.removeItem(at: mediaDirectory)
        watchingSessionEnd?.cancel()
        watchingSessionEnd = nil
        opening = nil
        chatListSource = nil
        images = nil
        uploads = nil
        networks = nil
        security = nil
        profile = nil
        Preferences.shared.networksWelcomed = false
        Preferences.shared.recoverySetupOffered = false
    }

    /// An account signed in, or the demo's: open at once.
    private func open(_ account: RustAccount) {
        open(Task { account })
        chatListSource = .open(account)
    }

    private func open(_ account: Task<RustAccount, any Error>) {
        opening = account
        // the server may end the session (its tokens refused): the device is gone, sign in again.
        watchingSessionEnd?.cancel()
        watchingSessionEnd = Task { [weak self] in
            guard let ends = try? await account.value.sessionEnd() else { return }
            for await _ in ends {
                Log.app.error("the server ended the session")
                await self?.signOut()
                self?.onAccountLost?()
            }
        }
        images = ImagePipeline(account: account, directory: mediaDirectory)
        uploads = Uploads(account: account, directory: outgoingDirectory)
        networks = NetworksModel(account: account, server: homeserver)
        security = SecurityModel(account: account)
        profile = ProfileModel(account: account)
    }

    /// The account's encrypted store (its folder's `lux-search/index.sqlite`).
    private func storeFile(store: String) -> URL { Self.storeFile(in: storeRoot, store: store) }

    /// The encrypted store of the account kept in `store`, in the folder of stores `root`.
    static func storeFile(in root: URL, store: String) -> URL {
        root.appendingPathComponent(store, isDirectory: true).appendingPathComponent("lux-search/index.sqlite")
    }

    /// Opens the account's encrypted store, with its key from the Keychain: the core keeps its
    /// chat list there, the app its search index.
    private func openStore(store: String) -> Task<LocalStore?, Never> {
        let opening = Self.openStore(file: storeFile(store: store), key: { try await SearchKey.key(for: store) })
        self.store = opening
        return opening
    }

    private static func openStore(file: URL, key: @escaping @Sendable () async throws -> String) -> Task<LocalStore?, Never> {
        Task {
            do {
                return try await LocalStore.open(file: file, key: try await key())
            } catch {
                Log.app.error("local store: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
    }

    /// Starts filling the search index in the account's store, once it is open.
    private func startSearch(maxChats: Int? = nil) {
        guard let account = opening, let opening = store else { return }
        Task {
            guard let store = await opening.value, self.opening == account else { return }
            search = MessageSearch(store: store, account: account, maxChats: maxChats)
        }
    }

    /// The account's encrypted store on this device (the search index, the last chat list).
    private var store: Task<LocalStore?, Never>?
}

/// The kept account is gone: its session left the Keychain, or the core forgot it over a store it
/// cannot open. The app signs in again.
private struct SessionLost: Error {}
