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
    /// A photo the search found, by its event: its thumbnail.
    case found(roomId: String, eventId: String)

    var key: String {
        switch self {
        case .room(let id, let version): "r|\(id)|\(version)"
        case .person(let url): "p|\(url)"
        case .photo(let room, _, let name): "m|\(room)|\(name)"
        case .poster(let room, _, let name): "v|\(room)|\(name)"
        case .found(let room, let event): "f|\(room)|\(event)"
        }
    }
}
