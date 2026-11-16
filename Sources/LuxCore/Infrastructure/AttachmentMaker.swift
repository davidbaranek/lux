import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes a picked file ready to send, off the main thread, with ImageIO (no image is ever decoded
/// whole): a photo goes as an upright JPEG of at most `maxPhotoSide` pixels, as Signal and
/// WhatsApp send them, with a small thumbnail for other apps; a GIF or a PNG goes as it is (its
/// animation, its transparency); a video goes as it is, with its poster; anything else goes as a file.
public enum AttachmentMaker {
    public static let maxPhotoSide = 4096
    static let thumbnailSide = 800

    public enum Failure: LocalizedError {
        case unreadable(String)
        case tooLarge(name: String, limit: Int)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let name): String(localized: "\(name) could not be read.")
            case .tooLarge(let name, let limit):
                String(localized: "\(name) is larger than the server takes (\(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))).")
            }
        }
    }

    /// Copies `source` into a folder of its own in `directory` (the picker's file goes away) and
    /// describes it; `name` is the one to show, the file's own by default.
    @concurrent
    public static func prepare(_ source: URL, name: String? = nil, in directory: URL) async throws -> OutgoingAttachment {
        let name = name ?? source.lastPathComponent
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let type = UTType(filenameExtension: source.pathExtension) ?? .data
        // a photo or video that cannot be made smaller goes as it is, a file.
        if type.conforms(to: .image), let photo = bestEffort("attachment: the photo", { try photo(source, name: name, type: type, in: folder) }) {
            return photo
        }
        if type.conforms(to: .movie),
           let video = await bestEffort("attachment: the video", { try await video(source, name: name, type: type, in: folder) }) {
            return video
        }
        let file = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: file)
        return OutgoingAttachment(file: file, name: name, mimetype: type.preferredMIMEType ?? "application/octet-stream",
                                  size: try size(of: file), kind: .file)
    }

    private static func photo(_ source: URL, name: String, type: UTType, in folder: URL) throws -> OutgoingAttachment {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw Failure.unreadable(name) }
        // orientations 5 to 8 turn the picture a quarter: its upright width is its stored height.
        let turned = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        let upright = turned ? (width: height, height: width) : (width: width, height: height)
        let thumbnail = try scaled(image, side: thumbnailSide, to: folder.appendingPathComponent("thumbnail.jpg"))

        // as it is: an animation or transparency would be lost, and these are rarely large.
        if type.conforms(to: .gif) || type.conforms(to: .png) {
            let file = folder.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: file)
            return OutgoingAttachment(file: file, name: name, mimetype: type.preferredMIMEType ?? "image/png", size: try size(of: file),
                                      kind: .photo(width: upright.width, height: upright.height), thumbnail: thumbnail)
        }
        let jpegName = (name as NSString).deletingPathExtension + ".jpg"
        let file = folder.appendingPathComponent(jpegName)
        let sent = try scaled(image, side: min(maxPhotoSide, max(upright.width, upright.height)), to: file)
        return OutgoingAttachment(file: file, name: jpegName, mimetype: "image/jpeg", size: sent.size,
                                  kind: .photo(width: sent.width, height: sent.height), thumbnail: thumbnail)
    }

    /// A video as it is (no re-encoding: that is slow and loses quality), with its upright size,
    /// its length, and a poster from its first second for other apps to show until it plays.
    private static func video(_ source: URL, name: String, type: UTType, in folder: URL) async throws -> OutgoingAttachment {
        let asset = AVURLAsset(url: source)
        let (duration, tracks) = try await asset.load(.duration, .tracks)
        guard duration.isNumeric, duration.timescale > 0 else { throw Failure.unreadable(name) }
        guard let track = tracks.first(where: { $0.mediaType == .video }) else { throw Failure.unreadable(name) }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let upright = natural.applying(transform)
        let (width, height) = (Int(abs(upright.width)), Int(abs(upright.height)))
        let file = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: file)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailSide, height: thumbnailSide)
        let still = try await generator.image(at: CMTime(seconds: min(1, duration.seconds / 2), preferredTimescale: 600)).image
        let posterFile = folder.appendingPathComponent("poster.jpg")
        guard let destination = CGImageDestinationCreateWithURL(posterFile as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.unreadable(name)
        }
        CGImageDestinationAddImage(destination, still, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable(name) }
        let poster = OutgoingAttachment.Thumbnail(file: posterFile, mimetype: "image/jpeg", size: try size(of: posterFile),
                                                  width: still.width, height: still.height)
        return OutgoingAttachment(file: file, name: name, mimetype: type.preferredMIMEType ?? "video/mp4", size: try size(of: file),
                                  kind: .video(width: width, height: height, duration: .seconds(duration.value) / Int64(duration.timescale)),
                                  thumbnail: poster)
    }

    /// An upright JPEG of `image` at most `side` pixels on its longer edge, decoded at that size.
    private static func scaled(_ image: CGImageSource, side: Int, to file: URL) throws -> OutgoingAttachment.Thumbnail {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let picture = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Failure.unreadable(file.lastPathComponent) }
        CGImageDestinationAddImage(destination, picture, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable(file.lastPathComponent) }
        return OutgoingAttachment.Thumbnail(file: file, mimetype: "image/jpeg", size: try size(of: file), width: picture.width, height: picture.height)
    }

    private static func size(of file: URL) throws -> Int {
        try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }
}
