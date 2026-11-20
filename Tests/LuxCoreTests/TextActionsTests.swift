import Foundation
import FoundationModels
import LuxBindings
import Testing
@testable import LuxCore

/// The composer's AI actions through the core, over a model that answers what the test gives
/// it: the switch, the actions offered, the answers checked and shown, the schema Foundation
/// Models is held to.
@MainActor
@Suite(.ownPreferences)
struct TextActionsTests {
    @Test func offIsTheDefaultAndOffersNothing() throws {
        let actions = TextActions(preferences: try .ofTest, model: FakeModel(answer: "{}"))
        #expect(!actions.isOn)
        #expect(actions.actions.isEmpty)
        actions.isOn = true
        #expect(actions.actions.map(\.id) == ["proofread", "format"])
        #expect(actions.actions.map(\.title) == ["Proofread", "Format"])
    }

    @Test func proofreadGivesCorrectionsThatApplyInPlace() async throws {
        let model = FakeModel(answer: #"{"corrections":[{"original":"teh","replacement":"the","kind":"spelling"}]}"#)
        let actions = TextActions(preferences: try .ofTest, model: model)
        actions.isOn = true
        let proofread = try #require(actions.actions.first { $0.id == "proofread" })
        let text = "👋 teh plan"
        let result = try await actions.run(proofread, on: text, in: nil)
        let expected = TextCorrection(range: NSRange(location: 3, length: 3), original: "teh", replacement: "the")
        #expect(result == .corrections([expected]))
        #expect(TextActionResult.applying([expected], to: text) == "👋 the plan")
    }

    @Test func formatGivesTheNewTextAndWhatChanged() async throws {
        let actions = TextActions(preferences: try .ofTest, model: FakeModel(answer: #"{"text":"Buy:\n\n- milk\n- bread"}"#))
        actions.isOn = true
        let format = try #require(actions.actions.first { $0.id == "format" })
        guard case .replacement(let text, let changes) = try await actions.run(format, on: "Buy milk and bread", in: nil) else {
            Issue.record("not a replacement")
            return
        }
        #expect(text == "Buy:\n\n- milk\n- bread")
        #expect(changes.contains { $0.kind == .removed && $0.text.contains("and") })
    }

    @Test func anUnsupportedLanguageIsSaidBeforeTheModelIsAsked() throws {
        let model = FakeModel(answer: "{}", language: "cs")
        let actions = TextActions(preferences: try .ofTest, model: model)
        actions.isOn = true
        #expect(actions.unavailability(of: "Ahoj, jak se máš?")?.isEmpty == false)
        #expect(actions.unavailability(of: "") != nil)
        #expect(model.requests.isEmpty)
    }

    @Test(arguments: [("proofread", #"{"corrections":[]}"#), ("format", #"{"text":"Hi there"}"#)])
    func eachOutputsSchemaMapsToFoundationModels(action id: String, answer: String) async throws {
        let model = FakeModel(answer: answer)
        let actions = TextActions(preferences: try .ofTest, model: model)
        actions.isOn = true
        let action = try #require(actions.actions.first { $0.id == id })
        _ = try await actions.run(action, on: "Hi there", in: nil)
        let request = try #require(model.requests.first)
        _ = try GenerationSchemaMapping.schema(json: request.outputSchema)
    }
}

/// Answers every request with `answer`, and keeps the requests.
private final class FakeModel: CoreLanguageModel, @unchecked Sendable {
    private let answer: String
    private let language: String
    private let lock = NSLock()
    private var asked: [CoreModelRequest] = []

    init(answer: String, language: String = "en") {
        self.answer = answer
        self.language = language
    }

    var requests: [CoreModelRequest] { lock.withLock { asked } }

    func availability() -> CoreModelAvailability { .ready }
    func languageOf(text: String) -> String? { language }
    func supports(language: String) -> Bool { language == "en" }

    func respond(request: CoreModelRequest, reply: CoreModelReply) {
        lock.withLock { asked.append(request) }
        reply.answer(json: answer)
    }
}
