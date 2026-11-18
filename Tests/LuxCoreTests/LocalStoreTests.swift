import Foundation
import Testing
@testable import LuxCore

@Suite struct LocalStoreTests {
    let key = String(repeating: "ab", count: 32)

    func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lux-search-\(UUID().uuidString)/index.sqlite")
    }

    func message(_ id: String, _ body: String, room: String = "!a", at seconds: Double = 0) -> IndexedMessage {
        IndexedMessage(eventId: id, roomId: room, senderName: "Anna Nováková", body: body,
                       date: Date(timeIntervalSince1970: 1_700_000_000 + seconds), isOwn: false)
    }

    // the store itself is tested in Rust (`core/crates/lux-store`); this checks the mapping.
    @Test func hitsComeBackWithTheirWordsInUTF16() async throws {
        let store = try await LocalStore.open(file: file(), key: key)
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

@Suite struct SearchIndexerTests {
    @Test func indexesTheNewestChatsAndThenOnlyWhatIsNew() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lux-indexer-\(UUID().uuidString)/index.sqlite")
        let store = try await LocalStore.open(file: file, key: String(repeating: "ef", count: 32))
        // more chats than it reads, each with more than one quick read's pages.
        let account = RustAccount.demo(rooms: 10, messagesPerRoom: 300)
        let (reports, report) = AsyncStream<SearchIndexer.Progress>.makeStream()
        let indexer = SearchIndexer(store: store, account: Task { account }, maxChats: 3) { report.yield($0) }
        try await leased { lease in await indexer.update(lease: lease) }
        for await progress in reports where !progress.isIndexing { break }

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
        for await progress in reports where !progress.isIndexing { break }
        #expect(try await store.messageCount() == first)
        await store.close()
    }

    @Test func aChatGoneFromTheListIsForgotten() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lux-indexer-\(UUID().uuidString)/index.sqlite")
        let store = try await LocalStore.open(file: file, key: String(repeating: "ef", count: 32))
        // a chat the index read before it was left.
        try await store.add([IndexedMessage(eventId: "$left", roomId: "!left", senderName: "Anna", body: "farewell",
                                            date: .now, isOwn: false)])
        try await store.setChat("!left", IndexedChat(newest: .now, complete: true))
        let account = RustAccount.demo(rooms: 20, messagesPerRoom: 5)
        let (reports, report) = AsyncStream<SearchIndexer.Progress>.makeStream()
        let indexer = SearchIndexer(store: store, account: Task { account }, maxChats: 3) { report.yield($0) }

        try await leased { lease in await indexer.update(lease: lease) }
        for await progress in reports where !progress.isIndexing { break }

        #expect(try await store.search("farewell").isEmpty)
        #expect(try await store.chats()["!left"] == nil)
    }
}

@MainActor
@Suite(.closesDemoSessions)
struct MergedChatSearchTests {
    @Test func everyRoomOfAMergedChatIsIndexed() async throws {
        let session = DemoSessions.open(rooms: 20, messagesPerRoom: 5)
        let list = ChatListModel(session: session)
        let shown = list.changes()
        await shown.until { list.rows.count >= 2 }
        let (first, second) = (list.rows[0], list.rows[1])
        list.merge(first, with: second)
        await shown.until { list.rows.contains { $0.isMerged } }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lux-indexer-\(UUID().uuidString)/index.sqlite")
        let store = try await LocalStore.open(file: file, key: String(repeating: "ef", count: 32))
        let (reports, report) = AsyncStream<SearchIndexer.Progress>.makeStream()
        let indexer = SearchIndexer(store: store, account: Task { [account = session.account] in try await account.value }, maxChats: 1) { report.yield($0) }
        try await leased { lease in await indexer.update(lease: lease) }
        for await progress in reports where !progress.isIndexing { break }

        let indexed = try await store.chats()
        #expect(indexed[first.id] != nil && indexed[second.id] != nil)
    }
}

/// The search index follows the whole account, not the place on screen.
@MainActor
@Suite(.closesDemoSessions)
struct MessageSearchTests {
    @Test func aChangeInAChatOutsideThePlaceOnScreenMakesTheIndexReadAgain() async throws {
        let session = DemoSessions.open(rooms: 40, messagesPerRoom: 5)
        let account = try await session.account.value
        // the list shows Signal's chats; the change comes in a chat elsewhere.
        let list = ChatListModel(session: session)
        let shown = list.changes()
        list.place = .network("signal")
        await shown.until { !list.rows.isEmpty && list.rows.allSatisfy { $0.network == "signal" } }
        let elsewhere = try #require(await account.chats().first { $0.network != "signal" })

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lux-search-\(UUID().uuidString)/index.sqlite")
        let store = try await LocalStore.open(file: file, key: String(repeating: "5e", count: 32))
        let search = MessageSearch(store: store, account: Task { [account = session.account] in try await account.value },
                                   photos: file.deletingLastPathComponent())
        let (read, token) = search.changes()
        await read.until { search.progress?.isIndexing == false }
        #expect(try await store.search("lighthouse").isEmpty)

        // a new message there: the index reads that chat again, and search finds it.
        var readsAgain = false
        let counting = search.progressChanges.observe { if search.progress?.isIndexing == true { readsAgain = true } }
        let chat = ThreadModel(session: session, row: elsewhere)
        let sent = chat.changes()
        await chat.start()
        chat.send("meet at the lighthouse")
        await sent.until { chat.messages.last?.body == "meet at the lighthouse" }
        await read.until { readsAgain && search.progress?.isIndexing == false }
        let found = try await store.search("lighthouse")
        #expect(found.map(\.roomId) == [elsewhere.id])
        withExtendedLifetime((token, counting)) {}
        await search.stop()
        await store.close()
    }
}

/// The search index over its port alone: a made-up server with two chats, one message each.
@Suite struct IndexSourcePortTests {
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
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lux-indexer-\(UUID().uuidString)/index.sqlite")
        let store = try await LocalStore.open(file: file, key: String(repeating: "ef", count: 32))
        let indexer = SearchIndexer(store: store, account: Task { Server() }) { _ in }
        try await leased { lease in await indexer.update(lease: lease) }
        #expect(try await store.messageCount() == 2)
        #expect(try await store.search("pizz").count == 2)
    }
}
