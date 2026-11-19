import Foundation

/// A message whose meaning is to be read, with the messages before it (its thread's when it is in
/// one, else its chat's, the oldest first): "yes, Friday at 5 at ours" means something only after
/// "When shall we come for dinner?".
struct MessageToEmbed: Sendable, Equatable {
    /// A message, as it is read: who sent it and what.
    struct Line: Sendable, Equatable {
        var senderName: String
        var body: String

        fileprivate var text: String { "\(senderName): \(body)" }
    }

    var eventId: String
    var senderName: String
    var body: String
    /// The messages before it, the oldest first.
    var context: [Line]

    /// What the model reads for the message, after its document prompt (`prompt`): the messages
    /// before it as the document's title, the message itself as its text, each line with its
    /// sender ("title: Anna: When shall we come? | text: Me: Friday at 5"). The title is
    /// EmbeddingGemma's place for what a text is about (its model card), and the message stays
    /// the text: read so, a message found by its own words loses less to the replies read with
    /// it than with the lines before it in the text (`scripts/image-search/evaluate-messages.py`).
    /// The oldest lines go first until the whole fits the encoder (`fits`); the message itself is
    /// never cut for them. A prompt without a title (another model's) has the lines before the
    /// message.
    func text(prompt: String, fits: (String) throws -> Bool) rethrows -> String {
        let message = Line(senderName: senderName, body: body).text
        var lines = context.map(\.text)
        while true {
            let text: String
            if prompt.hasPrefix(Self.untitled) {
                let title = lines.isEmpty ? "none" : lines.joined(separator: " / ")
                text = "title: \(title)" + prompt.dropFirst(Self.untitled.count) + message
            } else {
                text = prompt + (lines + [message]).joined(separator: "\n")
            }
            if lines.isEmpty { return text }
            if try fits(text) { return text }
            lines.removeFirst()
        }
    }

    /// How EmbeddingGemma's document prompt starts for a document without a title.
    private static let untitled = "title: none"
}
