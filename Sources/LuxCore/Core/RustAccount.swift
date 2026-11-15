import Foundation
import LuxBindings

/// The account in the Rust core (`lux-ffi`'s `CoreAccount`): a Matrix account, or the demo's made-up
/// one. The app's one way to the core's account: its session and sync here, its chats read whole
/// (search, a new conversation), and in the other files of this folder its threads
/// (`RustThread.swift`), timelines and media (`RustTimeline.swift`), people and security
/// (`RustAccountActions.swift`). The generated types stay in `Core/`.
final class RustAccount: Sendable {
    /// The core's account, for the other parts of the core in this folder.
    let account: CoreAccount
    /// The demo's pictures and files, drawn here: the demo has no server to load them from.
    let demo: DemoMedia?

    fileprivate init(_ account: CoreAccount, demo: DemoMedia? = nil) {
        self.account = account
        self.demo = demo
    }

    /// Opens the account kept in its folder `store` in `stores`, its session in `keychain`'s item.
    /// Once it is open, the core deletes the other folders in `stores`. Nil
    /// when no session is kept, or the core forgot the account because it cannot open its store
    /// (missing, not encrypted, or its key missing or wrong): it never opens a kept session over
    /// another store.
    /// `local` is the account's encrypted store, where the core keeps its chat list for the next
    /// launch.
    static func restore(stores: URL, keychain: AccountKeychain, store: String, local: LocalStore?) async throws -> RustAccount? {
        try await worded { try await opener(stores: stores, keychain: keychain, store: store, local: local).restore() }.map { RustAccount($0) }
    }

    static func signIn(homeserver: String, user: String, password: String, deviceName: String,
                       stores: URL, keychain: AccountKeychain, store: String, local: LocalStore?) async throws -> RustAccount {
        RustAccount(try await worded {
            try await opener(stores: stores, keychain: keychain, store: store, local: local)
                .signInWithPassword(server: homeserver, user: user, password: password, deviceName: deviceName)
        })
    }

    /// Starts a sign-in on the server's page; `RustOAuth.url` is the page to show.
    static func beginOAuth(homeserver: String, client: Session.OAuthClient, stores: URL, keychain: AccountKeychain,
                           store: String, local: LocalStore?) async throws -> RustOAuth {
        RustOAuth(try await worded {
            try await opener(stores: stores, keychain: keychain, store: store, local: local)
                .beginOauth(server: homeserver, clientName: client.name, redirectUri: client.redirect.absoluteString,
                            clientUri: client.uri.absoluteString)
        })
    }

    /// The demo's made-up account (`-LuxDemo`): `rooms` chats of `messagesPerRoom` messages, its
    /// encryption starting at `encryption`.
    static func demo(rooms: Int, messagesPerRoom: Int, encryption: Session.DemoEncryption = .ready,
                     verificationRequestAfter: Int? = nil) -> RustAccount {
        // the demo opens before any session: the core's runtime first.
        CoreRuntime.start()
        let start: CoreDemoEncryption = switch encryption {
        case .ready: .ready
        case .unverified: .unverified
        case .noRecovery: .noRecovery
        }
        return RustAccount(openDemo(rooms: UInt32(clamping: rooms), messagesPerRoom: UInt32(clamping: messagesPerRoom),
                                    encryption: start,
                                    verificationRequestAfterSeconds: verificationRequestAfter.map { UInt32(clamping: $0) }),
                           demo: DemoMedia())
    }

    /// How a server lets the app sign in, asked by the core.
    static func loginMethods(homeserver: String) async throws -> LoginMethods {
        let found = try await worded { try await serverLoginMethods(server: homeserver) }
        return LoginMethods(password: found.password, browser: found.oauth)
    }

    private static func opener(stores: URL, keychain: AccountKeychain, store: String, local: LocalStore?) -> CoreAccountOpener {
        CoreAccountOpener(stores: stores.path, folderName: store, keeper: KeychainKeeper(keychain: keychain, store: store),
                      store: local?.store)
    }

