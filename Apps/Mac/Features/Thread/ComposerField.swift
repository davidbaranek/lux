import AppKit
import LuxCore
import UniformTypeIdentifiers

/// The composer's text, as Messages has it: a text view in a scroll view as tall as its text, from
/// one line up to `maxLines` (less in a short window, whose layout caps it), past which it scrolls
/// inside. Its height is the text's layout (TextKit 2), measured as the text or the width changes
/// and given to auto layout as the scroll view's intrinsic size.
final class ComposerField: NSScrollView {
    static let maxLines = 8
    let textView = ComposerTextView(usingTextLayoutManager: true)
    /// The text's height the field last measured, and the width it measured it at.
    private var textHeight: CGFloat = 0
    private var measuredWidth: CGFloat = -1
    /// The placeholder shows: the text view draws again as it comes or goes.
    private var wasEmpty = true

    init(font: NSFont) {
        super.init(frame: .zero)
        textView.font = font
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        // the text starts where a text field's does.
        textView.textContainer?.lineFragmentPadding = 2
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.setAccessibilityIdentifier("composer")
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        documentView = textView
        textHeight = lineHeight
        // exactly as tall as its text, over any other wish in the composer (a scroll view hugs
        // and resists weakly); only the cap the window sets, which is required, holds it lower.
        setContentHuggingPriority(.required - 1, for: .vertical)
        setContentCompressionResistancePriority(.required - 1, for: .vertical)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The text being written; set by the app (a draft, an edit, sending), it is not the user's change.
    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            textChanged()
        }
    }

    /// One line of the font, the height of the empty field.
    private var lineHeight: CGFloat {
        let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        return ceil(font.ascender - font.descender + font.leading)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: textHeight)
    }

    /// The text changed: the placeholder shows only while it is empty, and the field takes the
    /// text's new height. True if the height changed (the window lays out, animated).
    @discardableResult
    func textChanged() -> Bool {
        if textView.string.isEmpty != wasEmpty {
            wasEmpty.toggle()
            textView.needsDisplay = true
        }
        let height = measure()
        guard height != textHeight else { return false }
        textHeight = height
        invalidateIntrinsicContentSize()
        return true
    }

    /// The text's height at the field's width, up to `maxLines`: its layout is ensured only that far,
    /// so a long text costs no more than the lines that show.
    private func measure() -> CGFloat {
        let line = lineHeight, limit = line * CGFloat(Self.maxLines)
        guard contentSize.width > 0, let layout = textView.textLayoutManager else { return line }
        var over = false
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            over = fragment.layoutFragmentFrame.maxY > limit
            return !over
        }
        // the usage bounds count the empty line after a final newline, which no fragment has.
        let height = over ? limit : min(limit, layout.usageBoundsForTextContainer.height)
        return max(line, ceil(height))
    }

    override func layout() {
        super.layout()
        // a new width wraps the text again.
        guard contentSize.width != measuredWidth else { return }
        measuredWidth = contentSize.width
        textChanged()
    }
}

/// The composer's text view: a placeholder while it is empty, and a pasted or dropped file,
/// picture or video goes with the message (`onAttach`) where text would be inserted. It takes
/// pictures and PDFs from Services too, so its context menu and the + offer Continuity Camera's
/// Import from iPhone or iPad (take a photo, scan documents, add a sketch): what the iPhone
/// returns comes in as a paste does.
final class ComposerTextView: NSTextView {
    /// What the empty field says: "Message", "Reply in Thread".
    var placeholder = "" {
        didSet {
            setAccessibilityPlaceholderValue(placeholder)
            needsDisplay = true
        }
    }
    /// Files, pictures and videos pasted or dropped into the text, in their order.
    var onAttach: (([PastedItems.Item]) -> Void)?

    /// The types it pastes besides text: Paste is on with only a picture or a file to paste.
    private static let attachableTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .png, .tiff, .pdf] + [UTType.jpeg, .heic, .gif, .mpeg4Movie, .quickTimeMovie].map { NSPasteboard.PasteboardType($0.identifier) }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + Self.attachableTypes
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + Self.attachableTypes
    }

    /// Asked for what a service (Continuity Camera) returns with nothing sent: a picture or a PDF
    /// is attached, as pasted.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, onAttach != nil, Self.attachableTypes.contains(returnType) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// Paste and drop read the pasteboard here: files, pictures and videos on it are attached,
    /// else its text goes in as the text view would put it.
    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let items = Self.attachments(on: pasteboard)
        guard !items.isEmpty, let onAttach else { return super.readSelection(from: pasteboard, type: type) }
        onAttach(items)
        return true
    }

    /// Each item of `pasteboard` that is not text, as a file or the bytes of one.
    static func attachments(on pasteboard: NSPasteboard) -> [PastedItems.Item] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            guard let type = PastedItems.attachableType(of: item.types.map(\.rawValue)) else { return nil }
            if type == .fileURL {
                return item.string(forType: .fileURL).flatMap(URL.init(string:)).flatMap { $0.isFileURL ? .file($0) : nil }
            }
            return item.data(forType: NSPasteboard.PasteboardType(type.identifier)).map { .data($0, type: type, name: nil) }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: NSFont.systemFontSize),
                                                         .foregroundColor: NSColor.placeholderTextColor]
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
        NSAttributedString(string: placeholder, attributes: attributes).draw(at: origin)
    }
}
