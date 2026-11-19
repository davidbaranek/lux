import CoreGraphics
import CoreML
import Foundation
import Vision

/// The model semantic search finds photos and messages with: EmbeddingGemma 2
/// (`scripts/image-search/convert.py`), an image encoder and a text encoder whose embeddings share
/// one space, so the words "dog on the beach" lie near a photo of one and near a message about
/// one, in any of the languages it learned. Both run on the device
/// (Core ML, on the Neural Engine where there is one); each loads when first needed, as each is
/// large: the image encoder while photos are read, the text encoder from the first search on
/// (until it is loaded, a search finds photos by their words). Once loaded, each stays until the
/// app leaves the front or memory runs short (`releaseEncoders`): Core ML keeps what it compiled
/// for the device, so a load after that is quick, but no reading of a few new photos pays for one.
actor PhotoSearchModel {
    /// What `model.json` says of the model.
    struct Description: Decodable, Sendable {
        var model: String
        var side: Int
        var textLength: Int
        var dimension: Int
        var lowercase: Bool
        var padId: Int
        /// What the model reads before a search's words, and before a message ("task: search
        /// result | query: "); none for a model that learned without.
        var queryPrompt: String?
        var documentPrompt: String?
        /// The least cosine of the words' embedding and a photo's, or a message's (both less the
        /// messages' mean), to be found; measured for the model when it is built.
        var photoSimilarity: Float?
        var messageSimilarity: Float?
        /// The token table (`embeddings.bin`): how many tokens, how wide each row. A model with
        /// one takes its tokens' vectors (the text encoder's graph is then all floats, all on the
        /// Neural Engine); one without takes their ids.
        var tokens: Int?
        var width: Int?
    }

    /// The model's name and version, kept with each embedding: a newer model reads every photo
    /// again.
    nonisolated let name: String
    /// The least cosine of a photo's and the words' embeddings for the photo to be found by its
    /// look: the model's own (`model.json`), else SigLIP's (a photo of what the words say is about
    /// 0.1 alike, others below 0.07).
    nonisolated let minSimilarity: Float
    /// The least cosine of a message's and the words' embeddings, both less the messages' mean.
    nonisolated let messageSimilarity: Float

    /// Where each of the model's files is (`model.json`, an encoder's `.mlmodelc`).
    typealias Files = @Sendable (String) throws -> URL

    private let file: Files
    private let description: Description
    private var imageEncoder: MLModel?
    private var textEncoder: MLModel?
    private var tokenizer: QueryTokenizer?
    private var table: TokenTable?
    private var preparing: Task<Void, Never>?
    /// How many times the encoders were let go: an encoder whose load began before the last time
    /// is used for what it was loaded for, and not kept.
    private var releases = 0
    /// The encoders' loads under way, and who waits for them all to end (`close`, before the
    /// model's files go).
    private var loading = 0
    private var loaded: [CheckedContinuation<Void, Never>] = []
    /// Photo search was turned off: no encoder loads again.
    private var isClosed = false

    /// The model whose files `file` finds (its `model.json`, encoders and tokenizer): an asset
    /// pack names each of its files' places itself, which need not share one folder.
    init(files file: @escaping Files) throws {
        self.file = file
        description = try JSONDecoder().decode(Description.self, from: Data(contentsOf: file("model.json")))
        name = "\(description.model)@\(description.side)"
        minSimilarity = description.photoSimilarity ?? 0.085
        messageSimilarity = description.messageSimilarity ?? 0.25
    }

    /// The model in `folder` (a model built on this Mac, for tests and `-LuxPhotoModel`).
    init(folder: URL) throws {
        try self.init(files: { folder.appending(path: $0) })
    }

    /// A photo's unit embedding: the photo squashed to the encoder's square, as it learned. The
    /// first loads the image encoder (compiled for this device the first time: long).
    func embedding(of image: CGImage, lease _: ForegroundLease) async throws -> [Float] {
        try embedding(of: image, by: try await loadedImageEncoder())
    }

    /// Predicts on the model's actor, which holds the encoder (an `MLModel` is not `Sendable`).
    private func embedding(of image: CGImage, by encoder: MLModel) throws -> [Float] {
        guard let constraint = encoder.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
            throw PhotoSearchError.unexpectedModel
        }
        let pixels = try MLFeatureValue(cgImage: image, constraint: constraint, options: [
            .cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue,
        ])
        let output = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": pixels]))
        return try floats(output)
    }

    /// The image encoder, loaded now if it is not (photos are read one at a time: one load).
    private func loadedImageEncoder() async throws -> MLModel {
        if let imageEncoder { return imageEncoder }
        let release = releases
        let encoder = try await load(.image)
        if release == releases { imageEncoder = encoder }
        return encoder
    }

    /// Loads the text encoder and the tokenizer off the model's actor: the first load on a device
    /// compiles the encoder for it, which takes a while (some 20 s on a Mac), and searches go on
    /// by words meanwhile.
    func prepareTextEncoder(lease _: ForegroundLease) {
        guard textEncoder == nil, preparing == nil, !isClosed else { return }
        let file = file, description = description
        // reading the tokenizer holds its thread: on its own executor, not the pool.
        preparing = Task(executorPreference: ImageWork.executor, priority: .utility) { [weak self] in
            await bestEffort("photo search: the text encoder") {
                let tokenizer = try QueryTokenizer(file: file("tokenizer.json"), length: description.textLength,
                                                   padId: description.padId, lowercase: description.lowercase)
                let table = try description.tokens.flatMap { tokens in
                    try description.width.map { try TokenTable(file: file("embeddings.bin"), tokens: tokens, width: $0) }
                }
                try await self?.loadTextEncoder(tokenizer, table)
            }
        }
    }

    /// Waits until the text encoder is loaded (or failed to), loading it if it is not.
    func textEncoderLoaded(lease: ForegroundLease) async {
        prepareTextEncoder(lease: lease)
        await preparing?.value
    }

    /// Waits while the text encoder loads (one started under a lease); at once when none loads.
    func textEncoderPrepared() async {
        await preparing?.value
    }

    private func loadTextEncoder(_ tokenizer: QueryTokenizer, _ table: TokenTable?) async throws {
        let encoder = try await load(.text)
        // released while it loaded (`preparing` cancelled): it is not kept.
        try Task.checkCancellation()
        textEncoder = encoder
        self.tokenizer = tokenizer
        self.table = table
    }

    /// A search's words' unit embedding, in the photos' and messages' space; nil until the text
    /// encoder is ready.
    func embedding(ofQuery text: String) throws -> [Float]? {
        try embedding(of: (description.queryPrompt ?? "") + text)
    }

    /// A message's unit embedding, read with the messages before it as far as the encoder reads
    /// (`MessageToEmbed.text`), as search by meaning keeps it; nil until the text encoder is ready.
    func embedding(ofMessage message: MessageToEmbed) throws -> [Float]? {
        guard let tokenizer else { return nil }
        return try embedding(of: message.text(prompt: description.documentPrompt ?? "", fits: tokenizer.fits))
    }

    private func embedding(of text: String) throws -> [Float]? {
        // loaded only under a lease (`prepareTextEncoder`): until then, nothing to compare.
        guard let encoder = textEncoder, let tokenizer else { return nil }
        let ids = try tokenizer.ids(text)
        let inputs: [String: Any]
        if let table {
            let (embeds, mask) = try table.inputs(ids, padId: description.padId)
            inputs = ["embeds": embeds, "mask": mask]
        } else {
            let input = try MLMultiArray(shape: [1, NSNumber(value: ids.count)], dataType: .int32)
            for (index, id) in ids.enumerated() { input[index] = NSNumber(value: id) }
            inputs = ["ids": input]
        }
        let output = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
        return try floats(output)
    }

    /// The text encoder is loaded: a search finds photos by their look at once.
    var isTextEncoderReady: Bool { textEncoder != nil }

    /// Lets both encoders go (the app left the front, or the system is short of memory): their
    /// memory is the app's again, and the next photo or search loads its encoder again.
    func releaseEncoders() {
        releases += 1
        imageEncoder = nil
        preparing?.cancel()
        preparing = nil
        textEncoder = nil
        tokenizer = nil
        table = nil
    }

    /// Photo search was turned off: no encoder loads again, and this returns once none of this
    /// model's loads is under way, so its files can go.
    func close() async {
        isClosed = true
        let preparation = preparing
        releaseEncoders()
        await preparation?.value
        if loading > 0 { await withCheckedContinuation { loaded.append($0) } }
    }

    /// The model's two encoders.
    private enum Encoder: String {
        case image, text

        /// Its own model file, in a model built before both were functions of one.
        var fileName: String { self == .image ? "ImageEncoder.mlmodelc" : "TextEncoder.mlmodelc" }
    }

    /// Loads `encoder`, counted in `loading` until it ends.
    private func load(_ encoder: Encoder) async throws -> MLModel {
        guard !isClosed else { throw CancellationError() }
        loading += 1
        defer {
            loading -= 1
            if loading == 0 {
                for waiting in loaded { waiting.resume() }
                loaded = []
            }
        }
        return try await Self.load(encoder, from: file)
    }

    /// An encoder: a function of the one model that holds both ("image", "text"), or, of a
    /// model built before, its own model file.
    private static func load(_ encoder: Encoder, from file: Files) async throws -> MLModel {
        let signpost = Signposts.model.beginInterval("load", "\(encoder.rawValue, privacy: .public)")
        defer { Signposts.model.endInterval("load", signpost) }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let both = try file("Encoders.mlmodelc")
        guard FileManager.default.fileExists(atPath: both.path) else {
            return try await MLModel.load(contentsOf: file(encoder.fileName), configuration: configuration)
        }
        configuration.functionName = encoder.rawValue
        return try await MLModel.load(contentsOf: both, configuration: configuration)
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

/// Every token's input vector, as the model's embedding layer gives it: rows of float16 in id
/// order, mapped from the file (only the rows a text uses are read; none stay in memory).
///
/// The values are copied as they are, 16 bits each, never read as numbers: Swift's `Float16`
/// does not exist on Intel Macs, and the model takes them as they are.
struct TokenTable: Sendable {
    /// A float16 value's bits.
    private typealias Half = UInt16
    /// 1.0 as float16 (IEEE 754 binary16).
    private static let one: Half = 0x3C00

    private let rows: Data
    private let tokens: Int
    private let width: Int

    init(file: URL, tokens: Int, width: Int) throws {
        rows = try Data(contentsOf: file, options: .alwaysMapped)
        guard rows.count == tokens * width * MemoryLayout<Half>.size else { throw PhotoSearchError.unexpectedModel }
        self.tokens = tokens
        self.width = width
    }

    /// The text encoder's inputs for `ids`: each real token's row (padding's left zero), and
    /// which are real (1) or padding (0).
    func inputs(_ ids: [Int32], padId: Int) throws -> (embeds: MLMultiArray, mask: MLMultiArray) {
        let count = NSNumber(value: ids.count)
        let embeds = try MLMultiArray(shape: [1, count, NSNumber(value: width)], dataType: .float16)
        let mask = try MLMultiArray(shape: [1, count], dataType: .float16)
        let rowBytes = width * MemoryLayout<Half>.size
        embeds.withUnsafeMutableBytes { target, _ in
            target.initializeMemory(as: UInt8.self, repeating: 0)
            rows.withUnsafeBytes { source in
                guard let from = source.baseAddress, let to = target.baseAddress else { return }
                for (index, id) in ids.enumerated() where Int(id) != padId && (0..<tokens).contains(Int(id)) {
                    to.advanced(by: index * rowBytes).copyMemory(from: from.advanced(by: Int(id) * rowBytes), byteCount: rowBytes)
                }
            }
        }
        mask.withUnsafeMutableBytes { target, _ in
            let values = target.bindMemory(to: Half.self)
            for (index, id) in ids.enumerated() where values.indices.contains(index) {
                values[index] = Int(id) == padId ? 0 : Self.one
            }
        }
        return (embeds, mask)
    }
}
