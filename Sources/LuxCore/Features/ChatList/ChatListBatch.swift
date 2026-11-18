import Foundation

/// One frame's changes to the chat list, as the core's view model sent them, in the app's types:
/// what did not change is nil or empty. Made off the main thread; the list's model applies it.
struct ChatListBatch: Sendable {
    /// A section without its rows.
    struct Header: Sendable, Equatable {
        var id: String
        var title: String?
        var style: ChatSection.Style
    }

    /// The changes to one section's rows, in order.
    struct SectionEdits: Sendable {
        var section: String
        var edits: [ListEdit<ChatRow>]
    }

    /// A chat with a reminder, for its notification.
    struct Reminder: Sendable, Equatable {
        var chatId: String
        var name: String
        var date: Date
    }

    struct Loading: Sendable, Equatable {
        var state: ChatListModel.LoadState
        /// The server answered the first sync.
        var answered: Bool
    }

    /// The place shown: the one asked for, or the inbox when it went away.
    var place: Place
    /// The newest selection (`ChatListView.select`'s number) this batch shows, when newer than the
    /// last batch's. Until the newest one asked for comes, a batch shows a place asked for before.
    var selection: UInt64?
    var places: [PlaceItem]?
    /// The colour of the places without one of their own, when it changed.
    var theme: PlaceTheme?
    /// The sections in order, when one came or went.
    var sections: [Header]?
    var rows: [SectionEdits]
    /// The saved and the waiting messages of the rows in this batch, by row id.
    var saved: [String: SavedMessage]
    var scheduled: [String: ScheduledMessage]
    var labels: [ChatLabel]?
    var reminders: [Reminder]?
    var loading: Loading?
    /// The chats (by id) a place's rule keeps out of the inbox, with that place, when they changed.
    var keptOut: [String: Place]?
    /// The app's badge, with what the notification extension needs to keep it, when it changed.
    var badge: BadgeState?
}

extension [ChatSection] {
    /// Applies a batch's sections and rows; returns the ids of rows that were there before and
    /// now show something else (what a diffable data source reconfigures). Only the rows the
    /// batch touches are looked at.
    mutating func apply(_ batch: ChatListBatch) -> [String] {
        if let headers = batch.sections {
            let kept = Dictionary(map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            self = headers.map { header in
                var section = kept[header.id] ?? ChatSection(id: header.id, title: header.title, rows: [], style: header.style)
                section.title = header.title
                section.style = header.style
                return section
            }
        }
        // a row that moved is removed and inserted: it changed when its value did.
        var removed: [String: ChatRow] = [:]
        var changed: [String] = []
        var inserted: [ChatRow] = []
        for section in batch.rows {
            guard let index = firstIndex(where: { $0.id == section.section }) else { continue }
            for edit in section.edits {
                // read in place: a copy of the rows would be copied whole by the edit.
                switch edit {
                case .set(let at, let row):
                    if self[index].rows.indices.contains(at), self[index].rows[at] != row { changed.append(row.id) }
                case .remove(let at):
                    if self[index].rows.indices.contains(at) { removed[self[index].rows[at].id] = self[index].rows[at] }
                case .insert(_, let row), .pushFront(let row), .pushBack(let row):
                    inserted.append(row)
                case .append(let new):
                    inserted.append(contentsOf: new)
                case .reset(let new):
                    for row in self[index].rows { removed[row.id] = row }
                    inserted.append(contentsOf: new)
                case .clear, .truncate, .popFront, .popBack:
                    break
                }
                self[index].rows.apply(edit)
            }
        }
        for row in inserted {
            if let before = removed[row.id], before != row { changed.append(row.id) }
        }
        return changed
    }
}
