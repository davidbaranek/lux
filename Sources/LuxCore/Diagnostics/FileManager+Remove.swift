import Foundation

public extension FileManager {
    /// Removes the item at `url`; one that is not there is already removed, not a failure.
    func removeItemIfPresent(at url: URL) throws {
        do {
            try removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}
