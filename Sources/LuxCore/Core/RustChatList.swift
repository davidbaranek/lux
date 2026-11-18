import Foundation
import LuxBindings

/// Where a chat list comes from: an open account (signed in, or the demo's), or one still
/// opening (its list kept on the device shows until it opens).
enum ChatListSource: Sendable {
    case open(RustAccount)
    case opening(kept: Task<LocalStore?, Never>, account: Task<RustAccount, any Error>)
}

/// The chat list's view model in the Rust core (`lux_core::list`): the app forwards intents to it
/// in its own types, and receives one batch of changes per frame, mapped to the app's rows off
/// the main thread (on the core's thread that sends it). The generated types stay in this file.
final class RustChatList: ChatListView {
    private let list: CoreChatList
    /// The list's batches and failed intents as they come.
    let events: AsyncStream<ChatListEvent>

    /// Opens a list at `place` with `filter`, in `order`. It takes intents at once: before its account
    /// opens, they wait in the core, in order.
    init(_ source: ChatListSource, place: Place, filter: ChatFilter?, order: ChatOrder, drafts: Set<String>) {
        let (events, continuation) = AsyncStream<ChatListEvent>.makeStream()
        self.events = events
        let setup = CoreListSetup(place: CorePlace(place), filter: filter.map(CoreChatFilter.init), order: CoreChatOrder(order),
                                  drafts: Array(drafts))
        let relay = Relay(continuation)
        switch source {
        case .open(let account):
            list = account.account.chatList(setup: setup, listener: relay)
        case .opening(let kept, let opening):
            let list = CoreChatList.opening(setup: setup, listener: relay)
            self.list = list
            Task {
                list.showKept(store: await kept.value?.store)
                // an account that does not open is the session's to handle: it signs in again.
                if case .success(let account) = await opening.result { list.attach(account: account.account) }
            }
        }
    }

    func select(_ place: Place) -> UInt64 { list.selectPlace(place: CorePlace(place)) }
    func setFilter(_ filter: ChatFilter?) { list.setFilter(filter: filter.map(CoreChatFilter.init)) }
    func setOrder(_ order: ChatOrder) { list.setOrder(order: CoreChatOrder(order)) }
    func setDrafts(_ drafts: Set<String>) { list.setDrafts(drafts: Array(drafts)) }
    /// Reads the waiting messages again.
    func refresh() { list.refresh() }

    func change(_ chatId: String, _ change: ChatChange) { list.change(chatId: chatId, change: CoreChatChange(change)) }
    func answer(request roomId: String, accept: Bool) { list.answerRequest(roomId: roomId, accept: accept) }
    func makeLabel(named name: String, with chatId: String?) { list.makeLabel(name: name, with: chatId) }
    func removeLabel(id: String) { list.removeLabel(id: id) }
    func setChat(_ chatId: String, inLabel id: String, _ included: Bool) {
        list.setInLabel(chatId: chatId, labelId: id, included: included)
    }
    func setReminder(_ chatId: String, at date: Date?) { list.setReminder(chatId: chatId, at: date) }
    func unsave(roomId: String, eventId: String) { list.unsave(roomId: roomId, eventId: eventId) }
    func cancelScheduled(id: String) { list.cancelScheduled(id: id) }
    func merge(_ chatIds: [String], name: String, defaultRoom: String) {
        list.merge(chatIds: chatIds, name: name, defaultRoom: defaultRoom)
    }
    func unmerge(_ chatId: String) { list.unmerge(chatId: chatId) }
    func reorder(_ places: [Place]) { list.reorder(places: places.map(CorePlace.init)) }
    func setHidden(_ place: Place, _ hidden: Bool) { list.setHidden(place: CorePlace(place), hidden: hidden) }
    func showAllPlaces() { list.showAllPlaces() }
    func setTheme(_ place: Place, _ theme: PlaceTheme?) { list.setTheme(place: CorePlace(place), theme: theme.map(CoreTheme.init)) }
    func setDefaultTheme(_ theme: PlaceTheme) { list.setDefaultTheme(theme: CoreTheme(theme)) }
    func setInbox(_ place: Place, _ rule: InboxRule) { list.setInbox(place: CorePlace(place), rule: CoreInboxRule(rule)) }
    func setNotifications(_ chatId: String, _ setting: NotificationSetting) {
        list.setNotifications(chat: chatId, mode: CoreNotificationMode(setting))
    }
    func setNotifications(_ place: Place, _ setting: NotificationSetting) {
        list.setPlaceNotifications(place: CorePlace(place), mode: CoreNotificationMode(setting))
    }
}

