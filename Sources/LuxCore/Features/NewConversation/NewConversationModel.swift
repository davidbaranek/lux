import Foundation

/// The new conversation sheet: the chats you have with one person (they open at once), then
/// people to write to from the server's directory and the bridges, as you type.
@MainActor
public final class NewConversationModel {
    public private(set) var query = ""
    /// Existing one-to-one chats whose name has the words.
    public private(set) var chats: [ChatRow] = []
    public private(set) var contacts: [Contact] = []
    public private(set) var problem: String?
    public private(set) var isSearching = false
    public var onUpdate: (() -> Void)?

    private let account: Task<any ConversationsPort, any Error>
    private var running: Task<Void, Never>?

    public convenience init(session: Session) {
        let account = session.account
        self.init(account: Task { try await account.value })
    }

    init(account: Task<any ConversationsPort, any Error>) {
        self.account = account
    }

    /// Lists what an empty search shows.
    public func start() async {
        search("")
    }

    /// Chats at once (the core finds them by name); contacts after a short pause, a newer search
    /// dropping an older answer.
    public func search(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        query = text
        running?.cancel()
        isSearching = true
        onUpdate?()
        running = Task { [account] in
            let byName = await bestEffort("new conversation: find chats") { try await account.value.findChats(text, limit: .max) } ?? []
            guard !Task.isCancelled else { return }
            chats = Array(byName.filter { !$0.isGroup && $0.folder != .archive }.prefix(text.isEmpty ? 8 : 20))
            onUpdate?()
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found: ContactListing
            do { found = try await account.value.contacts(query: text) } catch {
                found = ContactListing(contacts: [], problem: String(localized: "Could not search contacts."))
            }
            guard !Task.isCancelled, text == query else { return }
            // someone you already have a chat with shows there, not twice.
            let named = Set(chats.map { Self.fold($0.name) })
            contacts = found.contacts.filter { !named.contains(Self.fold($0.name)) }
            problem = found.problem
            isSearching = false
            onUpdate?()
        }
    }

    /// The chat with a contact (made if there is none): its room id.
    public func start(with contact: Contact) async throws -> String {
        try await account.value.startConversation(with: contact)
    }

    nonisolated private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
