import Foundation
import LuxBindings

/// A chat the user keeps from every AI in Lux: agents, Siri and Shortcuts, a model's tools.
public struct HiddenChat: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

extension Session {
    /// The chats kept from every AI in Lux. They are kept in the account, so every device has
    /// them; none while signed out.
    public func hiddenFromAI() async -> [HiddenChat] {
        guard let account = await bestEffort("hidden from AI", { try await account.value }) else { return [] }
        return await account.account.hiddenFromAi().map { HiddenChat(id: $0.chatId, name: $0.name) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Keeps `chat` from every AI in Lux, or shows it to AI again, on every device.
    public func setHiddenFromAI(_ chat: HiddenChat, hidden: Bool) async throws {
        try await account.value.account.setHiddenFromAi(chatId: chat.id, name: chat.name, hidden: hidden)
    }
}
