import Foundation

/// A message in a chat, by its room and its event: where a search result, a saved message or a
/// quote leads. Its room tells a merged chat's rooms apart.
public struct MessageLink: Sendable, Hashable {
    public var roomId: String
    public var eventId: String

    public init(roomId: String, eventId: String) {
        self.roomId = roomId
        self.eventId = eventId
    }
}

/// Where a jump to a message landed.
public enum JumpResult: Sendable, Equatable {
    /// In the chat shown: the row to scroll to.
    case here(String)
    /// In a Matrix thread of the chat: it opens there, at the message.
    case inThread(MatrixThread, MessageLink)
}

/// Why a jump to a message did not land.
public enum JumpError: Error, LocalizedError, Sendable, Equatable {
    /// The server has no such message.
    case notFound
    /// The account may not see it.
    case notAllowed
    /// Anything else: the network, the server.
    case failed

    public var errorDescription: String? {
        switch self {
        case .notFound: String(localized: "This message is no longer there.")
        case .notAllowed: String(localized: "You can't see this message.")
        case .failed: String(localized: "The message could not be loaded.")
        }
    }
}
