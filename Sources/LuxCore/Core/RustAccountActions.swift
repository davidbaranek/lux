import Foundation
import LuxBindings

/// The Rust core's account beyond its lists (the chat list's view model has its own actions, in
/// `RustChatList.swift`, the thread's in `RustThread.swift`, security in `RustSecurity.swift`): people and
/// the profile, in the app's types.
/// The generated types stay in `Core/`.
extension RustAccount {
    // MARK: People

    func contacts(query: String) async throws -> ContactListing {
        let found = try await worded { try await account.contacts(query: query) }
        let problems = found.problems.map(\.words)
        return ContactListing(contacts: found.contacts.map(Contact.init),
                              problem: problems.isEmpty ? nil : problems.joined(separator: " "))
    }

    func startConversation(with contact: Contact) async throws -> String {
        try await worded { try await account.startConversation(contact: CoreContact(contact)) }
    }

    func createRoom(name: String) async throws -> String { try await worded { try await account.createRoom(name: name) } }

    // MARK: Profile

    func profile() async throws -> Profile {
        let own = try await worded { try await account.profile() }
        return Profile(userId: own.userId, name: own.name, displayName: own.displayName, avatar: own.avatar.map { .person(url: $0) },
                       canChangeName: own.canChangeName, canChangeAvatar: own.canChangeAvatar)
    }

    func setProfileName(_ name: String) async throws { try await worded { try await account.setProfileName(name: name) } }

    /// Uploads a JPEG as the account's picture.
    func setProfilePicture(jpeg: Data) async throws {
        _ = try await worded { try await account.setProfilePicture(data: jpeg, format: .jpeg) }
    }

    func removeProfilePicture() async throws { try await worded { try await account.removeProfilePicture() } }
}

private extension Contact {
    init(_ contact: CoreContact) {
        self.init(id: contact.id, accountId: contact.accountId, name: contact.name, identifier: contact.identifier,
                  network: contact.network, avatar: contact.avatar.map { .person(url: $0) })
    }
}

private extension CoreContact {
    init(_ contact: Contact) {
        let avatar: String? = if case .person(let url) = contact.avatar { url } else { nil }
        self.init(id: contact.id, accountId: contact.accountId, name: contact.name, identifier: contact.identifier,
                  network: contact.network, avatar: avatar)
    }
}

private extension CoreContactProblem {
    var words: String {
        switch self {
        case .matrixSearch: String(localized: "Could not search Matrix. Other available contacts are shown. Try again.")
        case .discovery: String(localized: "Could not discover connected accounts. Matrix is still available. Try again.")
        case .someAccounts: String(localized: "Some connected accounts are unavailable. Available accounts are shown. Try again.")
        case .account(let name): String(localized: "Could not load \(name). Other available contacts are shown. Try again.")
        }
    }
}
