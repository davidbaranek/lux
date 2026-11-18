import Foundation
import Testing
@testable import LuxCore

// The models that search as the user types, each over a made-up account that answers when the
// test says: the newest words' answer shows, an older words' answer that comes after it is
// dropped, and words cleared show what shows before any are typed. (Sign-in's server field is
// in `SignInTests`.)

private let anna = ChatRow(id: "!anna", name: "Anna", preview: "", date: Date(timeIntervalSince1970: 1_700_000_200))
private let bob = ChatRow(id: "!bob", name: "Bob", preview: "", date: Date(timeIntervalSince1970: 1_700_000_100))
private let carl = ChatRow(id: "!carl", name: "Carl", preview: "", date: Date(timeIntervalSince1970: 1_700_000_000))

/// What search reads of an account: Anna's and Bob's chats, which found chats come when the test
/// answers (`found`), and, with `shown`, which chats show the found messages' rooms too.
private struct SearchAccount: SearchSourcePort {
    let found = Held<String, [ChatRow]>()
    var shown: Held<[String], Void>?

    func chats() async -> [ChatRow] { [anna, bob] }
    func indexHistory(roomId: String, since: Date, from: String?, maxPages: Int) async throws -> IndexHistoryPage {
        IndexHistoryPage(messages: [], reachedStart: true)
    }
    func sharedFile(roomId: String, eventId: String, directory: URL) async throws -> URL { throw AccountFailure.file }
    func findChats(_ query: String, limit: Int) async -> [ChatRow] { await found.answer(for: query) }
    func chats(ofRooms rooms: [String]) async -> [String: ChatRow] {
        if let shown { await shown.answer(for: rooms.sorted()) }
        return Dictionary(uniqueKeysWithValues: [anna, bob].filter { rooms.contains($0.id) }.map { ($0.id, $0) })
    }
    func chatChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

/// Search over `account`, its index holding a link Anna sent and one Bob sent.
@MainActor
private func messageSearch(over account: SearchAccount) async throws -> MessageSearch {
    let store = try await TemporaryFolder.store()
    for (chat, url) in [(anna, "https://anna.example/plan"), (bob, "https://bob.example/trip")] {
        try await store.add([IndexedMessage(eventId: "$\(chat.name)", roomId: chat.id, senderName: chat.name, body: "\(chat.name)'s link \(url)",
                                            links: [url], date: chat.date ?? .now, isOwn: false)])
        try await store.setChat(chat.id, IndexedChat(newest: chat.date ?? .now, complete: true))
    }
    return MessageSearch(store: store, account: Task { account }, photos: try TemporaryFolder.ofTest.appending(path: "photos"),
                         preferences: try Preferences.ofTest)
}

@MainActor
@Suite(.ownPreferences, .ownFolder, .timeLimit(.minutes(1)))
struct SearchModelTypeAheadTests {
    @Test func theNewestWordsAnswerShowsAndAnOlderOneComingLateIsDropped() async throws {
        let account = SearchAccount()
        let search = try await messageSearch(over: account)
        let model = SearchModel(search: { search }, searchChanges: Broadcast())
        let changes = Changes()
        var shown: [SearchHits] = []
        model.onUpdate = { shown.append($0); changes.send() }

        model.search("anna")
        #expect(try await account.found.asks.first() == "anna")
        model.search("bob")
        #expect(try await account.found.asks.first() == "bob")
        await account.found.answer("bob", with: [bob])
        try await changes.until { model.hits.chats == [bob] }
        // Anna's answer comes after Bob's.
        await account.found.answer("anna", with: [anna])
        // more words, searched after the pause: by their answer, Anna's had long come.
        model.search("carl")
        #expect(try await account.found.asks.first() == "carl")
        await account.found.answer("carl", with: [carl])
        try await changes.until { model.hits.chats == [carl] }
        #expect(!shown.contains { $0.chats == [anna] })
        await search.stop()
    }