    // MARK: Its chats

    /// Every chat, merged ones folded, the most recent first.
    func chats() async -> [ChatRow] {
        await account.chats().map(ChatRow.init)
    }

    /// The chats whose name has every word of `query` (without case or accents), the most
    /// recent first, at most `limit`.
    func findChats(_ query: String, limit: Int) async -> [ChatRow] {
        await account.findChats(query: query, limit: UInt32(clamping: limit)).map(ChatRow.init)
    }

    /// The chat of the list that shows each room: its own, or the merged chat it is in.
    func chats(ofRooms rooms: [String]) async -> [String: ChatRow] {
        let found = await account.chatsOfRooms(roomIds: rooms)
        return Dictionary(zip(rooms, found).compactMap { room, chat in chat.map { (room, ChatRow($0)) } },
                          uniquingKeysWith: { first, _ in first })
    }

    /// A signal each time the account's chats change (a new message, a chat read or archived),
    /// in every place, not only the one on screen; the first comes with the first change after
    /// this call. Changes that come while the last is unread count as one.
    func chatChanges() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let handle = account.followChats(listener: ChatsRelay(continuation: continuation))
        continuation.onTermination = { _ in handle.cancel() }
        return stream
    }

    // MARK: The session

    /// Ends once, with a value, if the server ends this device's session (it refuses its tokens).
    func sessionEnd() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let handle = account.followSessionEnd(listener: SessionEndRelay(continuation: continuation))
        continuation.onTermination = { _ in handle.cancel() }
        return stream
    }

    func pauseSync() async { await account.pauseSync() }
    func resumeSync() async { await account.resumeSync() }
    /// Opens the stores for work in the background without the sync (reading photos);
    /// `pauseSync` closes them when it is done.
    func beginBackgroundWork() async { await account.beginBackgroundWork() }
    /// Signs out, removing this device's pusher first.
    func signOut() async throws { try await worded { try await account.signOut() } }

    // MARK: Push notifications

    /// Registers this device's pusher with the server, in place of the one it registered before.
    func setPusher(_ pusher: Pusher) async throws {
        let pusher = CorePusher(token: pusher.token, environment: pusher.environment == .sandbox ? .sandbox : .production,
                                appId: pusher.appId, gatewayUrl: pusher.gateway.absoluteString, appName: pusher.appName,
                                deviceName: pusher.deviceName, language: pusher.language, fallbackText: pusher.fallbackText)
        try await worded { try await account.setPusher(pusher: pusher) }
    }

    /// Sends `text` to a room and returns once the server has it: a reply from a notification,
    /// after which the app may be suspended at once.
    func sendNow(roomId: String, text: String) async throws { try await worded { try await account.sendNow(roomId: roomId, text: text) } }

    /// Marks a room read up to one message: the one a notification showed.
    func markRead(roomId: String, upTo eventId: String) async throws {
        try await worded { try await account.markReadUpTo(roomId: roomId, eventId: eventId) }
    }

    /// A background refresh: syncs until the server answered (at most `seconds`), then stops.
    /// True when the server answered.
    func refresh(within seconds: Double) async -> Bool { await account.refresh(seconds: seconds) }

    /// The notifications of what the sync brings (noisy messages from others, new and unread,
    /// each once), while the account is open and the stream followed: where no push wakes an
    /// extension (the Mac), the app shows them itself.
    func liveNotifications() -> AsyncStream<PushedMessage> {
        let (stream, continuation) = AsyncStream.makeStream(of: PushedMessage.self, bufferingPolicy: .bufferingNewest(32))
        let handle = account.followNotifications(listener: NotificationRelay(continuation: continuation))
        continuation.onTermination = { _ in handle.cancel() }
        return stream
    }
}

/// A sign-in on the server's page, between showing it and its callback.
final class RustOAuth: Sendable {
    private let oauth: CoreOAuth
    let url: URL?

