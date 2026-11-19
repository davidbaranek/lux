import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads what a photo shows, for photo search, all on the device: the words in it (Vision's text
/// recognition: a screenshot, a receipt, a sign) and, with the model, its embedding (how it looks).
struct PhotoReader: PhotoReading {
    /// The photo search model; nil until it is on the device: the words are read meanwhile.
    let model: PhotoSearchModel?

    /// Who reads, kept with what was read: a reader that reads more (the model arrived) or
    /// better (a newer version) reads every photo again.
    var name: String { model.map { "\(Self.textReader)+\($0.name)" } ?? Self.textReader }
    private static let textReader = "vision-text-1"

    /// The words recognized read best at this size; a larger photo is scaled down to it.
    private static let largestSide = 2_048

    /// What `file` shows: its words, one line each in reading order, and its embedding. Read on
    /// the executor for work that holds its thread (`ImageWork`), whoever asks.
    func read(_ file: URL, lease: ForegroundLease) async throws -> (words: String, embedding: [Float]?) {
        try await withTaskExecutorPreference(ImageWork.executor) {
            let image = try Self.picture(file)
            let lines = try Self.words(in: image)
            let embedding = try await model?.embedding(of: image, lease: lease)
            return (lines.joined(separator: "\n"), embedding)
        }
    }

    func rest() async {
        await model?.releaseImageEncoder()
    }

    /// The lines of text in `image`, in reading order. Vision's request handler reads on the
    /// calling thread, the first time compiling its model for the device (seconds) and holding
    /// the thread meanwhile: called on `ImageWork`'s. (Its async `RecognizeTextRequest` does the
    /// same work in tasks of its own on Swift's cooperative pool, where no executor preference
    /// reaches, and a second request waits there on the first one's lock.)
    static func words(in image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // the language of each line is its own: a Czech receipt, an English screenshot.
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
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
