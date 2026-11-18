import BackgroundAssets
import CryptoKit
import Foundation
import System

/// Photo search's model on the device: an Apple-hosted asset pack (Background Assets), asked for
/// only when the user turns photo search on, and removed when they turn it off. The system keeps
/// it up to date with the app.
///
/// Core ML loads the model from a copy the app keeps (`AppPaths.photoModels`), one per model the
/// pack has held, never from the pack: the pack's folder is one the system puts together from the
/// packs each time it is asked for (`url(for:)`), at a place not to be kept past the process,
/// and Core ML keeps what it compiled for this device only while the model it compiled stays
/// where it was, unchanged. From the app's copy the model is compiled once per model, not on
/// every launch.
enum PhotoSearchAssets {
    /// The pack's id, as its manifest names it (`scripts/image-search/Manifest.json`).
    static let packID = "PhotoSearch"
    /// The model's folder in the pack.
    private static let folder = "PhotoSearch"
    /// The model's copies, each in a folder named after its `model.json`'s digest.
    private static var copies: URL { AppPaths.main.photoModels }

    /// The pack is on the device.
    static func isOnDevice() async -> Bool {
        if LaunchOptions.photoModel != nil { return true }
        if #available(iOS 26.4, macOS 26.4, *) {
            return AssetPackManager.shared.assetPackIsAvailableLocally(withID: packID)
        }
        let status = await bestEffort("photo search: the model's status") { try await AssetPackManager.shared.status(ofAssetPackWithID: packID) }
        return status?.contains(.downloaded) ?? false
    }

    /// Where each of the model's files is, downloading the pack first when it is not on the
    /// device; `progress` hears how far the download is (0…1).
    static func modelFiles(progress: @escaping @Sendable (Double) -> Void) async throws -> PhotoSearchModel.Files {
        if let folder = LaunchOptions.photoModel { return { folder.appending(path: $0) } }
        let manager = AssetPackManager.shared
        let pack = try await manager.assetPack(withID: packID)
        let following = Task {
            for await update in manager.statusUpdates(forAssetPackWithID: packID) {
                if case .downloading(_, let download) = update { progress(download.fractionCompleted) }
            }
        }
        defer { following.cancel() }
        // at once when the pack is on the device already.
        try await manager.ensureLocalAvailability(of: pack)
        // the model on the device, as its own `model.json` says (package.sh stamps the digest of
        // the pack's other files in it): read as a file, not through the merged folder.
        let description = try manager.contents(at: FilePath("\(folder)/model.json"), searchingInAssetPackWithID: packID)
        // copying holds its thread (for seconds where the volume cannot clone the files).
        let copy = try await withTaskExecutorPreference(ImageWork.executor) {
            // the pack's folder, asked for once: the system puts it together as it answers.
            try copied(of: description, in: copies) { try manager.url(for: FilePath(folder)) }
        }
        return { copy.appending(path: $0) }
    }

    /// The copy in `root` of the model whose `model.json` is `description`, made from `source`
    /// now when there is none; other models' copies go. It is named after `description`'s
    /// digest, so a model whose files changed is copied again, whatever version the system gives
    /// its pack. A copy is made beside the others and moved into place whole, so one that is
    /// there is complete, and it never changes while it is there.
    static func copied(of description: Data, in root: URL, from source: () throws -> URL) throws -> URL {
        let fileManager = FileManager.default
        var root = root
        let name = SHA256.hash(data: description).prefix(16).map { String(format: "%02x", $0) }.joined()
        let copy = root.appending(path: name, directoryHint: .isDirectory)
        if !fileManager.fileExists(atPath: copy.path) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            // the pack downloads again: its copy is no backup's to keep.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            let source = try source()
            let partial = root.appending(path: "\(UUID().uuidString).partial", directoryHint: .isDirectory)
            // on one volume, APFS clones the files: they take no second space.
            try fileManager.copyItem(at: source, to: partial)
            do {
                try fileManager.moveItem(at: partial, to: copy)
            } catch CocoaError.fileWriteFileExists {
                // another copy of this model came first: it stays as it is.
                try fileManager.removeItem(at: partial)
            }
        }
        for other in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where other.lastPathComponent != copy.lastPathComponent {
            try fileManager.removeItemIfPresent(at: other)
        }
        return copy
    }

    /// Frees the pack's space, and its copy's: photo search was turned off.
    static func remove() async {
        guard LaunchOptions.photoModel == nil else { return }
        bestEffort("photo search: the model's copy stays") { try FileManager.default.removeItemIfPresent(at: copies) }
        do { try await AssetPackManager.shared.remove(assetPackWithID: packID) } catch {
            Log.app.notice("photo search: the model stays: \(String(describing: error), privacy: .public)")
        }
    }
}