    fileprivate init(_ oauth: CoreOAuth) {
        self.oauth = oauth
        url = URL(string: oauth.url())
    }

    func finish(callback: URL) async throws -> RustAccount {
        RustAccount(try await worded { try await oauth.finish(callbackUrl: callback.absoluteString) })
    }

    func cancel() async { await oauth.cancel() }
}

/// Hands the core's live notifications on, worded.
private final class NotificationRelay: CoreNotificationListener {
    let continuation: AsyncStream<PushedMessage>.Continuation
    init(continuation: AsyncStream<PushedMessage>.Continuation) { self.continuation = continuation }

    func onNotification(notification: CoreNotification) { continuation.yield(PushedMessage(notification)) }
}

/// Hands the core's signal that the session ended on.
private final class SessionEndRelay: CoreSessionEndListener {
    let continuation: AsyncStream<Void>.Continuation
    init(continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }

    func onSessionEnd() {
        continuation.yield()
        continuation.finish()
    }
}

/// Hands the core's signal that the chats changed on.
private final class ChatsRelay: CoreChatsListener {
    let continuation: AsyncStream<Void>.Continuation
    init(continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }

    func onChange() { continuation.yield() }
}

/// The session in the account's Keychain item (`KeptAccount`), the store key beside it.
final class KeychainKeeper: CoreSessionKeeper {
    private let keychain: AccountKeychain
    private let store: String

    init(keychain: AccountKeychain, store: String) {
        self.keychain = keychain
        self.store = store
    }

    func load() throws -> CoreKeptSession? {
        do {
            return try keychain.read().map { CoreKeptSession($0.session) }
        } catch {
            throw CoreSessionKeeperError.Unavailable(reason: String(describing: error))
        }
    }

    func save(session: CoreKeptSession) throws {
        do {
            try keychain.write(KeptAccount(session: KeptAccount.Session(session), store: store))
        } catch {
            throw CoreSessionKeeperError.Unavailable(reason: String(describing: error))
        }
    }

    func loadStoreKey() throws -> Data? {
        do {
            return try keychain.storeKey()
        } catch {
            throw CoreSessionKeeperError.Unavailable(reason: String(describing: error))
        }
    }

    func saveStoreKey(key: Data) throws {
        do {
            try keychain.writeStoreKey(key)
        } catch {
            throw CoreSessionKeeperError.Unavailable(reason: String(describing: error))
        }
    }

    /// The account is forgotten: its session, its store key and its search index's key go.
    func delete() throws {
        do {
            try keychain.delete()
        } catch {
            throw CoreSessionKeeperError.Unavailable(reason: String(describing: error))
        }
        SearchKey.delete(for: store)
    }
}

// MARK: Mappings

extension ChatRow {
    /// A chat-list row of the core, in the app's types.
    init(_ chat: CoreChat) {
        self.init(id: chat.id, name: chat.name, preview: chat.preview.map(PreviewLine.words) ?? "", date: chat.date,
                  unreadCount: Int(chat.unreadCount),
                  isMarkedUnread: chat.isMarkedUnread, isMuted: chat.isMuted, network: chat.network,
                  // the picture's url names its version: a new picture is a new url. A merged chat's
                  // id names no room: its picture (its newest room's) loads by its url.
                  avatar: chat.avatar.map { chat.rooms.isEmpty ? .room(id: chat.id, version: $0) : .person(url: $0) },
                  isGroup: chat.isGroup,
                  folder: ChatFolder(chat.folder))
        memberAvatars = chat.memberAvatars.map { .person(url: $0) }
        reminder = chat.reminder
        isPinned = chat.pinned != nil
        pinOrder = chat.pinned
        rooms = chat.rooms.map { ChatRoom(id: $0.id, network: $0.network) }
        defaultRoom = chat.defaultRoom
    }
}

