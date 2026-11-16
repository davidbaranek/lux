import BackgroundAssets
import Foundation
import System

/// Photo search's model on the device: an Apple-hosted asset pack (Background Assets), asked for
/// only when the user turns photo search on, and removed when they turn it off. The system keeps
/// it up to date with the app.
enum PhotoSearchAssets {
    /// The pack's id, as its manifest names it (`scripts/image-search/Manifest.json`).
    static let packID = "PhotoSearch"
    /// The model's folder in the pack.
    private static let folder = "PhotoSearch"

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
    /// device; `progress` hears how far the download is (0…1). Each file's place is asked of the
    /// pack by its own path: a pack keeps its files where it chooses, so a folder found for one
    /// (`model.json`) need not hold the others (the encoders' `.mlmodelc` folders).
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
        return { name in try AssetPackManager.shared.url(for: FilePath("\(folder)/\(name)")) }
    }

    /// Frees the pack's space: photo search was turned off.
    static func remove() async {
        guard LaunchOptions.photoModel == nil else { return }
        do { try await AssetPackManager.shared.remove(assetPackWithID: packID) } catch {
            Log.app.notice("photo search: the model stays: \(String(describing: error), privacy: .public)")
        }
    }
}
