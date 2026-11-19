import Testing
@testable import LuxCore

/// What the model reads for a message: the messages before it as the title, the message as the
/// text, and the oldest context dropped first when it is too long, never the message.
struct MessageToEmbedTests {
    private static let prompt = "title: none | text: "

    private let reply = MessageToEmbed(eventId: "$3", senderName: "Anna", body: "yes, Friday at 5 at ours", context: [
        .init(senderName: "Me", body: "Are you free for dinner?"),
        .init(senderName: "Anna", body: "Friday or Saturday"),
    ])

    @Test func theMessagesBeforeItAreTheTitleAndItIsTheText() {
        #expect(reply.text(prompt: Self.prompt) { _ in true }
            == "title: Me: Are you free for dinner? / Anna: Friday or Saturday | text: Anna: yes, Friday at 5 at ours")
    }

    @Test func aMessageWithNothingBeforeItHasNoTitle() {
        let first = MessageToEmbed(eventId: "$1", senderName: "Me", body: "Are you free for dinner?", context: [])
        #expect(first.text(prompt: Self.prompt) { _ in true } == "title: none | text: Me: Are you free for dinner?")
    }

    @Test func theOldestMessagesGoFirstUntilItFits() {
        var asked: [String] = []
        let text = reply.text(prompt: Self.prompt) { text in
            asked.append(text)
            return text.count <= 70
        }
        #expect(text == "title: Anna: Friday or Saturday | text: Anna: yes, Friday at 5 at ours")
        #expect(asked.count == 2)
    }

    @Test func theMessageIsNeverCutForItsContext() {
        // nothing fits: the message is read alone, whole (the encoder cuts its end, as before).
        #expect(reply.text(prompt: Self.prompt) { _ in false } == "title: none | text: Anna: yes, Friday at 5 at ours")
    }

    @Test func aModelWithoutATitleReadsTheLinesBeforeTheMessage() {
        #expect(reply.text(prompt: "passage: ") { _ in true }
            == "passage: Me: Are you free for dinner?\nAnna: Friday or Saturday\nAnna: yes, Friday at 5 at ours")
    }
}
