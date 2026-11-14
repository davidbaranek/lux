import Foundation

/// A photo or a file to send, prepared on this device (`AttachmentMaker`): a file, and what other
/// apps show of it.
public struct OutgoingAttachment: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A picture, its size in pixels.
        case photo(width: Int, height: Int)
        /// A video, its size in pixels and its length in seconds; the thumbnail is its poster.
        case video(width: Int, height: Int, duration: TimeInterval)
        case file
    }

    /// A photo's smaller copy, which other apps show until they need the photo itself.
    public struct Thumbnail: Sendable, Equatable {
        public var file: URL
        public var mimetype: String
        public var size: Int
        public var width: Int
        public var height: Int

        public init(file: URL, mimetype: String, size: Int, width: Int, height: Int) {
            self.file = file; self.mimetype = mimetype; self.size = size; self.width = width; self.height = height
        }
    }

    public var file: URL
    /// The name other apps show ("Trip plan.pdf").
    public var name: String
    public var mimetype: String
    /// In bytes.
    public var size: Int
    public var kind: Kind
    public var thumbnail: Thumbnail?

    public init(file: URL, name: String, mimetype: String, size: Int, kind: Kind, thumbnail: Thumbnail? = nil) {
        self.file = file; self.name = name; self.mimetype = mimetype; self.size = size; self.kind = kind; self.thumbnail = thumbnail
    }
}
