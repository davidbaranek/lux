import Foundation
import LuxBindings

/// A chat to share to, as the chat list last showed it.
public struct ShareChat: Sendable, Hashable, Identifiable {
    /// The chat's id (a room's, or a merged chat's `merge:…`): the one notifications and the
    /// system's suggestions name.
    public var id: String
    /// The room it is sent to (a merged chat's default room).
    public var roomId: String
    public var name: String
    public var avatar: ImageRef?
    /// A group with no picture: two members' pictures.
    public var memberAvatars: [ImageRef]
    public var isGroup: Bool
    public var network: String
}

/// The account as the share extension sees it: the kept session, opened from the shared
/// container without its sync, sending what the user shares to one chat; and the chats to choose
/// from, as the app last kept its list.
public final class ShareSender: Sendable {
    private let sender: CoreShareSender
    /// The chats, the inbox's first.
    public let chats: [ShareChat]

    private init(sender: CoreShareSender, chats: [ShareChat]) {
        self.sender = sender
        self.chats = chats
    }

    /// Opens the kept account; nil when none is kept (the user has not signed in in the app).
    public static func open(configuration: Session.Configuration = .main) async throws -> ShareSender? {
        // the extension's small runtime, before the first call into the core.
        CoreRuntime.startInExtension()
        let keychain = AccountKeychain(service: configuration.keychainService)
        let paths = AppPaths.main
        guard let kept = try keychain.read(), paths.shared != nil else { return nil }
        let account = paths.account(kept.store)
        guard let sender = try await openShareSender(storeFolder: account.folder.path,
                                                     keeper: KeychainKeeper(keychain: keychain, store: kept.store))
        else { return nil }
        return ShareSender(sender: sender, chats: await chats(of: account, store: kept.store))
    }

    /// The chats the app kept in the account's store; none before it first kept its list.
    private static func chats(of account: AccountPaths, store: String) async -> [ShareChat] {
        guard let key = await SearchKey.existingKey(for: store),
              let local = await bestEffort("share: the kept chats", { try await LocalStore.open(file: account.keptStore, key: key) })
        else { return [] }
        return await shareChats(store: local.store).map(ShareChat.init)
    }

    /// Sends `attachments` and `text` to `chat`; returns once the server has them. Throws when the
    /// server refuses; what the extension cannot wait for goes out when the app opens next.
    public func send(to chat: ShareChat, text: String, attachments: [OutgoingAttachment]) async throws {
        try await sender.send(roomId: chat.roomId, text: text, attachments: attachments.map(CoreOutgoingAttachment.init))
    }

    /// A chat's or a person's picture, as image data; nil when it cannot be had soon.
    public func picture(_ ref: ImageRef) async -> Data? {
        guard case .person(let url) = ref else { return nil }
        return await sender.picture(media: url)
    }
}

extension ShareChat {
    init(_ chat: CoreShareChat) {
        id = chat.id
        roomId = chat.roomId
        name = chat.name
        avatar = chat.avatar.map { .person(url: $0) }
        memberAvatars = chat.memberAvatars.map { .person(url: $0) }
        isGroup = chat.isGroup
        network = chat.network
    }
}
