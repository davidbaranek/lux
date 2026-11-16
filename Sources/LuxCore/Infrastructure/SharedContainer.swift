import Foundation

/// Where the accounts' stores live. On the iPhone, in the App Group the notification extension
/// shares, so it can open the same store; on the Mac (and in a build without the group), in the
/// app's own Application Support.
public enum SharedContainer {
    /// The App Group of the app and its notification extension.
    public static var appGroup: String { AppIdentity.appGroup }

    /// The group's folder of stores; nil where there is no group (the Mac, an unsigned build).
    public static var groupRoot: URL? {
        #if os(iOS)
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Library/Application Support/matrix", isDirectory: true)
        #else
        nil
        #endif
    }

    /// The app's folder of stores: the group's, else its own.
    static var appRoot: URL { groupRoot ?? ownRoot }

    /// The app's own folder of stores, in its Application Support: what no extension reads (the
    /// search index), kept out of the group, where a file locked as the app is suspended ends it.
    static var ownRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("matrix", isDirectory: true)
    }
}
