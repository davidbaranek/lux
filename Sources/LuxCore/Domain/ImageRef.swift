import Foundation

/// An image the UI shows. Equal refs show the same picture, so a ref is also its cache key.
public enum ImageRef: Hashable, Sendable {
    /// A chat's picture (a DM falls back to the contact's); `version` changes with the picture.
    case room(id: String, version: String)
    /// A person's picture, by its media url.
    case person(url: String)
    /// A photo message's thumbnail.
    case photo(roomId: String, messageId: String, name: String)
    /// A video message's poster (its sender's still of it).
    case poster(roomId: String, messageId: String, name: String)
    /// A shared photo's thumbnail or video's poster, by its message's event, which the chat's
    /// timeline may not hold.
    case shared(roomId: String, eventId: String, name: String)

    var key: String {
        switch self {
        case .room(let id, let version): "r|\(id)|\(version)"
        case .person(let url): "p|\(url)"
        case .photo(let room, _, let name): "m|\(room)|\(name)"
        case .poster(let room, _, let name): "v|\(room)|\(name)"
        case .shared(let room, _, let name): "s|\(room)|\(name)"
        }
    }
}
