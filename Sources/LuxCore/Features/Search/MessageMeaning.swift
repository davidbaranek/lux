import Foundation

/// Reads what messages mean, for search by meaning: each message's text through the search
/// model's text encoder (the one a search's words go through, so no other model takes memory),
/// the newest first, a batch at a time, off the main thread. A message shorter than `minChars`
/// has too little to mean and is left.
///
/// Two texts' embeddings are all rather alike (a cosine of 0.7 to 0.85), and the shortest are
/// alike to everything. Each embedding is kept less their mean (the account's first messages',
/// once), which leaves what tells them apart; a search's words lose the same mean.
actor MessageMeaning {
    /// A message at least this long is read; "ok" and "Díky!" mean nothing to search by.
    static let minChars = 12
    /// The least cosine a message found by its meaning has to the words' (both less the mean):
    /// the model's own, measured when it is built; nil while there is none.
    var minSimilarity: Float? { model?.messageSimilarity }
    /// Kept together: few writes, and little lost when the system ends the work.
    private static let batch = 32
    /// How many of the first messages the mean is taken over.
    private static let meanOver = 512

    private let store: LocalStore
    private var model: PhotoSearchModel?
    /// The mean of the model's embeddings of this account's messages; nil until it is taken.
    private var mean: [Float]?
    private var running: Task<Bool, Never>?

    init(store: LocalStore) {
        self.store = store
    }

    /// The model came (the messages are read with it; another model's reading goes), or went
    /// (search by meaning is off: what was read goes).
    func use(_ model: PhotoSearchModel?) async {
        stop()
        self.model = model
        mean = nil
        try? await store.forgetMessageEmbeddings(keep: model?.name)
        if let model, let kept = try? await store.kept(Self.meanKey(model)) {
            mean = kept.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
    }

    /// Reads the messages not read yet, the newest first: at most `limit` (nil: all of them).
    /// True when none is left.
    @discardableResult
    func read(limit: Int?, lease: ForegroundLease) async -> Bool {
        if let running { return await running.value }
        let run = Task { await readUnread(limit: limit, lease: lease) }
        running = run
        // the caller's cancel (the app leaving the front) ends the reading too.
        let done = await withTaskCancellationHandler { await run.value } onCancel: { run.cancel() }
        running = nil
        return done
    }

    func stop() {
        running?.cancel()
    }

    /// How many messages mean something, and how many were read.
    func progress() async -> (total: Int, read: Int) {
        (try? await store.embeddingCounts(minChars: Self.minChars)) ?? (0, 0)
    }

    /// The words' embedding for a search, in the messages' space (less the mean); nil while the
    /// model or its text encoder is not ready, or before any message was read.
    func query(_ embedding: [Float]?) -> [Float]? {
        guard let embedding, let mean else { return nil }
        return Self.centred(embedding, less: mean)
    }

    private func readUnread(limit: Int?, lease: ForegroundLease) async -> Bool {
        guard let model else { return false }
        await model.textEncoderLoaded(lease: lease)
        var left = limit ?? .max
        while left > 0, !Task.isCancelled {
            let wanted = mean == nil ? Self.meanOver : Self.batch
            guard let messages = try? await store.messagesToEmbed(minChars: Self.minChars, limit: min(left, wanted)) else {
                return false
            }
            if messages.isEmpty { return true }
            var embeddings: [(eventId: String, embedding: [Float]?)] = []
            for message in messages where !Task.isCancelled {
                // the encoder went (memory ran short): the rest wait for the next reading.
                guard let embedding = try? await model.embedding(ofMessage: message.body) else { return false }
                embeddings.append((message.eventId, embedding))
            }
            if mean == nil {
                guard let taken = Self.mean(of: embeddings.compactMap(\.embedding)) else { return false }
                mean = taken
                try? await store.keep(Self.meanKey(model), taken.withUnsafeBytes { Data($0) })
            }
            guard let mean else { return false }
            let centred = embeddings.map { ($0.eventId, $0.embedding.map { Self.centred($0, less: mean) }) }
            do { try await store.setMessageEmbeddings(centred, by: model.name) } catch {
                Log.app.error("message meaning: \(String(describing: error), privacy: .public)")
                return false
            }
            left -= messages.count
        }
        return false
    }

    private static func meanKey(_ model: PhotoSearchModel) -> String { "meaning-mean:\(model.name)" }

    private static func mean(of embeddings: [[Float]]) -> [Float]? {
        guard let first = embeddings.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for embedding in embeddings where embedding.count == sum.count {
            for index in sum.indices { sum[index] += embedding[index] }
        }
        return sum.map { $0 / Float(embeddings.count) }
    }

    /// `embedding` less `mean`, of unit length again.
    private static func centred(_ embedding: [Float], less mean: [Float]) -> [Float] {
        guard embedding.count == mean.count else { return embedding }
        let difference = zip(embedding, mean).map { $0 - $1 }
        let length = difference.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? difference.map { $0 / length } : difference
    }
}
