import Foundation

/// Where Lux keeps its files, every folder named once: no other place asks the system for one.
///
/// What an extension opens (the Matrix stores and the account's kept store) is in the App Group on
/// the iPhone; what only the app uses (the search index, media, scratch) is in its own container,
/// out of the group, where a file held as iOS suspends the app ends it (0xdead10cc).
public struct AppPaths: Sendable {
    /// The accounts' folders that the extensions share; nil where there is no group (the Mac, an
    /// unsigned build).
    public let shared: URL?
    /// The accounts' folders in the app's own container (its search index).
    let own: URL
    /// The media cache: thumbnails, originals opened from chats, attachments being sent.
    let media: URL
    /// What lives for a moment (photos being read).
    let scratch: URL

    /// The accounts' folders the app opens: the group's, else its own.
    var accounts: URL { shared ?? own }

    /// This build's.
    public static var main: AppPaths {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #if os(iOS)
        let shared = fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppIdentity.appGroup)?
            .appending(path: "Library/Application Support/matrix", directoryHint: .isDirectory)
        #else
        let shared: URL? = nil
        #endif
        return AppPaths(shared: shared,
                        own: support.appending(path: "matrix", directoryHint: .isDirectory),
                        media: caches.appending(path: "lux-media", directoryHint: .isDirectory),
                        scratch: fileManager.temporaryDirectory)
    }

    /// All in a new temporary folder of its own (the demo, tests): no two share a file.
    static func temporary() -> AppPaths {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "lux-\(UUID().uuidString)", directoryHint: .isDirectory)
        return AppPaths(shared: nil, own: root.appending(path: "matrix", directoryHint: .isDirectory),
                        media: root.appending(path: "media", directoryHint: .isDirectory),
                        scratch: root.appending(path: "tmp", directoryHint: .isDirectory))
    }

    /// The files of the account kept as `store`.
    func account(_ store: String) -> AccountPaths {
        AccountPaths(folder: accounts.appending(path: store, directoryHint: .isDirectory),
                     ownFolder: own.appending(path: store, directoryHint: .isDirectory))
    }

    /// Originals opened from chats (photos, videos, files), kept in the cache with the thumbnails.
    var originals: URL { media.appending(path: "originals", directoryHint: .isDirectory) }
    /// Attachments being sent, prepared from what the user picked.
    var outgoing: URL { media.appending(path: "outgoing", directoryHint: .isDirectory) }
    /// Photos downloaded to be read for photo search.
    var photoReading: URL { scratch.appending(path: "photo-search", directoryHint: .isDirectory) }
}

/// One account's files.
struct AccountPaths: Sendable {
    /// Its Matrix stores (the SDK's), and its kept store: shared with the extensions.
    let folder: URL
    /// What only the app uses: its search index.
    let ownFolder: URL

    /// The account's encrypted store: the last chat list, which the share extension reads too.
    var keptStore: URL { folder.appending(path: "lux-search/index.sqlite") }
    /// The account's search index: the app writes it all the time and no extension reads it.
    var index: URL { ownFolder.appending(path: "lux-index/search.sqlite") }

    /// Removes all of the account's files.
    func remove() throws {
        let fileManager = FileManager.default
        for url in [folder, ownFolder] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
