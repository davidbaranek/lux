import Foundation

/// Someone to start a conversation with: a Matrix user (the server's directory: people, bridge
/// bots) or a contact of a bridged network (a WhatsApp number, an Instagram account).
public struct Contact: Hashable, Sendable, Identifiable {
    public var id: String
    /// The account that reaches them: "matrix", or a bridge's login.
    public var accountId: String
    public var name: String
    /// Their address on that account: a Matrix id, a phone number, a username.
    public var identifier: String
    public var network: String
    public var avatar: ImageRef?

    public init(id: String, accountId: String, name: String, identifier: String, network: String, avatar: ImageRef?) {
        self.id = id; self.accountId = accountId; self.name = name; self.identifier = identifier
        self.network = network; self.avatar = avatar
    }
}

/// What a contact search found, and what could not be searched.
public struct ContactListing: Sendable, Equatable {
    public var contacts: [Contact]
    /// A part that could not be searched (a bridge that does not answer); nil when all could.
    public var problem: String?
    public init(contacts: [Contact], problem: String?) { self.contacts = contacts; self.problem = problem }
}
