import Foundation
import Testing
@testable import LuxCore

/// A chat's details over the Rust core's demo account: a group's state and what its admin may
/// change, its members found as the user types, what it shared, and a merged chat's rooms.
@MainActor
@Suite(.closesDemoSessions, .timeLimit(.minutes(1)))
struct ChatDetailsTests {
    private let session = DemoSessions.open(rooms: 30, messagesPerRoom: 120)

    private func row(_ id: String, name: String = "", isGroup: Bool = false) -> ChatRow {
        ChatRow(id: id, name: name, preview: "", date: nil, isGroup: isGroup)
    }

    @Test func aGroupsAdminRenamesItAndSetsItsNotifications() async throws {
        let details = session.details(of: row("!room2:demo", isGroup: true))
        try await details.load()
        #expect(details.row.name == "Family")
        #expect(details.topic != nil)
        #expect(details.canRename && details.canChangePicture)
        #expect(details.info?.notifications == .default)

        try await details.rename(to: "  The Nováks ")
        #expect(details.row.name == "The Nováks")
        try await details.setNotifications(.mentions)
        #expect(details.info?.notifications == .mentions)
        #expect(details.row.isMuted && details.row.notifications == .mentions)
    }

    @Test func aChatGoesToLowPriorityAndBack() async throws {
        let details = session.details(of: row("!room1:demo"))
        try await details.load()
        #expect(!details.isLowPriority)
        // opened with no list: no place's rule to tell of.
        #expect(details.keptOutNote == nil)
        try await details.setLowPriority(true)
        #expect(details.isLowPriority && details.row.folder == .lowPriority)
        try await details.setLowPriority(false)
        #expect(details.row.folder == .inbox)
    }

    @Test func aGroupOthersRunCannotBeRenamed() async throws {
        let details = session.details(of: row("!room6:demo", isGroup: true))
        try await details.load()
        #expect(!details.canRename)
        #expect(details.info?.rooms.first?.joinedMembers == 240)
    }

    @Test func aBigGroupsMembersAreFoundByName() async throws {
        let details = session.details(of: row("!room6:demo", isGroup: true))
        try await details.load()
        let room = try #require(details.mainRoom)
        let members = details.members(of: room)
        await members.load()
        #expect(members.count == 240)
        #expect(members.found.first?.isOwn == true)
        let someone = try #require(members.found.dropFirst().first)
        members.search(String(someone.name.split(separator: " ").first ?? ""))
        #expect(members.found.contains(someone))
        #expect(members.found.count < 240)
        members.search("nobody by this name")
        #expect(members.found.isEmpty)
    }

    @Test func whatAChatSharedComesNewestFirstPageByPage() async throws {
        let details = session.details(of: row("!room1:demo"))
        let media = details.shared(.media)
        await media.loadMore()
        #expect(!media.items.isEmpty)
        #expect(media.items.allSatisfy { $0.picture != nil })
        #expect(zip(media.items, media.items.dropFirst()).allSatisfy { $0.date >= $1.date })
        let links = details.shared(.links)
        await links.loadMore()
        #expect(links.items.allSatisfy { if case .link = $0.content { true } else { false } })
        #expect(!links.items.isEmpty)
    }

    @Test func aSearchKeepsWhatHoldsItsWordsAndClearingItShowsAllAgain() async throws {
        let details = session.details(of: row("!room1:demo"))
        let files = details.shared(.files)
        await files.loadMore()
        let all = files.items.count
        #expect(all > 1)
        guard case .file(let name, _, _) = files.items.last?.content else { throw CancellationError() }
        // its name's words, in any case and without its accents.
        await files.search(name.uppercased().replacingOccurrences(of: ".PDF", with: ""))
        #expect(!files.items.isEmpty && files.items.count < all)
        #expect(files.items.allSatisfy { if case .file(let found, _, _) = $0.content { found == name } else { false } })
        await files.search("nothing shared by this name")
        #expect(files.isComplete && files.items.isEmpty)
        await files.search("")
        #expect(files.items.count == all)

        let links = details.shared(.links)
        await links.search("page2")
        #expect(!links.items.isEmpty)
        #expect(links.items.allSatisfy { if case .link(let url, let text) = $0.content { (url.absoluteString + text).contains("page2") } else { false } })
    }

    @Test func aChatKeepsItsOwnMessageStyleOverTheAppsAndNamesTheAppsInItsChoices() {
        let details = session.details(of: row("!room3:demo", isGroup: true))
        defer { details.chatStyleOverride = nil }
        details.chatStyleOverride = .plain
        #expect(Preferences.shared.chatStyle(in: "!room3:demo") == .plain)
        #expect(details.chatStyleChoices.last?.title.contains(Preferences.shared.chatStyle.title) == true)
        details.chatStyleOverride = nil
        #expect(Preferences.shared.chatStyle(in: "!room3:demo") == Preferences.shared.chatStyle)
    }

    @Test func aMergedChatShowsEachOfItsRooms() async throws {
        let details = session.details(of: row("merge:demo-jana", name: "Jana Dvořáková"))
        try await details.load()
        #expect(details.info?.rooms.count == 2)
        #expect(Set(details.info?.rooms.map(\.network) ?? []).count == 2)
        #expect(!details.canRename)
    }
}
