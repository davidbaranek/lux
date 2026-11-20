import Foundation
import FoundationModels
import LuxBindings
import NaturalLanguage

/// Apple Intelligence on this device, as the core's model (`CoreLanguageModel`). It holds no rule
/// of the app: the core gives the instructions, the prompt and the answer's schema, and checks the
/// answer. A session per question: actions share nothing between them.
final class AppleIntelligenceModel: CoreLanguageModel {
    /// The language a text is in, when the recognizer is at least this sure.
    private static let languageConfidence = 0.5

    func availability() -> CoreModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: .ready
        case .unavailable(.appleIntelligenceNotEnabled): .turnedOff
        case .unavailable(.deviceNotEligible): .notEligible
        case .unavailable(.modelNotReady): .notReady
        case .unavailable(let reason): .unavailable(reason: String(describing: reason))
        }
    }

    func languageOf(text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= Self.languageConfidence else { return nil }
        return language.rawValue
    }

    func supports(language: String) -> Bool {
        SystemLanguageModel.default.supportsLocale(Locale(identifier: language))
    }

    func respond(request: CoreModelRequest, reply: CoreModelReply) {
        let schema: GenerationSchema
        do {
            schema = try GenerationSchemaMapping.schema(json: request.outputSchema)
        } catch {
            return reply.fail(error: .Failed(reason: "the answer's schema: \(error)"))
        }
        let session = LanguageModelSession(instructions: request.instructions)
        let prompt = request.prompt
        Task {
            do {
                reply.answer(json: try await session.respond(to: prompt, schema: schema).content.jsonString)
            } catch {
                reply.fail(error: Self.modelError(error))
            }
        }
    }

    /// What Foundation Models threw, as the core's error: 27 names its errors anew.
    private static func modelError(_ error: any Error) -> CoreModelError {
        let reason = error.localizedDescription
        if #available(iOS 27, macOS 27, *), let error = error as? LanguageModelError {
            return switch error {
            case .contextSizeExceeded: .TooLong
            case .guardrailViolation, .refusal: .Refused(reason: reason)
            case .unsupportedLanguageOrLocale: .UnsupportedLanguage
            default: .Failed(reason: reason)
            }
        }
        if let error = error as? LanguageModelSession.GenerationError {
            return switch error {
            case .exceededContextWindowSize: .TooLong
            case .guardrailViolation, .refusal: .Refused(reason: reason)
            case .unsupportedLanguageOrLocale: .UnsupportedLanguage
            case .assetsUnavailable: .Unavailable(reason: reason)
            default: .Failed(reason: reason)
            }
        }
        return .Failed(reason: reason)
    }
}

/// The core's JSON Schema (objects, arrays, strings, string enums, numbers, booleans, every
/// subschema inline) as Foundation Models' schema, which it constrains its answer to.
enum GenerationSchemaMapping {
    struct Unsupported: Error, CustomStringConvertible {
        let description: String
    }

    static func schema(json: String) throws -> GenerationSchema {
        guard let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw Unsupported(description: "not an object")
        }
        return try GenerationSchema(root: dynamic(root, name: root["title"] as? String ?? "Answer"), dependencies: [])
    }

    /// `schema` as a dynamic schema; an object's is named `name`, its properties' after it.
    static func dynamic(_ schema: [String: Any], name: String) throws -> DynamicGenerationSchema {
        let description = schema["description"] as? String
        if let choices = stringChoices(schema) {
            return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
        }
        switch schema["type"] as? String {
        case "object":
            let required = Set(schema["required"] as? [String] ?? [])
            let properties = (schema["properties"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }
            return DynamicGenerationSchema(name: name, description: description, properties: try properties.map { key, value in
                guard let property = value as? [String: Any] else { throw Unsupported(description: "property \(key)") }
                return DynamicGenerationSchema.Property(name: key, description: property["description"] as? String,
                                                        schema: try dynamic(property, name: "\(name)_\(key)"),
                                                        isOptional: !required.contains(key))
            })
        case "array":
            guard let items = schema["items"] as? [String: Any] else { throw Unsupported(description: "array without items") }
            return DynamicGenerationSchema(arrayOf: try dynamic(items, name: "\(name)_item"),
                                           minimumElements: schema["minItems"] as? Int, maximumElements: schema["maxItems"] as? Int)
        case "string": return DynamicGenerationSchema(type: String.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        case let type: throw Unsupported(description: "type \(type ?? "none")")
        }
    }

    /// A string enum's values: `enum`, or `oneOf`/`anyOf` of `const`s (a documented enum's).
    private static func stringChoices(_ schema: [String: Any]) -> [String]? {
        if let values = schema["enum"] as? [String] { return values }
        guard let options = (schema["oneOf"] ?? schema["anyOf"]) as? [[String: Any]] else { return nil }
        let values = options.compactMap { $0["const"] as? String }
        return values.count == options.count && !values.isEmpty ? values : nil
    }
}
