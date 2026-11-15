import Foundation
import LuxBindings

/// Photo search's query words as the token ids its text encoder reads: the Rust core reads them
/// with the tokenizer that comes with the model (`tokenizer.json`), the same on every platform.
final class QueryTokenizer: Sendable {
    private let tokenizer: CoreQueryTokenizer

    /// Loads the tokenizer: a large file (every language's words), so off the main thread.
    init(file: URL, length: Int, padId: Int, lowercase: Bool) throws {
        tokenizer = try CoreQueryTokenizer.open(settings: CoreTokenizerSettings(
            path: file.path, length: UInt32(clamping: length), padId: UInt32(clamping: padId), lowercase: lowercase))
    }

    /// The words' ids, exactly as many as the encoder reads.
    func ids(_ text: String) throws -> [Int32] {
        try tokenizer.ids(text: text)
    }
}
