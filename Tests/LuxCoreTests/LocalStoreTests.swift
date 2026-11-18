import Foundation
import Testing
@testable import LuxCore

@Suite(.ownFolder, .timeLimit(.minutes(1))) struct LocalStoreTests {
    func message(_ id: String, _ body: String, room: String = "!a", at seconds: Double = 0) -> IndexedMessage {
        IndexedMessage(eventId: id, roomId: room, senderName: "Anna Nováková", body: body,
                       date: Date(timeIntervalSince1970: 1_700_000_000 + seconds), isOwn: false)
    }

    // the store itself is tested in Rust (`core/crates/lux-store`); this checks the mapping.
    @Test func hitsComeBackWithTheirWordsInUTF16() async throws {
        let store = try await TemporaryFolder.store()
        try await store.add([message("$1", "😀 Uvidíme se zítra ráno", at: 1), message("$2", "jindy", room: "!b", at: 2)])
        try await store.setChat("!a", IndexedChat(newest: Date(timeIntervalSince1970: 1_700_000_001), complete: true))
        let hit = try #require(try await store.search("zit").first)
        #expect(hit.eventId == "$1" && hit.roomId == "!a" && hit.senderName == "Anna Nováková" && !hit.isOwn)
        #expect(hit.date == Date(timeIntervalSince1970: 1_700_000_001))
        #expect(hit.matches.map { (hit.excerpt as NSString).substring(with: $0) } == ["zítra"])
        #expect(try await store.search("jindy", in: "!a").isEmpty)
        #expect(try await store.chats() == ["!a": IndexedChat(newest: Date(timeIntervalSince1970: 1_700_000_001), complete: true)])
        #expect(try await store.messageCount() == 2)
    }
}

@Suite(.ownPreferences, .ownFolder, .timeLimit(.minutes(1))) struct SearchIndexerTests {
    @Test func indexesTheNewestChatsAndThenOnlyWhatIsNew() async throws {
        let store = try await TemporaryFolder.store()
        // more chats than it reads, each with more than one quick read's pages.
        let account = RustAccount.demo(rooms: 10, messagesPerRoom: 300)
        let (reports, report) = AsyncStream<SearchIndexer.Progress>.makeStream()
        let indexer = SearchIndexer(store: store, account: Task { account }, maxChats: 3, preferences: try Preferences.ofTest) { report.yield($0) }
        try await leased { lease in await indexer.update(lease: lease) }
        _ = try await reports.first { !$0.isIndexing }

        // the three newest chats, and only they.
        let listed = await account.chats()
        let newest = listed.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(3)
        #expect(Set(try await store.chats().keys) == Set(newest.map(\.id)))
        let first = try await store.messageCount()
        #expect(first > 0)
        // every word of a message's text finds it, by its words' starts.
        let any = try #require(try await store.search("coff").first)
        #expect(any.excerpt.lowercased().contains("coff"))
        // nothing new: a second run adds nothing.
        try await leased { lease in await indexer.update(lease: lease) }
        _ = try await reports.first { !$0.isIndexing }
        #expect(try await store.messageCount() == first)
    }

    @Test func aChatGoneFromTheListIsForgotten() async throws {
        let store = try await TemporaryFolder.store()
        // a chat the index read before it was left.
        try await store.add([IndexedMessage(eventId: "$left", roomId: "!left", senderName: "Anna", body: "farewell",
                                            date: .now, isOwn: false)])
        try await store.setChat("!left", IndexedChat(newest: .now, complete: true))
        let account = RustAccount.demo(rooms: 20, messagesPerRoom: 5)
        let (reports, report) = AsyncStream<SearchIndexer.Progress>.makeStream()
        let indexer = SearchIndexer(store: store, account: Task { account }, maxChats: 3, preferences: try Preferences.ofTest) { report.yield($0) }

        try await leased { lease in await indexer.update(lease: lease) }
        _ = try await reports.first { !$0.isIndexing }

        #expect(try await store.search("farewell").isEmpty)
        #expect(try await store.chats()["!left"] == nil)
    }
}

/// An index damaged as a crash in a write leaves it (a page that fails its check) gives way to a
/// new one, which search reads again: search does not find nothing for good. (Which damage the
/// store finds, and when, is tested in Rust: `core/crates/lux-store/tests/damaged.rs`.)
@MainActor
@Suite(.ownPreferences, .ownFolder, .timeLimit(.minutes(1))) struct DamagedIndexTests {
    @Test func anIndexFoundDamagedIsReadAgain() async throws {
        let account = RustAccount.demo(rooms: 10, messagesPerRoom: 300)
        // an index read whole, a large value kept after it: its pages last in the file.
        let first = try await TemporaryFolder.store(named: "index")
        let filling = try search(over: first, account)
        try await read(by: filling)
        await filling.stop()
        try await first.keep("large", Data(count: 40 * 4096))
        await first.close()
        // a page of the large value damaged: the store opens, and finds it when it is read.
        let file = try TemporaryFolder.storeFile(named: "index")
        var bytes = try Data(contentsOf: file)
        let page = bytes.count - 20 * 4096
        for index in page + 100..<page + 200 { bytes[index] ^= 0xa5 }
        try bytes.write(to: file)

        let store = try await TemporaryFolder.store(named: "index")
        let search = try search(over: store, account)
        try await read(by: search)
        #expect(try await !store.search("coff").isEmpty)
        let changes = Changes()
        var readAgain = false
        let watching = search.progressChanges.observe {
            if search.progress?.isIndexing == true { readAgain = true }
            changes.send()
        }
        await #expect(throws: (any Error).self) { try await store.kept("large") }
        try await changes.until { readAgain && search.progress?.isIndexing == false }
        withExtendedLifetime(watching) {}
        #expect(try await store.kept("large") == nil)
        #expect(try await !store.search("coff").isEmpty)
        await search.stop()
    }

    private func search(over store: LocalStore, _ account: RustAccount) throws -> MessageSearch {
        MessageSearch(store: store, account: Task { account }, photos: try TemporaryFolder.ofTest.appending(path: "photos"),
                      maxChats: 3, preferences: try Preferences.ofTest)
    }

    /// Waits for `search`'s index to have read every chat it reads.
    private func read(by search: MessageSearch) async throws {
        let changes = Changes()
        let watching = search.progressChanges.observe { changes.send() }
        try await changes.until { search.progress?.isIndexing == false }
        withExtendedLifetime(watching) {}
    }
}

