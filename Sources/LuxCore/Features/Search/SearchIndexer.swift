import Foundation

/// Fills the search index from the account, chat by chat, the most recent chats first: a quick
/// first pass reads each chat's newest messages, so search finds recent ones within moments; a
/// second pass reads back three months. Afterwards each change to a chat reads only what is new.
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

    /// How far back the second pass reads.
    static let history: TimeInterval = 90 * 24 * 3600
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
        // quick: rooms with nothing indexed, or with newer messages; deep: rooms not read back yet.
        let quick = rooms.filter { room in
            guard let indexed = chats[room.id] else { return true }
            return (room.date ?? .distantPast) > indexed.newest
        }
        await read(quick, deep: false, from: account)
        await read(rooms.filter { chats[$0.id]?.complete != true }, deep: true, from: account)
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

    private func read(_ rooms: [IndexedRoom], deep: Bool, from account: RustAccount) async {
        for (done, room) in rooms.enumerated() {
            if Task.isCancelled { return }
            report(Progress(chats: done, total: rooms.count, deep: deep, isIndexing: true, messages: 0, isFirstFill: firstFill))
            let indexed = chats[room.id]
            // history back three months; afterwards only what came since the newest indexed.
            let since = if let indexed, indexed.complete { indexed.newest } else { Date.now.addingTimeInterval(-Self.history) }
            guard let page = try? await account.indexHistory(roomId: room.id, since: since,
                                                             maxPages: deep ? Self.deepPages : Self.quickPages) else { continue }
            do {
                if let until = page.deletedUntil { try await store.forgetChat(room.id, until: until) }
                try await store.add(page.messages)
                // photos are kept from the start: turning photo search on reads them, with no
                // walk back through every chat again.
                try await store.addImages(page.images)
                try await store.remove(page.removed)
                let newest = [page.messages.map(\.date).max(), page.images.map(\.date).max(), room.date, indexed?.newest]
                    .compactMap(\.self).max() ?? .distantPast
                let chat = IndexedChat(newest: newest, complete: indexed?.complete == true || deep)
                try await store.setChat(room.id, chat)
                chats[room.id] = chat
            } catch {
                Log.app.error("search index: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
