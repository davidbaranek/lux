import Foundation

/// Where the chat list looks: a folder, the requests, one network's chats, one space's, or one
/// label's.
public enum Place: Hashable, Sendable {
    case folder(ChatFolder)
    case requests
    /// Saved messages, across chats.
    case saved
    /// Chats with a reminder, the soonest first.
    case reminders
    /// Messages waiting to go.
    case scheduled
    case network(String)
    case space(String)
    case label(String)

    public static let inbox = Place.folder(.inbox)

    /// The rail's groups, a line between each: the folders (and the requests), the networks, the
    /// spaces, the labels. The user orders places within the last three.
    public enum Group: Int, CaseIterable, Sendable { case folders, networks, spaces, labels }

    public var group: Group {
        switch self {
        case .folder, .requests, .saved, .reminders, .scheduled: .folders
        case .network: .networks
        case .space: .spaces
        case .label: .labels
        }
    }

    /// A string that names the place, for the saved order of places.
    public var key: String {
        switch self {
        case .folder(let folder): "folder:\(folder)"
        case .network(let network): "network:\(network)"
        case .space(let id): "space:\(id)"
        case .requests: "requests"
        case .saved: "saved"
        case .reminders: "reminders"
        case .scheduled: "scheduled"
        case .label(let id): "label:\(id)"
        }
    }
}

/// A place as the rail (and the iPhone's filter menu) shows it.
public struct PlaceItem: Hashable, Sendable, Identifiable {
    public enum Icon: Hashable, Sendable {
        /// An SF Symbol.
        case symbol(String)
        /// A network's logo (or, without one, its symbol on the logos' tile): `Networks`.
        case network(String)
        /// A space's picture, over its initials while it loads (or when it has none).
        case picture(ImageRef?)
    }

    public var id: Place
    public var title: String
    public var icon: Icon
    /// Chats with unread messages that are not muted.
    public var unread: Int
    /// The user hid it from the rail; the inbox never is.
    public var isHidden = false
}

/// The places as the app words and draws them; the core composes the list of them and what
/// each holds (`lux_core::list`).
public enum Places {
    /// A place as the rail shows it: its title and icon (a space's and a label's name from the core).
    static func item(_ place: Place, unread: Int, isHidden: Bool, name: String?, avatar: ImageRef?) -> PlaceItem {
        let (title, icon): (String, PlaceItem.Icon) = switch place {
        case .folder(.inbox): (String(localized: "Inbox"), .symbol("tray"))
        case .folder(.lowPriority): (String(localized: "Low Priority"), .symbol("arrow.down.circle"))
        case .folder(.archive): (String(localized: "Archive"), .symbol("archivebox"))
        case .reminders: (String(localized: "Reminders"), .symbol("bell"))
        case .scheduled: (String(localized: "Scheduled"), .symbol("clock.arrow.circlepath"))
        case .saved: (String(localized: "Saved"), .symbol("bookmark"))
        case .requests: (String(localized: "Requests"), .symbol("person.crop.circle.badge.questionmark"))
        case .network(let network): (Networks.name(network), .network(network))
        case .space: (name ?? "", .picture(avatar))
        case .label: (name ?? "", .symbol("tag"))
        }
        return PlaceItem(id: place, title: title, icon: icon, unread: unread, isHidden: isHidden)
    }
}

extension ChatRow {
    /// The row in the Reminders list: when to answer it, before its newest message.
    var reminded: ChatRow {
        guard let reminder else { return self }
        var row = self
        row.preview = String(localized: "Remind \(TimeText.upcoming(reminder)) · ") + preview
        return row
    }
}

/// What the chat list's loading bubble says while the app works: connecting, the chats as they
/// arrive, then the search index reading each chat's newest messages. Nil once there is nothing
/// to wait for (the index's long read of older messages goes on without a bubble).
public enum ListActivity {
    public static func describe(_ state: ChatListModel.LoadState, search: SearchIndexer.Progress?) -> (title: String, detail: String?)? {
        switch state {
        case .loading:
            return (String(localized: "Connecting…"), String(localized: "Opening your account"))
        case .syncing(let newChats):
            // the server's first answer after launch; on a first sign-in, the chats as they come.
            return (String(localized: "Updating chats"), newChats > 0 ? String(localized: "\(newChats) new") : String(localized: "From the server"))
        case .done:
            guard let search, search.isIndexing, search.isFirstFill, !search.deep, search.total > 0 else { return nil }
            return (String(localized: "Preparing search"), String(localized: "\(search.chats) of \(search.total) chats"))
        }
    }
}
