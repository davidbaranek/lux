import Foundation
import Photos
import Synchronization

/// The newest photos and videos of the library, offered under the composer's + as Photos and
/// ChatGPT offer them: picked with a tap, they wait in the composer as ones from the system's
/// picker do. Reading the library needs its permission, asked only when the user opens them.
public enum RecentPhotos {
    /// As many as the system's picker takes at once.
    public static let selectionLimit = 10
    /// How many of the newest the grid offers; older ones are in All Photos.
    public static let count = 120

    /// What opening the recent photos shows for the library's permission.
    public enum Access: Equatable, Sendable {
        /// The newest of the library; `limited` to those the user shared, with the system's
        /// option to choose them again.
        case grid(limited: Bool)
        /// The system's picker, which needs no permission: the user refused it, or may not give it.
        case picker

        /// What a permission, asked already, opens.
        public init(_ status: PHAuthorizationStatus) {
            switch status {
            case .authorized: self = .grid(limited: false)
            case .limited: self = .grid(limited: true)
            default: self = .picker
            }
        }
    }

    /// The newest photos and videos first.
    public static func fetch() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue,
                                        PHAssetMediaType.video.rawValue)
        options.fetchLimit = count
        return PHAsset.fetchAssets(with: options)
    }

    /// Which of an asset's resources is the one to send: the picture or the video as the library
    /// shows it (with the user's edits, if any), never a Live Photo's motion or an adjustment's data.
    public static func original(among types: [PHAssetResourceType]) -> Int? {
        for wanted in [PHAssetResourceType.fullSizePhoto, .photo, .fullSizeVideo, .video] {
            if let index = types.firstIndex(of: wanted) { return index }
        }
        return nil
    }

    /// Where an asset's picture or video goes in `directory`, a folder of its own, named as the
    /// library names it: known at once, before it is written (`write`).
    public static func destination(of asset: PHAsset, in directory: URL) -> URL? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let index = original(among: resources.map(\.type)) else { return nil }
        return directory.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(resources[index].originalFilename)
    }

    /// Writes an asset's picture or video to `file`, from iCloud if it is only there, telling
    /// `progress` how far it has come (0 to 1). Cancelling stops it. It stays on the caller's
    /// actor (an asset is not `Sendable`); Photos hands the data over on a queue of its own.
    public nonisolated(nonsending) static func write(_ asset: PHAsset, to file: URL,
                                                     progress: @escaping @Sendable (Double) -> Void) async throws {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let index = original(among: resources.map(\.type)) else { throw CocoaError(.fileReadUnknown) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: file)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { share in progress(share) }
        let request = Mutex<PHAssetResourceDataRequestID?>(nil)
        let failure = Mutex<(any Error)?>(nil)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
                    let id = PHAssetResourceManager.default().requestData(for: resources[index], options: options) { data in
                        do { try handle.write(contentsOf: data) } catch { failure.withLock { $0 = $0 ?? error } }
                    } completionHandler: { error in
                        if let error = error ?? failure.withLock({ $0 }) { done.resume(throwing: error) } else { done.resume() }
                    }
                    request.withLock { $0 = id }
                }
            } onCancel: {
                if let id = request.withLock({ $0 }) { PHAssetResourceManager.default().cancelDataRequest(id) }
            }
            try handle.close()
        } catch {
            bestEffort("recent photo: close") { try handle.close() }
            throw error
        }
    }
}

/// The recent photos the user picked, in the order they were picked (the order they go in), up
/// to `RecentPhotos.selectionLimit`.
public struct RecentPhotoSelection: Equatable, Sendable {
    public private(set) var ids: [String] = []

    public init() {}

    public var isFull: Bool { ids.count >= RecentPhotos.selectionLimit }

    /// Picks the photo, or puts it back; a full selection takes no more. True if it changed.
    @discardableResult
    public mutating func toggle(_ id: String) -> Bool {
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
            return true
        }
        guard !isFull else { return false }
        ids.append(id)
        return true
    }

    /// The photos no longer in the library are no longer picked.
    public mutating func keep(only existing: Set<String>) {
        ids.removeAll { !existing.contains($0) }
    }
}
