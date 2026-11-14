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
        let account = Task<RustAccount, any Error> { RustAccount.demo(rooms: 2_000, messagesPerRoom: 3_000) }
        let (reports, report) = AsyncStream<SearchIndexer.Progress>.makeStream()
        let indexer = SearchIndexer(store: store, account: account, maxChats: 3) { report.yield($0) }
        await indexer.update()
        for await progress in reports where !progress.isIndexing { break }
        let first = try await store.messageCount()
        #expect(first > 0)
        // every word of a message's text finds it, by its words' starts.
        let any = try #require(try await store.search("coff").first)
        #expect(any.excerpt.lowercased().contains("coff"))
        // nothing new: a second run adds nothing.
        await indexer.update()
        for await progress in reports where !progress.isIndexing { break }
        #expect(try await store.messageCount() == first)
    }

    @Test func aChatGoneFromTheListIsForgotten() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lux-indexer-\(UUID().uuidString)/index.sqlite")
        let store = try await LocalStore.open(file: file, key: String(repeating: "ef", count: 32))
        // a chat the index read before it was left.
        try await store.add([IndexedMessage(eventId: "$left", roomId: "!left", senderName: "Anna", body: "farewell",
                                            date: .now, isOwn: false)])
        try await store.setChat("!left", IndexedChat(newest: .now, complete: true))
        let account = Task<RustAccount, any Error> { RustAccount.demo(rooms: 20, messagesPerRoom: 5) }
        let (reports, report) = AsyncStream<SearchIndexer.Progress>.makeStream()
        let indexer = SearchIndexer(store: store, account: account, maxChats: 3) { report.yield($0) }

        await indexer.update()
        for await progress in reports where !progress.isIndexing { break }

        #expect(try await store.search("farewell").isEmpty)
        #expect(try await store.chats()["!left"] == nil)
    }
}

@MainActor
struct MergedChatSearchTests {
    @Test func everyRoomOfAMergedChatIsIndexed() async throws {
        let session = Session.demo(rooms: 20, messagesPerRoom: 5)
        let list = ChatListModel(session: session)
        let shown = list.changes()
        await shown.until { list.rows.count >= 2 }
        let (first, second) = (list.rows[0], list.rows[1])
        list.merge(first, with: second)
        await shown.until { list.rows.contains { $0.isMerged } }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lux-indexer-\(UUID().uuidString)/index.sqlite")
        let store = try await LocalStore.open(file: file, key: String(repeating: "ef", count: 32))
        let (reports, report) = AsyncStream<SearchIndexer.Progress>.makeStream()
        let indexer = SearchIndexer(store: store, account: session.account, maxChats: 1) { report.yield($0) }
        await indexer.update()
        for await progress in reports where !progress.isIndexing { break }

        let indexed = try await store.chats()
        #expect(indexed[first.id] != nil && indexed[second.id] != nil)
    }
}

/// The search index follows the whole account, not the place on screen.
@MainActor
struct MessageSearchTests {
    @Test func aChangeInAChatOutsideThePlaceOnScreenMakesTheIndexReadAgain() async throws {
        let session = Session.demo(rooms: 40, messagesPerRoom: 5)
        let account = try await session.account.value
        // the list shows Signal's chats; the change comes in a chat elsewhere.
        let list = ChatListModel(session: session)
        let shown = list.changes()
        list.place = .network("signal")
        await shown.until { !list.rows.isEmpty && list.rows.allSatisfy { $0.network == "signal" } }
        let elsewhere = try #require(await account.chats().first { $0.network != "signal" && !$0.isPinned })

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lux-search-\(UUID().uuidString)/index.sqlite")
        let search = MessageSearch(store: try await LocalStore.open(file: file, key: String(repeating: "5e", count: 32)),
                                   account: session.account, maxChats: 3)
        let (read, token) = search.changes()
        var reports = 0
        let counting = search.progressChanges.observe { reports += 1 }
        await read.until { search.progress?.isIndexing == false }
        let filled = reports

        list.change(elsewhere.id, .pin)
        await read.until { reports > filled }
        withExtendedLifetime((token, counting)) {}
    }
}
