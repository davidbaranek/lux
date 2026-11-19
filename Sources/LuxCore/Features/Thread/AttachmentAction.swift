import Foundation

/// What a message's menu offers for its photos, videos, files or sounds, beside `MessageAction`:
/// keeping a copy outside the chat. The rules live here, so both apps offer the same; each platform
/// saves where its own system keeps files.
public enum AttachmentAction: Hashable, Sendable {
    /// The file (and a picture's image) on the pasteboard, to paste into another app.
    case copy
    /// Mac: into the user's Downloads folder, under a name not yet taken there.
    case saveToDownloads
    /// Mac: where the save panel says.
    case saveAs
    /// iPhone: where the Files export says.
    case saveToFiles
    /// iPhone: a photo or a video into the photo library.
    case saveToPhotos
    /// iPhone: the share sheet.
    case share

    public enum Platform: Sendable { case mac, phone }

    /// The actions for `message`'s media on `platform`, in menu order: none while it is not on the
    /// server yet (it is still the user's own file) or has none.
    public static func available(for message: MessageItem, on platform: Platform) -> [AttachmentAction] {
        guard message.hasMedia, !message.isDeleted, message.state == .sent, message.uploadProgress == nil else { return [] }
        switch platform {
        case .mac:
            // a save panel names one file; an album goes to Downloads.
            return [.copy, .saveToDownloads] + (message.mediaMessageIds.count == 1 ? [.saveAs] : [])
        case .phone:
            return [.copy, .saveToFiles] + (isPhotoOrVideo(message) ? [.saveToPhotos] : []) + [.share]
        }
    }

    /// A photo, a video or an album of them: the photo library takes it.
    static func isPhotoOrVideo(_ message: MessageItem) -> Bool {
        message.file == nil && (message.photo != nil || message.video != nil || !message.album.isEmpty)
    }

    /// The menu's words for `message`'s media: "Copy Photo", "Copy File".
    public func title(for message: MessageItem) -> String {
        switch self {
        case .copy:
            if message.mediaMessageIds.count > 1 { return String(localized: "Copy Photos") }
            if message.video != nil, message.file == nil { return String(localized: "Copy Video") }
            if message.photo != nil, message.file == nil { return String(localized: "Copy Photo") }
            return String(localized: "Copy File")
        case .saveToDownloads: return String(localized: "Save to Downloads")
        case .saveAs: return String(localized: "Save As…")
        case .saveToFiles: return String(localized: "Save to Files")
        case .saveToPhotos: return String(localized: "Save to Photos")
        case .share: return String(localized: "Share…")
        }
    }

    public var symbol: String {
        switch self {
        case .copy: "doc.on.doc"
        case .saveToDownloads: "arrow.down.circle"
        case .saveAs: "square.and.arrow.down"
        case .saveToFiles: "folder"
        case .saveToPhotos: "photo.badge.plus"
        case .share: "square.and.arrow.up"
        }
    }
}