@MainActor
@Suite(.closesDemoSessions, .timeLimit(.minutes(1)))
struct MergedChatSearchTests {
    @Test func everyRoomOfAMergedChatIsIndexed() async throws {
        let session = try DemoSessions.open(rooms: 20, messagesPerRoom: 5)
        let list = ChatListModel(session: session)
        let shown = list.changes()
        try await shown.until { list.rows.count >= 2 }
        let (first, second) = (list.rows[0], list.rows[1])
        list.merge(first, with: second)
        try await shown.until { list.rows.contains { $0.isMerged } }

        let store = try await TemporaryFolder.store()
        let (reports, report) = AsyncStream<SearchIndexer.Progress>.makeStream()
        let indexer = SearchIndexer(store: store, account: Task { [account = session.account] in try await account.value }, maxChats: 1,
                                    preferences: session.preferences) { report.yield($0) }
        try await leased { lease in await indexer.update(lease: lease) }
        _ = try await reports.first { !$0.isIndexing }

        let indexed = try await store.chats()
        #expect(indexed[first.id] != nil && indexed[second.id] != nil)
    }
}

/// The search index follows the whole account, not the place on screen.
@MainActor
@Suite(.closesDemoSessions, .timeLimit(.minutes(1)))
struct MessageSearchTests {
    @Test func aChangeInAChatOutsideThePlaceOnScreenMakesTheIndexReadAgain() async throws {
        let session = try DemoSessions.open(rooms: 40, messagesPerRoom: 5)
        let account = try await session.account.value
        // the list shows Signal's chats; the change comes in a chat elsewhere.
        let list = ChatListModel(session: session)
        let shown = list.changes()
        list.place = .network("signal")
        try await shown.until { !list.rows.isEmpty && list.rows.allSatisfy { $0.network == "signal" } }
        let elsewhere = try #require(await account.chats().first { $0.network != "signal" })

        let store = try await TemporaryFolder.store()
        let search = MessageSearch(store: store, account: Task { [account = session.account] in try await account.value },
                                   photos: try TemporaryFolder.ofTest, preferences: session.preferences)
        let (read, token) = search.changes()
        try await read.until { search.progress?.isIndexing == false }
        #expect(try await store.search("lighthouse").isEmpty)

        // a new message there: the index reads that chat again, and search finds it.
        var readsAgain = false
        let counting = search.progressChanges.observe { if search.progress?.isIndexing == true { readsAgain = true } }
        let chat = ThreadModel(session: session, row: elsewhere)
        let sent = chat.changes()
        await chat.start()
        chat.send("meet at the lighthouse")
        try await sent.until { chat.messages.last?.body == "meet at the lighthouse" }
        try await read.until { readsAgain && search.progress?.isIndexing == false }
        let found = try await store.search("lighthouse")
        #expect(found.map(\.roomId) == [elsewhere.id])
        withExtendedLifetime((token, counting)) {}
        await search.stop()
    }
}

/// The search index over its port alone: a made-up server with two chats, one message each.
@Suite(.ownPreferences, .ownFolder, .timeLimit(.minutes(1))) struct IndexSourcePortTests {
    private struct Server: IndexSourcePort {
        let now = Date()

        func chats() async -> [ChatRow] {
            [ChatRow(id: "!a", name: "Anna", preview: "", date: now), ChatRow(id: "!b", name: "Bob", preview: "", date: now)]
        }
        func indexHistory(roomId: String, since: Date, from: String?, maxPages: Int) async throws -> IndexHistoryPage {
            IndexHistoryPage(messages: [IndexedMessage(eventId: "$\(roomId)", roomId: roomId, senderName: "Anna",
                                                       body: "pizza in \(roomId)", date: now, isOwn: false)],
                             reachedStart: true)
        }
    }

    @Test func readsEveryChatsHistoryIntoTheIndex() async throws {
        let store = try await TemporaryFolder.store()
        let indexer = SearchIndexer(store: store, account: Task { Server() }, preferences: try Preferences.ofTest) { _ in }
        try await leased { lease in await indexer.update(lease: lease) }
        #expect(try await store.messageCount() == 2)
        #expect(try await store.search("pizz").count == 2)
    }
}
