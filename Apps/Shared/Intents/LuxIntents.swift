import AppIntents
import Foundation
import LuxCore

/// What the app's intents reach: the account's session, and the app's own way to open a chat
/// (its navigation, as Handoff and a notification open one). Registered as the intents'
/// dependency as the app launches.
@MainActor
final class IntentHost {
    let session: Session
    private let open: (ChatActivity) -> Void

    init(session: Session, open: @escaping (ChatActivity) -> Void) {
        self.session = session
        self.open = open
    }

    /// Opens `chat` in the app, in front.
    func openChat(_ chat: ChatActivity) {
        open(chat)
    }

    /// The search over the encrypted index on this device, once the account is open.
    private func search() throws(IntentFailure) -> MessageSearch {
        guard let search = session.search else { throw IntentFailure.notOpen }
        return search
    }

    /// The chats whose name has every word of `text`.
    func chats(named text: String) async throws -> [ChatEntity] {
        let search = try search()
        return await search.chats(named: text, limit: 20).map { ChatEntity($0, room: $0.id) }
    }

    /// The chats of `rooms`, in their order; a room no chat shows is left out.
    func chats(ofRooms rooms: [String]) async throws -> [ChatEntity] {
        let search = try search()
        let chats = await search.chats(ofRooms: rooms)
        return rooms.compactMap { room in chats[room].map { ChatEntity($0, room: room) } }
    }

    /// At most `limit` messages with the words of `text` or near their meaning, the newest first.
    func messages(_ text: String, limit: Int) async throws -> [MessageEntity] {
        _ = try actions()
        let search = try search()
        return await search.search(text).messages.prefix(limit).map(MessageEntity.init)
    }

    /// `text` with the AI action `id`'s result applied: its corrections, or its new text.
    func apply(_ id: String, to text: String) async throws -> String {
        let actions = try actions()
        guard let action = actions.actions.first(where: { $0.id == id }) else { throw IntentFailure.aiOff }
        if let reason = actions.unavailability(of: text) { throw IntentFailure.failed(reason) }
        do {
            return try await actions.run(action, on: text, in: nil).applied(to: text) ?? text
        } catch {
            throw IntentFailure.failed(error.localizedDescription)
        }
    }

    /// The AI actions, when Settings › AI's switch is on: Siri and Shortcuts read nothing in Lux
    /// while it is off.
    func actions() throws(IntentFailure) -> TextActions {
        guard session.textActions.isOn else { throw IntentFailure.aiOff }
        return session.textActions
    }
}

/// Why an intent could not run, in the user's words.
struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    let localizedStringResource: LocalizedStringResource

    static let notOpen = Self(localizedStringResource: "Open Lux and sign in, then try again.")
    static let aiOff = Self(localizedStringResource: "Turn on AI Features in Lux's Settings to use this.")
    static func failed(_ reason: String) -> Self { Self(localizedStringResource: "\(reason)") }
}

// MARK: Chats

/// A chat, as Siri and Shortcuts pick one: by its name.
struct ChatEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Chat"
    static let defaultQuery = ChatQuery()

    /// One of the chat's rooms: a merged chat opens whole from any of them.
    let id: String
    let name: String
    let network: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(network)")
    }

    init(_ row: ChatRow, room: String) {
        id = room
        name = row.name
        network = Networks.name(row.network)
    }
}

struct ChatQuery: EntityStringQuery {
    @Dependency private var host: IntentHost

    func entities(for identifiers: [ChatEntity.ID]) async throws -> [ChatEntity] {
        try await host.chats(ofRooms: identifiers)
    }

    func entities(matching string: String) async throws -> [ChatEntity] {
        try await host.chats(named: string)
    }

    func suggestedEntities() async throws -> [ChatEntity] {
        []
    }
}

/// Opens a chat in Lux.
struct OpenChatIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Chat"
    static let description = IntentDescription("Opens a chat in Lux.")

    @Parameter(title: "Chat") var target: ChatEntity
    @Dependency private var host: IntentHost

    @MainActor
    func perform() async throws -> some IntentResult {
        host.openChat(ChatActivity(roomId: target.id))
        return .result()
    }
}

// MARK: Messages

/// A message found in the encrypted index on this device.
struct MessageEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Message"
    static let defaultQuery = MessageQuery()

    let id: String
    @Property(title: "Sender") var sender: String
    @Property(title: "Text") var text: String
    @Property(title: "Chat") var chat: String
    @Property(title: "Date") var date: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(sender): \(text)", subtitle: "\(chat)")
    }

    init(_ item: FoundItem) {
        id = item.id
        sender = item.senderName
        text = item.body
        chat = item.chat.name
        date = item.date
    }
}

/// Messages are found by searching, not looked up by their id.
struct MessageQuery: EntityQuery {
    func entities(for identifiers: [MessageEntity.ID]) async throws -> [MessageEntity] { [] }
}

/// Searches the messages on this device by their words and their meaning, as Lux's search does.
/// Behind Settings › AI's switch: Siri and Shortcuts read no message while it is off.
struct SearchMessagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Messages"
    static let description = IntentDescription("Finds messages in your chats on this device, by their words and by what they mean.")

    @Parameter(title: "Words") var query: String
    @Parameter(title: "Most", default: 20, inclusiveRange: (1, 60)) var limit: Int
    @Dependency private var host: IntentHost

    func perform() async throws -> some IntentResult & ReturnsValue<[MessageEntity]> {
        .result(value: try await host.messages(query, limit: limit))
    }
}

// MARK: Text

/// Corrects a text's spelling, grammar and punctuation with Apple Intelligence on this device.
struct ProofreadTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Proofread Text"
    static let description = IntentDescription("Corrects the spelling, grammar and punctuation of a text, with Apple Intelligence on this device.")

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true)) var text: String
    @Dependency private var host: IntentHost

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await host.apply("proofread", to: text))
    }
}

/// Lays a text out with lists, paragraphs and bold, with Apple Intelligence on this device.
struct FormatTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Format Text"
    static let description = IntentDescription("Lays a text out in Markdown with lists, paragraphs and bold, with Apple Intelligence on this device.")

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true)) var text: String
    @Dependency private var host: IntentHost

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await host.apply("format", to: text))
    }
}

// MARK: Shortcuts

/// The phrases that run Lux's intents from Siri and Spotlight, without setting up a shortcut.
struct LuxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenChatIntent(), phrases: ["Open a chat in \(.applicationName)", "Open \(\.$target) in \(.applicationName)"],
                    shortTitle: "Open Chat", systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(intent: SearchMessagesIntent(), phrases: ["Search messages in \(.applicationName)"],
                    shortTitle: "Search Messages", systemImageName: "magnifyingglass")
        AppShortcut(intent: ProofreadTextIntent(), phrases: ["Proofread with \(.applicationName)"],
                    shortTitle: "Proofread Text", systemImageName: "text.magnifyingglass")
        AppShortcut(intent: FormatTextIntent(), phrases: ["Format with \(.applicationName)"],
                    shortTitle: "Format Text", systemImageName: "list.bullet.indent")
    }
}