/// A message in the app's words: a chat's newest as the list's one line (who wrote it, then what),
/// or the message a reply quotes.
enum PreviewLine {
    static func words(_ preview: CorePreview) -> String {
        switch preview.kind {
        // what someone did, worded with them.
        case .reaction(let key):
            return switch preview.author {
            case .own: String(localized: "You reacted \(key)")
            case .named(let name): String(localized: "\(name) reacted \(key)")
            case nil: String(localized: "Reacted \(key)")
            }
        case .membership(let membership):
            return membershipWords(membership, by: preview.author)
        default:
            let what = body(preview.kind)
            return switch preview.author {
            case .own: String(localized: "You: ") + what
            case .named(let name): "\(name): \(what)"
            case nil: what
            }
        }
    }

    /// Someone joined, invited the user, or asks to join.
    private static func membershipWords(_ membership: CoreMembership, by author: CoreAuthor?) -> String {
        switch (membership, author) {
        case (.joined, .own): String(localized: "You joined")
        case (.joined, .named(let name)): String(localized: "\(name) joined")
        case (.joined, nil): String(localized: "Joined")
        case (.invited, .named(let name)): String(localized: "\(name) invited you")
        case (.invited, _): String(localized: "Invited you")
        case (.knocked, .own): String(localized: "You asked to join")
        case (.knocked, .named(let name)): String(localized: "\(name) asked to join")
        case (.knocked, nil): String(localized: "Asks to join")
        }
    }

    /// A quote: its sender, then what it is; empty until the message is known.
    static func quote(_ quote: CoreQuote) -> String {
        let what = quote.kind.map(body) ?? ""
        return quote.senderName.isEmpty ? what : "\(quote.senderName): \(what)"
    }

    /// What a message is: its text, or its kind ("Photo").
    static func body(_ kind: CorePreviewKind) -> String {
        switch kind {
        case .text(let text): text
        case .image: String(localized: "Photo")
        case .video: String(localized: "Video")
        case .audio: String(localized: "Audio")
        case .voice: String(localized: "Voice message")
        case .file(let name): name ?? String(localized: "File")
        case .location: String(localized: "Location")
        case .sticker: String(localized: "Sticker")
        case .poll(let question): String(localized: "Poll: \(question)")
        case .encrypted: String(localized: "Encrypted message")
        case .deleted: String(localized: "Message deleted")
        case .reaction(let key): String(localized: "Reacted \(key)")
        case .call: String(localized: "Call")
        case .membership(.joined): String(localized: "Joined")
        case .membership(.invited): String(localized: "Invited")
        case .membership(.knocked): String(localized: "Asks to join")
        case .other: String(localized: "Message")
        }
    }
}

extension SavedMessage {
    init(_ saved: CoreSavedMessage) {
        let body = saved.body.isEmpty ? saved.fileName : saved.body
        self.init(id: saved.event, roomId: saved.room, senderName: saved.senderName, isOwn: saved.isOwn, body: body,
                  date: saved.date, savedAt: saved.savedAt)
    }
}

extension ChatRequest {
    init(_ request: CoreRequest) {
        self.init(id: request.id, name: request.name, avatar: request.avatar.map { .room(id: request.id, version: $0) },
                  inviterName: request.inviterName, isDirect: request.isDirect)
    }
}

private extension CoreKeptSession {
    init(_ saved: KeptAccount.Session) {
        self.init(userId: saved.userId, deviceId: saved.deviceId, homeserverUrl: saved.homeserverUrl,
                  accessToken: saved.accessToken, refreshToken: saved.refreshToken, oauthClientId: saved.oauthClientId,
                  nativeSlidingSync: saved.nativeSlidingSync)
    }
}

private extension KeptAccount.Session {
    init(_ kept: CoreKeptSession) {
        self.init(userId: kept.userId, deviceId: kept.deviceId, homeserverUrl: kept.homeserverUrl,
                  accessToken: kept.accessToken, refreshToken: kept.refreshToken, oauthClientId: kept.oauthClientId,
                  nativeSlidingSync: kept.nativeSlidingSync)
    }
}