/// Passes the core's batches on, mapped where they arrive, so the main actor only applies them;
/// ends the stream when the list goes.
private final class Relay: CoreListListener {
    private let continuation: AsyncStream<ChatListEvent>.Continuation

    init(_ continuation: AsyncStream<ChatListEvent>.Continuation) { self.continuation = continuation }
    deinit { continuation.finish() }

    func onUpdate(update: CoreListUpdate) { continuation.yield(.batch(ChatListBatch(update))) }
    func onError(error: CoreAccountError) { continuation.yield(.failed(AccountFailure(error))) }
}

// MARK: Mappings

private extension ChatListBatch {
    init(_ update: CoreListUpdate) {
        let place = Place(update.place)
        var saved: [String: SavedMessage] = [:]
        var scheduled: [String: ScheduledMessage] = [:]
        let row = { (row: CoreListRow) -> ChatRow in
            switch row {
            case .chat(let chat):
                // the Reminders list shows when to answer each chat before its newest message.
                return place == .reminders ? ChatRow(chat).reminded : ChatRow(chat)
            case .request(let request):
                return ChatRequest(request).row
            case .saved(let message, let chat):
                let message = SavedMessage(message)
                let row = message.row(in: chat.map(ChatRow.init))
                saved[row.id] = message
                return row
            case .scheduled(let message, let chat):
                let message = ScheduledMessage(id: message.id, roomId: message.room, body: message.body, sendAt: message.sendAt)
                let row = message.row(in: chat.map(ChatRow.init))
                scheduled[row.id] = message
                return row
            }
        }
        let rows = update.rows.map { section in
            SectionEdits(section: section.section.key, edits: section.diffs.map { $0.edit.map(row) })
        }
        self.init(place: place, selection: update.selection,
                  places: update.places?.map { listed in
                      let place = Place(listed.place)
                      let avatar: ImageRef? = if case .space(let id) = place { listed.avatar.map { .room(id: id, version: $0) } } else { nil }
                      var item = Places.item(place, unread: Int(listed.unread), isHidden: listed.isHidden, name: listed.name, avatar: avatar)
                      item.theme = PlaceTheme(listed.theme)
                      item.ownTheme = listed.ownTheme.map(PlaceTheme.init)
                      item.inbox = listed.inbox.map(InboxRule.init)
                      item.notifications = listed.notifications.map(NotificationSetting.init)
                      return item
                  },
                  theme: update.theme.map(PlaceTheme.init),
                  sections: update.sections?.map { header in
                      Header(id: header.id.key, title: header.title, style: header.style == .grid ? .grid : .list)
                  },
                  rows: rows, saved: saved, scheduled: scheduled,
                  labels: update.labels?.map { ChatLabel(id: $0.id, name: $0.name, rooms: Set($0.chats)) },
                  reminders: update.reminders?.map { Reminder(chatId: $0.chat, name: $0.name, date: $0.at) },
                  loading: update.loading.map { loading in
                      let state: ChatListModel.LoadState = switch loading.state {
                      case .connecting: .loading
                      case .syncing(let newChats): .syncing(newChats: Int(newChats))
                      case .done: .done
                      }
                      return Loading(state: state, answered: loading.answered)
                  },
                  keptOut: update.keptOut?.mapValues(Place.init),
                  badge: update.badge.map { BadgeState(count: Int($0.count), counted: Set($0.counted), uncounted: Set($0.uncounted)) })
    }
}

private extension CoreListRowDiff {
    var edit: ListEdit<CoreListRow> {
        switch self {
        case .append(let values): .append(values)
        case .clear: .clear
        case .pushFront(let value): .pushFront(value)
        case .pushBack(let value): .pushBack(value)
        case .popFront: .popFront
        case .popBack: .popBack
        case .insert(let index, let value): .insert(Int(index), value)
        case .set(let index, let value): .set(Int(index), value)
        case .remove(let index): .remove(Int(index))
        case .truncate(let length): .truncate(Int(length))
        case .reset(let values): .reset(values)
        }
    }
}

extension CoreChatChange {
    init(_ change: ChatChange) {
        self = switch change {
        case .read: .read
        case .unread: .unread
        case .lowPriority: .lowPriority
        case .inbox: .inbox
        case .archive: .archive
        case .unarchive: .unarchive
        case .delete: .delete
        case .pin: .pin
        case .unpin: .unpin
        }
    }
}
