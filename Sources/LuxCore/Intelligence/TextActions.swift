import Foundation
import LuxBindings

/// An action over the composer's text, as the apps show it: the core's definition with its
/// title and symbol. A new action is a definition in the core, not code here.
public struct TextAction: Identifiable, Sendable {
    fileprivate let definition: CoreTextAction
    public var id: String { definition.id }

    /// The built-in actions by their id, in the user's language; a user's own by its name.
    public var title: String {
        switch definition.id {
        case "proofread": String(localized: "Proofread")
        case "format": String(localized: "Format")
        default: definition.name
        }
    }

    public var symbol: String {
        switch definition.id {
        case "proofread": "text.magnifyingglass"
        case "format": "list.bullet.indent"
        default: "sparkles"
        }
    }
}

/// A run of a preview: kept, added, or removed from the text.
public struct TextActionChange: Sendable, Equatable {
    public enum Kind: Sendable { case kept, added, removed }
    public var kind: Kind
    public var text: String
}

/// One mistake and its correction, at a range of the text (UTF-16, as text views count).
public struct TextCorrection: Sendable, Equatable {
    public var range: NSRange
    public var original: String
    public var replacement: String
}

/// An action's answer, checked by the core; how it shows follows from its kind, not the action.
public enum TextActionResult: Sendable, Equatable {
    /// Corrections to apply to the text, each in place; none when it needs none.
    case corrections([TextCorrection])
    /// A new text to preview (what changed) and apply in place of the old.
    case replacement(text: String, changes: [TextActionChange])
    /// Something to read.
    case note(String)

    /// The text with every correction applied, last first so the ranges stay right.
    public static func applying(_ corrections: [TextCorrection], to text: String) -> String {
        let result = NSMutableString(string: text)
        for correction in corrections.sorted(by: { $0.range.location > $1.range.location })
        where NSMaxRange(correction.range) <= result.length {
            result.replaceCharacters(in: correction.range, with: correction.replacement)
        }
        return result as String
    }

    /// The composer's text once the result is applied to `text`; nil when there is nothing to
    /// apply (a note, no corrections).
    public func applied(to text: String) -> String? {
        switch self {
        case .corrections(let corrections): corrections.isEmpty ? nil : Self.applying(corrections, to: text)
        case .replacement(let new, _): new == text ? nil : new
        case .note: nil
        }
    }

    /// How the result shows over `text`, for its preview: the runs kept, removed and added, in
    /// order. Both apps draw these runs; neither knows which action gave them.
    public func preview(of text: String) -> [TextActionChange] {
        switch self {
        case .replacement(_, let changes):
            return changes
        case .note(let note):
            return [TextActionChange(kind: .kept, text: note)]
        case .corrections(let corrections):
            let source = text as NSString
            var runs: [TextActionChange] = []
            var at = 0
            for correction in corrections.sorted(by: { $0.range.location < $1.range.location })
            where correction.range.location >= at && NSMaxRange(correction.range) <= source.length {
                if correction.range.location > at {
                    runs.append(TextActionChange(kind: .kept, text: source.substring(with: NSRange(location: at, length: correction.range.location - at))))
                }
                runs.append(TextActionChange(kind: .removed, text: source.substring(with: correction.range)))
                runs.append(TextActionChange(kind: .added, text: correction.replacement))
                at = NSMaxRange(correction.range)
            }
            if at < source.length { runs.append(TextActionChange(kind: .kept, text: source.substring(from: at))) }
            return runs
        }
    }
}

/// Why an action gave nothing, in the user's words.
public struct TextActionError: LocalizedError, Sendable {
    public let errorDescription: String?
}

/// The chat an action may read, when its templates ask for it: what the composer's chat shows
/// now. Built-in actions read only the text.
public struct TextActionChat: Sendable {
    public var name: String
    public var network: String?
    public var isGroup: Bool
    public var myName: String?
    public var messages: [MessageItem]

    public init(name: String, network: String?, isGroup: Bool, myName: String?, messages: [MessageItem]) {
        self.name = name
        self.network = network
        self.isGroup = isGroup
        self.myName = myName
        self.messages = messages
    }
}

/// The AI actions over the composer's text, behind Settings › AI's one switch, over Apple
/// Intelligence on this device. Off (the default), it offers nothing and no model is asked.
@MainActor
public final class TextActions {
    private let preferences: Preferences
    private let intelligence: CoreIntelligence
    /// Settings and the composers follow the switch and the model's state.
    public let changes = Broadcast()

