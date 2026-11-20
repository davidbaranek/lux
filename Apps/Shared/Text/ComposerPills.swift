import LuxCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension NSAttributedString.Key {
    /// A pill in the composer's text: who it names, as text (a user id, or `@room`). The name it
    /// shows is the run's text.
    static let mention = NSAttributedString.Key("com.bardav.lux.mention")
}

/// The pills of both apps' composers: runs of the text view's storage with `.mention`, styled as
/// pills, that an edit takes whole (a pill never holds half a name), read out as the composer's
/// `ComposedText` and written back from one (a draft, an edit's message).
enum ComposerPills {
    private static let room = "@room"

    private static func value(_ target: MentionTarget) -> String {
        switch target {
        case .user(let id): id
        case .room: room
        }
    }

    private static func target(_ value: String) -> MentionTarget {
        value == room ? .room : .user(value)
    }

    /// The text and its pills.
    static func composed(_ text: NSAttributedString) -> ComposedText {
        var mentions: [Mention] = []
        text.enumerateAttribute(.mention, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let value = value as? String else { return }
            mentions.append(Mention(target(value), range))
        }
        return ComposedText(text.string, mentions: mentions)
    }

    /// `composed` as the composer's storage holds it: its text with `attributes`, its pills marked.
    static func attributed(_ composed: ComposedText, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let text = NSMutableAttributedString(string: composed.text, attributes: attributes)
        for mention in composed.mentions where NSMaxRange(mention.range) <= text.length {
            text.addAttribute(.mention, value: value(mention.target), range: mention.range)
        }
        return text
    }

    /// The pills' marks in `text`, to put back after its attributes are set anew (`mark`).
    static func marks(in text: NSAttributedString) -> [(range: NSRange, value: Any)] {
        var marks: [(range: NSRange, value: Any)] = []
        text.enumerateAttribute(.mention, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let value { marks.append((range, value)) }
        }
        return marks
    }

    static func mark(_ storage: NSMutableAttributedString, _ marks: [(range: NSRange, value: Any)]) {
        for mark in marks where NSMaxRange(mark.range) <= storage.length {
            storage.addAttribute(.mention, value: mark.value, range: mark.range)
        }
    }

    /// The pills' runs in `text`.
    static func ranges(in text: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        text.enumerateAttribute(.mention, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        return ranges
    }

    /// The range an edit of `range` really replaces: grown over each pill it cuts into, so a pill
    /// goes whole or stays whole. A caret inside a pill (no length) moves to its end.
    static func expanded(_ range: NSRange, in text: NSAttributedString) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        for pill in ranges(in: text) {
            if range.length == 0 {
                if pill.location < start, start < NSMaxRange(pill) { return NSRange(location: NSMaxRange(pill), length: 0) }
                continue
            }
            if pill.location < end, start < NSMaxRange(pill) {
                start = min(start, pill.location)
                end = max(end, NSMaxRange(pill))
            }
        }
        return NSRange(location: start, length: end - start)
    }

    /// Puts the pill of `suggestion` in the place of `range` (the `@` and its word), and a space
    /// after it; the caret's new place.
    @discardableResult
    static func insert(_ suggestion: MentionSuggestion, replacing range: NSRange, in storage: NSMutableAttributedString,
                       attributes: [NSAttributedString.Key: Any]) -> Int {
        let (target, name) = suggestion.pill
        let pill = NSMutableAttributedString(string: name, attributes: attributes)
        pill.addAttribute(.mention, value: value(target), range: NSRange(location: 0, length: pill.length))
        pill.append(NSAttributedString(string: " ", attributes: attributes))
        storage.replaceCharacters(in: range, with: pill)
        return range.location + pill.length
    }

    /// The pills drawn as pills: the accent colour on a tint of it.
    static func style(_ storage: NSMutableAttributedString, tint: PlatformColor) {
        for pill in ranges(in: storage) {
            storage.addAttributes([.foregroundColor: tint, .backgroundColor: tint.withAlphaComponent(0.15)], range: pill)
        }
    }
}
