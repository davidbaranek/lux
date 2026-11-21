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
/// pills, read out as the composer's `ComposedText` and written back from one (a draft, an edit's
/// message). A pill is never half a name: a deletion that cuts into one takes it whole, and text
/// put into part of one (an autocorrection, a spelling fix of one of its words) is refused
/// (`edit`).
///
/// Pills are runs of the name's own text, not `NSTextAttachment`s (Element X's pills are
/// attachments of its rich text editor, whose model is not text): the composer's text is the
/// Markdown the core reads and sends, its formatting shown from the core's runs of that text and
/// its pills' UTF-16 ranges handed over as they are, so an attachment's one character would need
/// its offsets mapped at each of those boundaries.
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

    /// Marks `range` of `storage` as the pill of `target`.
    static func mark(_ storage: NSMutableAttributedString, _ target: MentionTarget, in range: NSRange) {
        guard NSMaxRange(range) <= storage.length else { return }
        storage.addAttribute(.mention, value: value(target), range: range)
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

    /// What an edit of the text views' `ranges` with `replacement` does to the pills it touches.
    enum Edit: Equatable {
        /// It cuts into none: as asked.
        case asAsked
        /// A deletion that cuts into pills: these ranges go instead, each grown over the pills it
        /// cuts, the later first.
        case delete([NSRange])
        /// Text put into part of a pill: refused, the pill stays whole.
        case refused
    }

    /// What an edit of `ranges` with `replacement` does: each range grown over the pills it cuts
    /// into on its own (never the text between two ranges).
    static func edit(_ ranges: [NSRange], replacement: String, in text: NSAttributedString) -> Edit {
        let grown = ranges.map { expanded($0, in: text) }
        guard grown != ranges else { return .asAsked }
        guard replacement.isEmpty else { return .refused }
        // two ranges grown over one pill are one range.
        var merged: [NSRange] = []
        for range in grown.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return .delete(merged.reversed())
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