    /// Over `model`: Apple Intelligence, or a test's.
    init(preferences: Preferences, model: any CoreLanguageModel = AppleIntelligenceModel()) {
        self.preferences = preferences
        intelligence = CoreIntelligence(model: model)
    }

    /// The one switch for AI in Lux.
    public var isOn: Bool {
        get { preferences.aiFeatures }
        set {
            guard newValue != preferences.aiFeatures else { return }
            preferences.aiFeatures = newValue
            changes.send()
        }
    }

    /// The actions the composer offers: none while AI is off or the model is not on this device.
    public var actions: [TextAction] {
        guard isOn else { return [] }
        if case .notEligible = intelligence.availability() { return [] }
        return builtInTextActions().map(TextAction.init(definition:))
    }

    /// The model's state in one line, for Settings.
    public var status: String {
        switch intelligence.availability() {
        case .ready: String(localized: "Apple Intelligence is ready. What you ask it stays on this device.")
        case .turnedOff: String(localized: "Turn on Apple Intelligence in System Settings to use it here.")
        case .notEligible: String(localized: "Apple Intelligence is not available on this device.")
        case .notReady: String(localized: "Apple Intelligence is getting ready. Try again in a while.")
        case .unavailable: String(localized: "Apple Intelligence is not available now.")
        }
    }

    /// Why `text` cannot be worked on now, in the user's words; nil when it can. Asked before the
    /// model is, so an action shows as unavailable instead of failing on a tap.
    public func unavailability(of text: String) -> String? {
        do {
            try intelligence.checkText(text: text)
            return nil
        } catch {
            return Self.words(error)
        }
    }

    /// `action`'s answer about `text`, reading `chat` only if the action asks for it.
    public func run(_ action: TextAction, on text: String, in chat: TextActionChat?) async throws(TextActionError) -> TextActionResult {
        let context = ChatSnapshot(chat: chat, today: Date.now.formatted(.iso8601.year().month().day()))
        let result: CoreActionResult
        do {
            result = try await intelligence.run(action: action.definition, text: text, context: context)
        } catch {
            throw TextActionError(errorDescription: Self.words(error))
        }
        return switch result {
        case .corrections(let corrections):
            .corrections(corrections.map {
                TextCorrection(range: NSRange(location: Int($0.start), length: Int($0.length)), original: $0.original,
                               replacement: $0.replacement)
            })
        case .replacement(let text, let changes):
            .replacement(text: text, changes: changes.map { change in
                let kind: TextActionChange.Kind = switch change.kind {
                case .kept: .kept
                case .added: .added
                case .removed: .removed
                }
                return TextActionChange(kind: kind, text: change.text)
            })
        case .note(let text): .note(text)
        }
    }

    private static func words(_ error: any Error) -> String {
        guard let error = error as? CoreIntelligenceError else { return String(localized: "Something went wrong. Try again.") }
        return switch error {
        case .Unavailable: String(localized: "Apple Intelligence is not available now.")
        case .Empty: String(localized: "Write a message first.")
        case .TooLong: String(localized: "The message is too long.")
        case .UnsupportedLanguage(let language):
            if let name = Locale.current.localizedString(forLanguageCode: language), !language.isEmpty {
                String(localized: "Apple Intelligence doesn't support \(name) yet.")
            } else {
                String(localized: "Apple Intelligence doesn't support this language yet.")
            }
        case .Hidden: String(localized: "This chat is hidden from AI.")
        case .Refused: String(localized: "Apple Intelligence can't help with this message.")
        case .Action, .Failed: String(localized: "Something went wrong. Try again.")
        }
    }
}

/// What the chat showed when the action ran, as the core reads its variables.
private final class ChatSnapshot: CoreActionContext {
    private let shown: TextActionChat?
    private let date: String

    init(chat: TextActionChat?, today: String) {
        shown = chat
        date = today
    }

    func today() -> String { date }

    func chat() throws -> CoreActionChat? {
        shown.map { CoreActionChat(name: $0.name, network: $0.network, isGroup: $0.isGroup) }
    }

    func myName() throws -> String? { shown?.myName }

    func recentMessages(count: UInt32) throws -> [CoreActionMessage] {
        (shown?.messages ?? []).suffix(Int(count)).map {
            CoreActionMessage(sender: $0.senderName, text: $0.body, sentAt: $0.date.formatted(.iso8601), mine: $0.isOwn)
        }
    }
}
