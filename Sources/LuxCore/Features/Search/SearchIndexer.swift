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
    private let account: Task<any IndexSourcePort, any Error>
    private let maxChats: Int?
    private var chats: [String: IndexedChat] = [:]
    private var loaded = false
    /// The pass under way started with an empty index.
    private var firstFill = false
    private var isRunning = false
    private var stopped = false
    private var again = false
    /// The store made a new file in place of a damaged one: the next pass starts from nothing.
    private var replaced = false
    private let report: @Sendable (Progress) -> Void
    /// How far back each chat is read (Settings).
    private let preferences: Preferences

    /// `maxChats`: index only the most recent chats (the demo's thousands of made-up ones).
    init(store: LocalStore, account: Task<any IndexSourcePort, any Error>, maxChats: Int? = nil, preferences: Preferences,
         report: @escaping @Sendable (Progress) -> Void) {
        self.store = store
        self.account = account
        self.maxChats = maxChats
        self.preferences = preferences
        self.report = report
    }

    /// Brings the index up to date, in the caller's task (cancelling it ends the reading): now,
    /// or, while a run is under way, once more when it ends, and this returns then.
    public func update(lease _: WorkLease) async {
        if isRunning {
            again = true
            await withCheckedContinuation { waiting.append($0) }
            return
        }
        isRunning = true
        repeat {
            again = false
            await pass()
        } while again && !Task.isCancelled && !stopped
        isRunning = false
        let waiters = waiting
        waiting = []
        for waiter in waiters { waiter.resume() }
    }

    /// The updates asked for while a run was under way: they return as it ends.
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Some chat is not read back as far as Settings asks yet: a deep pass has more to read.
    public func hasHistoryLeft() async -> Bool {
        if !loaded {
            chats = await bestEffort("search index: the indexed chats") { try await store.chats() } ?? [:]
            loaded = true
        }
        let horizon = await MainActor.run { [preferences] in preferences.searchHistory.since(.now) }
        return chats.values.contains { !$0.complete && ($0.oldest ?? .distantFuture) > horizon.addingTimeInterval(Self.slack) }
    }

    /// The account closes: no run goes on.
    public func stop() {
        stopped = true
    }

    /// The store made a new, empty file in place of a damaged one: the pass under way ends, and
    /// the next (an update's, or this run's once more) reads every chat again.
    func storeReplaced() {
        replaced = true
        again = true
    }

    private func pass() async {
        if replaced {
            replaced = false
            loaded = false
            // the pass that was under way may have written a chat into the new file as read
            // into the old one: it goes, with all else.
            await bestEffort("search index: empty the new file") { try await store.clearIndex() }
        }
        if !loaded {
            chats = await bestEffort("search index: the indexed chats") { try await store.chats() } ?? [:]
            loaded = true
        }
        guard let account = await bestEffort("search index: the account", { try await account.value }) else { return }
        let all = await account.chats()
        firstFill = chats.isEmpty
        await forgetGone(listed: all)
        // each chat's rooms (a merged chat's several), with the chat's newest date.
        let rooms = (maxChats.map { Array(all.prefix($0)) } ?? all).flatMap { row in
            (row.isMerged ? row.rooms.map(\.id) : [row.id]).map { IndexedRoom(id: $0, date: row.date) }
        }
        let horizon = await MainActor.run { [preferences] in preferences.searchHistory.since(.now) }
        // quick: rooms with nothing indexed, or with newer messages; deep: rooms not read back
        // to their start or as far as Settings asks.
        let quick = rooms.filter { room in
            guard let indexed = chats[room.id] else { return true }
            // to the nearest millisecond, as the store keeps it: a date a hair off it is no newer.
            return Self.millis(room.date ?? .distantPast) > Self.millis(indexed.newest)
        }
        await read(quick, deep: false, back: horizon, from: account)
        let deep = rooms.filter { room in
            guard let indexed = chats[room.id] else { return true }
            return !indexed.complete && (indexed.oldest ?? .distantFuture) > horizon.addingTimeInterval(Self.slack)
        }
        if !deep.isEmpty {
            let reasons = deep.map { room -> String in
                guard let indexed = chats[room.id] else { return "new" }
                return "oldest \(indexed.oldest.map { String(Int(-$0.timeIntervalSinceNow / 86_400)) + "d" } ?? "none"), older \(indexed.older == nil ? "none" : "some")"
            }
            let back = Int(-horizon.timeIntervalSinceNow / 86_400)
            Log.app.notice("search index: back \(back, privacy: .public)d, \(quick.count, privacy: .public) quick, \(deep.count, privacy: .public) deep: \(reasons.prefix(8).joined(separator: "; "), privacy: .public)")
        }
        await read(deep, deep: true, back: horizon, from: account)
        let messages = await bestEffort("search index: count") { try await store.messageCount() } ?? 0
        report(Progress(chats: 0, total: 0, deep: true, isIndexing: false, messages: messages))
    }

    private static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
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
    private func read(_ rooms: [IndexedRoom], deep: Bool, back horizon: Date, from account: any IndexSourcePort) async {
        for (done, room) in rooms.enumerated() {
            if Task.isCancelled || stopped || replaced { return }
            report(Progress(chats: done, total: rooms.count, deep: deep, isIndexing: true, messages: 0, isFirstFill: firstFill))
            let indexed = chats[room.id]
            let walksBack = deep || indexed == nil
            let since = walksBack ? horizon : indexed?.newest ?? horizon
            let page: IndexHistoryPage
            do {
                page = try await account.indexHistory(roomId: room.id, since: since, from: deep ? indexed?.older : nil,
                                                      maxPages: deep ? Self.deepPages : Self.quickPages)
            } catch {
                Log.app.notice("""
                    search index: a room's history not read (\(deep ? "deep" : "quick", privacy: .public)): \
                    \(String(describing: error), privacy: .public)
                    """)
                continue
            }
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
