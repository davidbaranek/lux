import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads what a photo shows, for photo search, all on the device: the words in it (Vision's text
/// recognition: a screenshot, a receipt, a sign) and, with the model, its embedding (how it looks).
struct PhotoReader: Sendable {
    /// The photo search model; nil until it is on the device: the words are read meanwhile.
    let model: PhotoSearchModel?

    /// Who reads, kept with what was read: a reader that reads more (the model arrived) or
    /// better (a newer version) reads every photo again.
    var name: String { model.map { "\(Self.textReader)+\($0.name)" } ?? Self.textReader }
    private static let textReader = "vision-text-1"

    /// The words recognized read best at this size; a larger photo is scaled down to it.
    private static let largestSide = 2_048

    /// What `file` shows: its words, one line each in reading order, and its embedding.
    func read(_ file: URL, lease: ForegroundLease) async throws -> (words: String, embedding: [Float]?) {
        let image = try Self.picture(file)
        var text = RecognizeTextRequest()
        text.recognitionLevel = .accurate
        // the language of each line is its own: a Czech receipt, an English screenshot.
        text.automaticallyDetectsLanguage = true
        let lines = try await text.perform(on: image).compactMap { $0.topCandidates(1).first?.string }
        let embedding = try await model?.embedding(of: image, lease: lease)
        return (lines.joined(separator: "\n"), embedding)
    }

    /// The photo, turned upright and no larger than `largestSide`.
    private static func picture(_ file: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: largestSide,
              ] as CFDictionary)
        else { throw PhotoSearchError.notAPicture }
        return image
    }
}
