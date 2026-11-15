import Foundation

/// The app's own settings, kept on this device.
@MainActor
public final class Preferences {
    public static let shared = Preferences()
    private let defaults = UserDefaults.standard

    /// Send read receipts when a chat is read. Off by default: on a bridged account the other side
    /// (WhatsApp, Instagram) sees the chat read too.
    public var sendsReadReceipts: Bool {
        get { defaults.bool(forKey: "sendsReadReceipts") }
        set { defaults.set(newValue, forKey: "sendsReadReceipts") }
    }

    /// Search finds photos by how they look too (the words in them and the messages near them
    /// it finds always), read on this device. Off by default: it downloads a model of about
    /// 450 MB and reads every photo again with it.
    public var searchesPhotosByLook: Bool {
        get { defaults.bool(forKey: "searchesPhotosByLook") }
        set { defaults.set(newValue, forKey: "searchesPhotosByLook") }
    }

    /// The places pinned on the iPhone (place keys), in order: the first `toolbarPlaces` of them
    /// show in the bottom toolbar. The inbox and the archive until the user changes them.
    public var pinnedPlaces: [String] {
        get { defaults.stringArray(forKey: "pinnedPlaces") ?? [Place.inbox.key, Place.folder(.archive).key] }
        set { defaults.set(newValue, forKey: "pinnedPlaces") }
    }

    /// As many places as the toolbar fits beside the filter, the button for all places and search.
    public static let toolbarPlaces = 3

    /// Recovery setup was offered after signing in (once per sign-in; Settings keeps it after).
    public var recoverySetupOffered: Bool {
        get { defaults.bool(forKey: "recoverySetupOffered") }
        set { defaults.set(newValue, forKey: "recoverySetupOffered") }
    }

    /// The welcome to the server's networks was shown after signing in (once per sign-in).
    public var networksWelcomed: Bool {
        get { defaults.bool(forKey: "networksWelcomed") }
        set { defaults.set(newValue, forKey: "networksWelcomed") }
    }

    /// The order of the chat list's chats, on this device.
    public var chatOrder: ChatOrder {
        get { defaults.string(forKey: "chatOrder").flatMap(ChatOrder.init(rawValue:)) ?? .activity }
        set { defaults.set(newValue.rawValue, forKey: "chatOrder") }
    }

    /// How chats draw their messages, on this device: bubbles until the user picks plain rows.
    public var chatStyle: ChatStyle {
        get { defaults.string(forKey: "chatStyle").flatMap(ChatStyle.init(rawValue:)) ?? .bubbles }
        set {
            guard newValue != chatStyle else { return }
            defaults.set(newValue.rawValue, forKey: "chatStyle")
            chatStyleChanges.send()
        }
    }

    /// Open chats draw their messages again when `chatStyle`, or a chat's own, changes.
    public let chatStyleChanges = Broadcast()

    /// How one chat draws its messages, when it differs from `chatStyle`.
    public func chatStyleOverride(in roomId: String) -> ChatStyle? {
        (defaults.dictionary(forKey: "chatStyleByChat")?[roomId] as? String).flatMap(ChatStyle.init(rawValue:))
    }

    /// Sets how one chat draws its messages; nil follows `chatStyle`.
    public func setChatStyle(_ style: ChatStyle?, in roomId: String) {
        guard style != chatStyleOverride(in: roomId) else { return }
        var all = defaults.dictionary(forKey: "chatStyleByChat") ?? [:]
        all[roomId] = style?.rawValue
        defaults.set(all, forKey: "chatStyleByChat")
        chatStyleChanges.send()
    }

    /// How a chat draws its messages: its own choice, else the app's.
    public func chatStyle(in roomId: String) -> ChatStyle {
        chatStyleOverride(in: roomId) ?? chatStyle
    }

    /// The server last signed in to; nil for Lux's own.
    public var homeserver: String? {
        get { defaults.string(forKey: "homeserver") }
        set { defaults.set(newValue, forKey: "homeserver") }
    }

    /// The chats with an unsent draft on this device (the drafts themselves are in the account's
    /// store, one chat at a time; the list's Drafts filter needs them all at once).
    public var chatsWithDrafts: Set<String> {
        Set(defaults.stringArray(forKey: "chatsWithDrafts") ?? [])
    }

    public func setHasDraft(_ hasDraft: Bool, in roomId: String) {
        var chats = chatsWithDrafts
        guard (hasDraft ? chats.insert(roomId).inserted : chats.remove(roomId) != nil) else { return }
        defaults.set(Array(chats), forKey: "chatsWithDrafts")
    }

    /// How one chat sends read receipts, when it differs from `sendsReadReceipts`.
    public func readReceiptsOverride(in roomId: String) -> ReadReceipts? {
        (defaults.dictionary(forKey: "readReceiptsByChat")?[roomId] as? String).flatMap(ReadReceipts.init(rawValue:))
    }

    /// Sets how one chat sends read receipts; nil follows `sendsReadReceipts`.
    public func setReadReceipts(_ mode: ReadReceipts?, in roomId: String) {
        var all = defaults.dictionary(forKey: "readReceiptsByChat") ?? [:]
        all[roomId] = mode?.rawValue
        defaults.set(all, forKey: "readReceiptsByChat")
    }

    /// How a chat sends read receipts: its own choice, else the app's.
    public func readReceipts(in roomId: String) -> ReadReceipts {
        readReceiptsOverride(in: roomId) ?? (sendsReadReceipts ? .automatic : .manual)
    }
}

/// When a chat tells the others it was read.
public enum ReadReceipts: String, Sendable, CaseIterable {
    /// When the reader reaches the newest message.
    case automatic
    /// Only when the reader asks (the eye button in the composer).
    case manual
}