    @Test func clearedWordsShowWhatChatsSharedLately() async throws {
        let account = SearchAccount()
        let search = try await messageSearch(over: account)
        let model = SearchModel(search: { search }, searchChanges: Broadcast())
        let changes = Changes()
        model.onUpdate = { _ in changes.send() }

        model.search("anna")
        #expect(try await account.found.asks.first() == "anna")
        await account.found.answer("anna", with: [anna])
        try await changes.until { model.hits.chats == [anna] }
        model.search("")
        try await changes.until { model.hits.chats.isEmpty && model.hits.links.count == 2 }
        #expect(model.hits.links.map(\.roomId) == ["!anna", "!bob"])
        await search.stop()
    }
}

@MainActor
@Suite(.ownPreferences, .ownFolder, .timeLimit(.minutes(1)))
struct SearchListModelTypeAheadTests {
    @Test func theNewestWordsPageShowsAnOlderOneComingLateIsDroppedAndClearedWordsShowAll() async throws {
        var account = SearchAccount()
        let shownRooms = Held<[String], Void>()
        account.shown = shownRooms
        let search = try await messageSearch(over: account)
        let list = SearchListModel(search: { search }, kind: .links, query: "")
        let changes = Changes()
        var shown: [SearchHits] = []
        list.onUpdate = { shown.append($0); changes.send() }

        // all the links, at once.
        #expect(try await shownRooms.asks.first() == ["!anna", "!bob"])
        await shownRooms.answer(["!anna", "!bob"])
        try await changes.until { list.hasLoaded && list.hits.links.count == 2 }

        list.search("anna")
        #expect(try await shownRooms.asks.first() == ["!anna"])
        list.search("bob")
        #expect(try await shownRooms.asks.first() == ["!bob"])
        await shownRooms.answer(["!bob"])
        try await changes.until { list.hits.links.map(\.roomId) == ["!bob"] }
        // Anna's page comes after Bob's.
        await shownRooms.answer(["!anna"])
        list.search("")
        #expect(try await shownRooms.asks.first() == ["!anna", "!bob"])
        await shownRooms.answer(["!anna", "!bob"])
        try await changes.until { list.query.isEmpty && list.hits.links.count == 2 }
        #expect(!shown.contains { $0.links.map(\.roomId) == ["!anna"] })
        await search.stop()
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NewConversationTypeAheadTests {
    /// Chats with one person each (Anna's archived), a group, and the directory's people, who come
    /// when the test answers.
    private struct Directory: ConversationsPort {
        let people = Held<String, ContactListing>()

        func findChats(_ query: String, limit: Int) async -> [ChatRow] {
            var archived = ChatRow(id: "!old", name: "Anna Old", preview: "", date: nil)
            archived.folder = .archive
            let group = ChatRow(id: "!group", name: "Anna's team", preview: "", date: nil, isGroup: true)
            return [anna, bob, carl, archived, group].filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        }
        func contacts(query: String) async throws -> ContactListing { await people.answer(for: query) }
        func startConversation(with contact: Contact) async throws -> String { "!\(contact.id)" }
    }

    private static func listing(_ names: String...) -> ContactListing {
        ContactListing(contacts: names.map { Contact(id: $0, accountId: "matrix", name: $0, identifier: "@\($0):example.org",
                                                     network: "matrix", avatar: nil) },
                       problem: nil)
    }

    @Test func theNewestWordsPeopleShowAndAnOlderAnswerComingLateIsDropped() async throws {
        let directory = Directory()
        let model = NewConversationModel(account: Task { directory })
        let changes = Changes()
        var shown: [[Contact]] = []
        model.onUpdate = { shown.append(model.contacts); changes.send() }

        model.search("an")
        #expect(try await directory.people.asks.first() == "an")
        model.search("ann")
        #expect(try await directory.people.asks.first() == "ann")
        await directory.people.answer("ann", with: Self.listing("Anna Directory"))
        try await changes.until { !model.isSearching && model.contacts.map(\.name) == ["Anna Directory"] }
        // the answer for "an" comes after the one for "ann".
        await directory.people.answer("an", with: Self.listing("Dan"))
        model.search("bo")
        #expect(try await directory.people.asks.first() == "bo")
        await directory.people.answer("bo", with: Self.listing("Bob Directory"))
        try await changes.until { !model.isSearching && model.contacts.map(\.name) == ["Bob Directory"] }
        #expect(!shown.contains { $0.map(\.name) == ["Dan"] })
    }

    @Test func clearedWordsShowTheChatsWithOnePersonAgain() async throws {
        let directory = Directory()
        let model = NewConversationModel(account: Task { directory })
        let changes = Changes()
        model.onUpdate = { changes.send() }

        model.search("anna")
        try await changes.until { model.chats.map(\.id) == ["!anna"] }
        #expect(try await directory.people.asks.first() == "anna")
        await directory.people.answer("anna", with: Self.listing("Anna", "Anna Directory"))
        // someone you have a chat with shows there, not twice.
        try await changes.until { !model.isSearching && model.contacts.map(\.name) == ["Anna Directory"] }

        model.search("")
        // not the archived one, nor the group.
        try await changes.until { model.chats.map(\.id) == ["!anna", "!bob", "!carl"] }
        #expect(try await directory.people.asks.first() == "")
        await directory.people.answer("", with: Self.listing())
        try await changes.until { !model.isSearching && model.contacts.isEmpty }
    }
}

@MainActor
@Suite(.ownFolder, .timeLimit(.minutes(1)))
struct SharedModelTypeAheadTests {
    /// A chat whose shared links, for each search, come when the test answers.
    private struct Chat: ChatDetailsPort {
        let histories = Held<String, [SharedItem]>()

        private struct History: SharedHistory {
            let items: [SharedItem]
            func next(_ count: Int) async throws -> [SharedItem] { items }
            func isAtStart() async -> Bool { true }
        }

        func sharedHistory(chatId: String, kind: SharedKind, query: String?) async throws -> any SharedHistory {
            History(items: await histories.answer(for: query ?? ""))
        }

        func chatInfo(chatId: String) async throws -> ChatInfo { throw AccountFailure.notAllowed }
        func members(roomId: String) async throws -> any MemberList { throw AccountFailure.notAllowed }
        func sharedFile(_ item: SharedItem, directory: URL) async throws -> URL { throw AccountFailure.notAllowed }
        func threads(roomId: String, from: String?) async throws -> (threads: [ListedThread], next: String?) { throw AccountFailure.notAllowed }
        func setNotifications(chatId: String, _ setting: NotificationSetting) async throws { throw AccountFailure.notAllowed }
        func change(chatId: String, _ change: ChatChange) async throws { throw AccountFailure.notAllowed }
        func renameRoom(roomId: String, to name: String) async throws { throw AccountFailure.notAllowed }
        func setTopic(roomId: String, _ topic: String) async throws { throw AccountFailure.notAllowed }
        func setRoomPicture(roomId: String, jpeg: Data) async throws { throw AccountFailure.notAllowed }
        func removeRoomPicture(roomId: String) async throws { throw AccountFailure.notAllowed }
        func leave(chatId: String) async throws { throw AccountFailure.notAllowed }
    }

    private static func link(_ name: String, _ seconds: Double) throws -> SharedItem {
        SharedItem(id: "$\(name)", eventId: "$\(name)", roomId: "!a", senderName: "Anna", date: Date(timeIntervalSince1970: seconds),
                   content: .link(try #require(URL(string: "https://example.org/\(name)")), text: "the \(name)"))
    }

    @Test func theNewestWordsLinksShowAnOlderAnswerComingLateIsDroppedAndClearedWordsShowAll() async throws {
        let chat = Chat()
        let model = SharedModel(account: Task { chat }, chatId: "!a", kind: .links, originals: try TemporaryFolder.ofTest)
        let (plan, trip) = (try Self.link("plan", 2), try Self.link("trip", 1))

        let older = Task { await model.search("plan") }
        #expect(try await chat.histories.asks.first() == "plan")
        let newer = Task { await model.search("trip") }
        #expect(try await chat.histories.asks.first() == "trip")
        await chat.histories.answer("trip", with: [trip])
        await newer.value
        #expect(model.items == [trip])
        // the answer for "plan" comes after the one for "trip".
        await chat.histories.answer("plan", with: [plan])
        await older.value
        #expect(model.items == [trip])

        let cleared = Task { await model.search("") }
        #expect(try await chat.histories.asks.first() == "")
        await chat.histories.answer("", with: [plan, trip])
        await cleared.value
        #expect(model.query.isEmpty && model.items == [plan, trip] && model.isComplete)
    }
}
