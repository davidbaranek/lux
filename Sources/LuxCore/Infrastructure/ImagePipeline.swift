import CoreGraphics
import Foundation
import ImageIO

/// Downloads images once (into a cache folder, through the account) and decodes them off the main
/// thread at the size they show (WWDC18 "Image and Graphics Best Practices": a decoded bitmap costs
/// width x height x 4 bytes, whatever the file's size). Avatars come out already round, so no layer
/// has to clip them (no offscreen pass). One request per image at a time; decoded bitmaps stay in
/// memory until the system needs it back.
public final class ImagePipeline: Sendable {
    public enum Shape: Sendable {
        case original
        /// Cropped to a circle (aspect fill), with transparent corners.
        case circle
    }

    private let account: Task<RustAccount, any Error>
    private let directory: URL
    private let memory = MemoryCache()
    private let loads = Loads()

    init(account: Task<RustAccount, any Error>, directory: URL) {
        self.account = account
        self.directory = directory
    }

    /// The decoded image if it is in memory: a cell shows it at once, with no flash.
    public func cached(_ ref: ImageRef, pixels: Int, shape: Shape = .original) -> CGImage? {
        memory.object(forKey: Self.key(ref, pixels, shape))
    }

    /// The image at most `pixels` on its longer side; nil when there is none.
    public func image(_ ref: ImageRef, pixels: Int, shape: Shape = .original) async -> CGImage? {
        let key = Self.key(ref, pixels, shape)
        if let image = memory.object(forKey: key) { return image }
        return await loads.run(key) { [account, directory, memory] in
            let state = Signposts.images.beginInterval("image", id: Signposts.images.makeSignpostID())
            defer { Signposts.images.endInterval("image", state) }
            guard let file = await bestEffort("image", { try await account.value.imageFile(ref, directory: directory) }) ?? nil,
                  var image = Self.decode(file, pixels: pixels) else { return nil }
            if shape == .circle, let round = Self.circle(image, side: pixels) { image = round }
            memory.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
            return image
        }
    }

    /// Starts loading images a list will show soon (its prefetching), at a low priority.
    public func prefetch(_ refs: [ImageRef], pixels: Int, shape: Shape = .original) {
        for ref in refs where cached(ref, pixels: pixels, shape: shape) == nil {
            Task(priority: .utility) { _ = await image(ref, pixels: pixels, shape: shape) }
        }
    }

    private static func key(_ ref: ImageRef, _ pixels: Int, _ shape: Shape) -> String {
        "\(ref.key)@\(pixels)\(shape == .circle ? "o" : "")"
    }

    /// A thumbnail decoded now (not lazily at first draw on the main thread).
    static func decode(_ file: URL, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The image filling a circle `side` pixels across.
    static func circle(_ image: CGImage, side: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        context.addEllipse(in: bounds)
        context.clip()
        context.interpolationQuality = .high
        let scale = max(CGFloat(side) / CGFloat(image.width), CGFloat(side) / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.draw(image, in: CGRect(x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2,
                                       width: size.width, height: size.height))
        return context.makeImage()
    }
}

/// The decoded images, evicted under memory pressure. `@unchecked`: its one property is an
/// `NSCache`, which Apple documents as thread-safe but does not mark `Sendable`.
private final class MemoryCache: @unchecked Sendable {
    private let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        // decoded bitmaps at display size: about 30 photos or 2,000 avatars.
        cache.totalCostLimit = 48 << 20
        return cache
    }()
    func object(forKey key: String) -> CGImage? { cache.object(forKey: key as NSString) }
    func setObject(_ image: CGImage, forKey key: String, cost: Int) { cache.setObject(image, forKey: key as NSString, cost: cost) }
}

/// Joins callers of one image to one load.
private actor Loads {
    private var running: [String: Task<CGImage?, Never>] = [:]

    func run(_ key: String, _ load: @escaping @Sendable () async -> CGImage?) async -> CGImage? {
        if let task = running[key] { return await task.value }
        let task = Task(priority: .userInitiated) { await load() }
        running[key] = task
        let image = await task.value
        running[key] = nil
        return image
    }
}
