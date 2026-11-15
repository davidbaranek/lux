import Foundation

/// A chat's details screen: its rooms' state (name, topic, picture, networks, encryption), its
/// notification setting, and what the user changes there. Its members and what it shared have
/// their own models, made here.
@MainActor
public final class ChatDetailsModel {
    /// The chat as the list shows it; renamed and repictured as the details change.
    public private(set) var row: ChatRow
    /// Nil until loaded.
    public private(set) var info: ChatInfo?
    /// A change is on its way to the server.
    public private(set) var isSaving = false
    public let changes = Broadcast()

    private let account: Task<RustAccount, any Error>
    private let originals: URL
    /// Photo search, once the account's index has opened: what the chat shared is found by the
    /// words in its photos and how they look too.
    private let photos: @MainActor () -> PhotoSearch?

    init(account: Task<RustAccount, any Error>, row: ChatRow, originals: URL, photos: @escaping @MainActor () -> PhotoSearch? = { nil }) {
        self.account = account
        self.row = row
        self.originals = originals
        self.photos = photos
    }

    /// The room a single-room chat is; a merged chat's first. Its name, topic and picture are
    /// the chat's.
    public var mainRoom: RoomInfo? { info?.rooms.first }
    /// What the chat is about.
    public var topic: String? { info?.rooms.lazy.compactMap(\.topic).first }
    public var isGroup: Bool { row.isGroup || info?.rooms.contains { !$0.isDirect } == true }
    /// What the chat is, under its name: a group of how many, or the networks it is on.
    public var subtitle: String {
        if isGroup, let room = mainRoom {
            return String(localized: "Group · \(room.joinedMembers) members")
        }
        return row.chatRooms.map { Networks.name($0.network) }.joined(separator: " + ")
    }

    /// A merged chat is the user's own: renaming it is renaming the merge, which the list does.
    public var canRename: Bool { !row.isMerged && mainRoom?.canRename == true }
    public var canChangeTopic: Bool { !row.isMerged && mainRoom?.canChangeTopic == true }
    public var canChangePicture: Bool { !row.isMerged && mainRoom?.canChangeAvatar == true }

    /// Reads the details from the core; keeps the last ones when it cannot. Throws an
    /// `AccountFailure` the first time.
    public func load() async throws {
        let account = try await account.value
        do {
            info = try await account.chatInfo(chatId: row.id)
        } catch where info != nil {
            return
        }
        if let room = mainRoom, !row.isMerged {
            row.name = room.name
            row.avatar = room.avatar
        }
        changes.send()
    }

    // MARK: Changes

    /// How this chat draws its messages, when it differs from the app's; nil follows Settings. An
    /// open chat redraws at once (`Preferences.chatStyleChanges`).
    public var chatStyleOverride: ChatStyle? {
        get { Preferences.shared.chatStyleOverride(in: row.id) }
        set {
            Preferences.shared.setChatStyle(newValue, in: row.id)
            changes.send()
        }
    }

    /// The choices for how the chat draws its messages, the last following Settings, which it names
    /// ("As in Settings (Bubbles)").
    public var chatStyleChoices: [(title: String, style: ChatStyle?)] {
        ChatStyle.allCases.map { ($0.title, $0) }
            + [(String(localized: "As in Settings (\(Preferences.shared.chatStyle.title))"), nil)]
    }

    public func setNotifications(_ setting: NotificationSetting) async throws {
        try await save { try await $0.setNotifications(chatId: self.row.id, setting) }
        row.isMuted = setting == .off || setting == .mentions
    }

    /// Marks it read (or unread) on the server, as the chat's menu does.
    public func markRead(_ read: Bool) async throws {
        try await save { try await $0.change(chatId: self.row.id, read ? .read : .unread) }
    }

    public func rename(to name: String) async throws {
        guard let room = mainRoom else { return }
        try await save { try await $0.renameRoom(roomId: room.id, to: name) }
    }

    public func setTopic(_ topic: String) async throws {
        guard let room = mainRoom else { return }
        try await save { try await $0.setTopic(roomId: room.id, topic) }
    }

    /// Makes a picked image (any format ImageIO reads) the chat's picture.
    public func setPicture(_ image: Data) async throws {
        guard let room = mainRoom else { return }
        let jpeg = try await ProfilePicture.jpeg(from: image)
        try await save { try await $0.setRoomPicture(roomId: room.id, jpeg: jpeg) }
    }

    public func removePicture() async throws {
        guard let room = mainRoom else { return }
        try await save { try await $0.removeRoomPicture(roomId: room.id) }
    }

    /// Leaves the chat (each room of a merged one); it goes from the list.
    public func leave() async throws {
        try await save(reload: false) { try await $0.leave(chatId: self.row.id) }
    }

    /// Runs `change`, then reads the details again, as the server now has them.
    private func save(reload: Bool = true, _ change: (RustAccount) async throws -> Void) async throws {
        isSaving = true
        changes.send()
        defer {
            isSaving = false
            changes.send()
        }
        try await change(try await account.value)
        if reload { try? await load() }
    }

    // MARK: Members and what it shared

    /// The members of one of its rooms (a merged chat's, by network).
    public func members(of room: RoomInfo) -> MembersModel {
        MembersModel(account: account, room: room)
    }

    /// What it shared, of `kind`.
    public func shared(_ kind: SharedKind) -> SharedModel {
        SharedModel(account: account, chatId: row.id, kind: kind, originals: originals, photos: photos)
    }
}

/// A room's members, found by name as the user types.
@MainActor
public final class MembersModel {
    public let room: RoomInfo
    /// The members found, the account first, then by role and name.
    public private(set) var found: [ChatMember] = []
    public private(set) var count = 0
    public private(set) var isLoading = true
    public private(set) var failure: AccountFailure?
    public let changes = Broadcast()

    /// At most this many show, the rest found by searching: a group of thousands lists fast.
    public static let shown = 500

    private let account: Task<RustAccount, any Error>
    private var list: MemberList?
    private var query = ""

    init(account: Task<RustAccount, any Error>, room: RoomInfo) {
        self.account = account
        self.room = room
    }

    /// Loads the members (from the server once, if this device has not got them).
    public func load() async {
        do {
            let list = try await account.value.members(roomId: room.id)
            self.list = list
            count = list.count
            found = list.find(query, limit: Self.shown)
        } catch {
            failure = error as? AccountFailure ?? .connectionFailed
        }
        isLoading = false
        changes.send()
    }

    /// Shows the members whose name or id holds every word of `query`.
    public func search(_ query: String) {
        self.query = query
        guard let list else { return }
        found = list.find(query, limit: Self.shown)
        changes.send()
    }
}
