import Foundation

/// Who a pill names: a member, or everyone in the room (`@room`).
public enum MentionTarget: Hashable, Sendable {
    case user(String)
    case room
}

/// A pill in a text: who it names, over the name it shows, in UTF-16 offsets (as text views count).
public struct Mention: Hashable, Sendable {
    public var target: MentionTarget
    public var range: NSRange

    public init(_ target: MentionTarget, _ range: NSRange) {
        self.target = target
        self.range = range
    }
}

/// What the composer holds: its Markdown text and the pills in it. The core sends it with the
/// spec's intentional mentions (`lux_core::mention`).
public struct ComposedText: Hashable, Sendable, ExpressibleByStringLiteral {
    public var text: String
    public var mentions: [Mention]

    public init(_ text: String, mentions: [Mention] = []) {
        self.text = text
        self.mentions = mentions
    }

    public init(stringLiteral text: String) {
        self.init(text)
    }

    /// Nothing but white space.
    public var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The `@` and the word typed before the cursor: the members it offers replace it with a pill.
public struct MentionQuery: Hashable, Sendable {
    /// The `@` and the word, in UTF-16 offsets.
    public var range: NSRange
    /// The word after the `@`.
    public var text: String
}

/// What the composer offers for a mention.
public enum MentionSuggestion: Hashable, Sendable {
    case member(ChatMember)
    /// `@room`, where the account's power level lets it notify the room.
    case room

    /// The pill it makes, and the name the pill shows.
    public var pill: (target: MentionTarget, name: String) {
        switch self {
        case .member(let member): (.user(member.id), member.name)
        case .room: (.room, "@room")
        }
    }
}
