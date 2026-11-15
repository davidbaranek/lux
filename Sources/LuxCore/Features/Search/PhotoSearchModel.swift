import CoreGraphics
import CoreML
import Foundation
import Vision

/// The model photo search finds photos with: SigLIP 2 (`scripts/image-search/convert.py`), an
/// image encoder and a text encoder whose embeddings share one space, so the words "dog on the
/// beach" lie near a photo of one, in any of the languages it learned. Both run on the device
/// (Core ML, on the Neural Engine where there is one); each loads when first needed, as each is
/// large: the image encoder while photos are read, the text encoder from the first search on
/// (until it is loaded, a search finds photos by their words).
actor PhotoSearchModel {
    /// What `model.json` says of the model.
    struct Description: Decodable, Sendable {
        var model: String
        var side: Int
        var textLength: Int
        var dimension: Int
        var lowercase: Bool
        var padId: Int
    }

    /// The model's name and version, kept with each embedding: a newer model reads every photo
    /// again.
    nonisolated let name: String
    /// The least cosine of a photo's and the words' embeddings for the photo to be found by its
    /// look. SigLIP's cosines are small: a photo of what the words say is about 0.1 alike, others
    /// below 0.07 (measured on the base model in English and Czech).
    nonisolated let minSimilarity: Float = 0.085

    private let folder: URL
    private let description: Description
    private var imageEncoder: MLModel?
    private var textEncoder: MLModel?
    private var tokenizer: QueryTokenizer?
    private var preparing: Task<Void, Never>?

    /// The model in `folder` (its `model.json`, encoders and tokenizer).
    init(folder: URL) throws {
        self.folder = folder
        description = try JSONDecoder().decode(Description.self, from: Data(contentsOf: folder.appending(path: "model.json")))
        name = "\(description.model)@\(description.side)"
    }

    /// A photo's unit embedding: the photo squashed to the encoder's square, as it learned.
    func embedding(of image: CGImage) throws -> [Float] {
        let encoder = try imageEncoder ?? Self.load("ImageEncoder", in: folder)
        imageEncoder = encoder
        guard let constraint = encoder.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
            throw PhotoSearchError.unexpectedModel
        }
        let pixels = try MLFeatureValue(cgImage: image, constraint: constraint, options: [
            .cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue,
        ])
        let output = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": pixels]))
        return try floats(output)
    }

    /// Loads the text encoder and the tokenizer off the model's queue: the first load on a device
    /// compiles the encoder for it, which takes a while (some 20 s on a Mac), and searches go on
    /// by words meanwhile.
    func prepareTextEncoder() {
        guard textEncoder == nil, preparing == nil else { return }
        let folder = folder, description = description
        preparing = Task.detached(priority: .utility) { [weak self] in
            do {
                let tokenizer = try QueryTokenizer(file: folder.appending(path: "tokenizer.json"), length: description.textLength,
                                                   padId: description.padId, lowercase: description.lowercase)
                let encoder = try Self.load("TextEncoder", in: folder)
                await self?.prepared(encoder, tokenizer)
            } catch {
                Log.app.error("photo search: the text encoder: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Waits until the text encoder is loaded (or failed to).
    func textEncoderLoaded() async {
        prepareTextEncoder()
        await preparing?.value
    }

    private func prepared(_ encoder: MLModel, _ tokenizer: QueryTokenizer) {
        textEncoder = encoder
        self.tokenizer = tokenizer
    }

    /// The words' unit embedding, in the photos' space; nil until the text encoder is ready.
    func embedding(of text: String) throws -> [Float]? {
        guard let encoder = textEncoder, let tokenizer else {
            prepareTextEncoder()
            return nil
        }
        let ids = try tokenizer.ids(text)
        let input = try MLMultiArray(shape: [1, NSNumber(value: ids.count)], dataType: .int32)
        for (index, id) in ids.enumerated() { input[index] = NSNumber(value: id) }
        let output = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["ids": input]))
        return try floats(output)
    }

    /// Lets the image encoder go (the photos are read): its memory is the app's again.
    func releaseImageEncoder() {
        imageEncoder = nil
    }

    private static func load(_ name: String, in folder: URL) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        return try MLModel(contentsOf: folder.appending(path: "\(name).mlmodelc"), configuration: configuration)
    }

    private func floats(_ output: any MLFeatureProvider) throws -> [Float] {
        guard let embedding = output.featureValue(for: "embedding")?.multiArrayValue, embedding.count == description.dimension else {
            throw PhotoSearchError.unexpectedModel
        }
        return (0..<embedding.count).map { embedding[$0].floatValue }
    }
}

enum PhotoSearchError: Error {
    /// The model's files are not the encoders photo search expects.
    case unexpectedModel
    /// The file is not a picture.
    case notAPicture
}
