import Foundation

/// Fills the search index from the account, chat by chat, the most recent chats first: a quick
/// first pass reads each chat's newest messages, so search finds recent ones within moments; a
/// second pass reads back as far as Settings asks (three months, a year, all), a few pages of
/// each chat at a time, going on where the last stopped. Afterwards each change to a chat reads
/// only what is new.
/// Runs off the main thread, one chat at a time, so the app stays quick while it works.
public actor SearchIndexer {
    /// How far the index is, for the UI.
    public struct Progress: Sendable, Equatable {
        /// Chats read in the current pass, and how many it has.
        public var chats: Int
        public var total: Int
        /// The pass: the newest messages of every chat, then their history.
        public var deep: Bool
        public var isIndexing: Bool
        public var messages: Int
        /// The index's first fill (it had no chats): worth telling the user. A later update reads
        /// a few new messages and says nothing.
        public var isFirstFill = false

        /// What search results say while the index is not complete: their messages are those
        /// read so far. Nil once it is.
        public var note: String? {
            guard isIndexing, total > 0 else { return nil }
            return deep ? String(localized: "Still reading older messages · \(chats) of \(total) chats")
                        : String(localized: "Still reading new messages · \(chats) of \(total) chats")
        }

        public init(chats: Int, total: Int, deep: Bool, isIndexing: Bool, messages: Int, isFirstFill: Bool = false) {
            self.chats = chats; self.total = total; self.deep = deep; self.isIndexing = isIndexing; self.messages = messages
            self.isFirstFill = isFirstFill
        }
    }

    /// The horizon moves with the clock: a chat read back to it is read further a week at a time,
    /// not a page on every pass.
    static let slack: TimeInterval = 7 * 24 * 3600
    static let quickPages = 4
    static let deepPages = 40

    private let store: LocalStore
    private let account: Task<RustAccount, any Error>
    private let maxChats: Int?
    private var chats: [String: IndexedChat] = [:]
    private var loaded = false
    /// The pass under way started with an empty index.
    private var firstFill = false
    private var running: Task<Void, Never>?
    private var again = false
    private let report: @Sendable (Progress) -> Void

    /// `maxChats`: index only the most recent chats (the demo's thousands of made-up ones).
    init(store: LocalStore, account: Task<RustAccount, any Error>, maxChats: Int? = nil, report: @escaping @Sendable (Progress) -> Void) {
        self.store = store
        self.account = account
        self.maxChats = maxChats
        self.report = report
    }

    /// Brings the index up to date: now, or once the run in progress ends.
    public func update() {
        if running != nil { again = true; return }
        running = Task { await run() }
    }

    public func stop() {
        running?.cancel()
        running = nil
    }

    private func run() async {
        repeat {
            again = false
            await pass()
        } while again && !Task.isCancelled
        running = nil
    }

    private func pass() async {
        if !loaded {
            chats = (try? await store.chats()) ?? [:]
            loaded = true
        }
        guard let account = try? await account.value else { return }
        let all = await account.chats()
        firstFill = chats.isEmpty
        await forgetGone(listed: all)
        // each chat's rooms (a merged chat's several), with the chat's newest date.
        let rooms = (maxChats.map { Array(all.prefix($0)) } ?? all).flatMap { row in
            (row.isMerged ? row.rooms.map(\.id) : [row.id]).map { IndexedRoom(id: $0, date: row.date) }
        }
        let horizon = await MainActor.run { Preferences.shared.searchHistory.since(.now) }
        // quick: rooms with nothing indexed, or with newer messages; deep: rooms not read back
        // to their start or as far as Settings asks.
        let quick = rooms.filter { room in
            guard let indexed = chats[room.id] else { return true }
            return (room.date ?? .distantPast) > indexed.newest
        }
        await read(quick, deep: false, back: horizon, from: account)
        await read(rooms.filter { room in
            guard let indexed = chats[room.id] else { return true }
            return !indexed.complete && (indexed.oldest ?? .distantFuture) > horizon.addingTimeInterval(Self.slack)
        }, deep: true, back: horizon, from: account)
        report(Progress(chats: 0, total: 0, deep: true, isIndexing: false, messages: (try? await store.messageCount()) ?? 0))
    }

    /// A room to read: its id, and its chat's newest message.
    private struct IndexedRoom {
        var id: String
        var date: Date?
    }

    /// Forgets the rooms the account's list no longer shows (left, or deleted with nothing newer):
    /// search finds nothing the app does not show.
    private func forgetGone(listed rows: [ChatRow]) async {
        // an empty list is the account's before its rooms came, not every chat gone.
        guard !rows.isEmpty else { return }
        let listed = Set(rows.flatMap { $0.isMerged ? $0.rooms.map(\.id) : [$0.id] })
        for room in chats.keys where !listed.contains(room) {
            do {
                try await store.forgetChat(room)
                chats[room] = nil
            } catch {
                Log.app.error("search index: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Reads `rooms`: `deep`, a few pages further back from where each stopped, to `horizon`;
    /// else what came since each's newest indexed (back to `horizon`, a room not read before).
    private func read(_ rooms: [IndexedRoom], deep: Bool, back horizon: Date, from account: RustAccount) async {
        for (done, room) in rooms.enumerated() {
            if Task.isCancelled { return }
            report(Progress(chats: done, total: rooms.count, deep: deep, isIndexing: true, messages: 0, isFirstFill: firstFill))
            let indexed = chats[room.id]
            let walksBack = deep || indexed == nil
            let since = walksBack ? horizon : indexed?.newest ?? horizon
            guard let page = try? await account.indexHistory(roomId: room.id, since: since, from: deep ? indexed?.older : nil,
                                                             maxPages: deep ? Self.deepPages : Self.quickPages) else { continue }
            do {
                if let until = page.deletedUntil { try await store.forgetChat(room.id, until: until) }
                try await store.add(page.messages)
                // photos are kept from the start: turning photo search on reads them, with no
                // walk back through every chat again.
                try await store.addImages(page.images)
                try await store.addFiles(page.files)
                try await store.remove(page.removed)
                let newest = [page.messages.map(\.date).max(), page.images.map(\.date).max(), page.files.map(\.date).max(),
                              room.date, indexed?.newest]
                    .compactMap(\.self).max() ?? .distantPast
                var chat = indexed ?? IndexedChat(newest: newest, complete: false)
                chat.newest = newest
                if walksBack {
                    // how far back it is read now, and where a walk further back goes on.
                    let read = page.messages.map(\.date) + page.images.map(\.date) + page.files.map(\.date)
                    chat.complete = page.reachedStart || page.deletedUntil != nil
                    chat.oldest = page.reachedSince ? horizon : (read + [chat.oldest].compactMap(\.self)).min()
                    chat.older = page.older
                }
                try await store.setChat(room.id, chat)
                chats[room.id] = chat
            } catch {
                Log.app.error("search index: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
