import LuxCore
import UIKit
import UniformTypeIdentifiers

/// A growing text view and a send button on Liquid Glass, with a bar above the text when it
/// answers or edits a message. While nothing is written and the chat has unread messages, the
/// button is an eye that sends a read receipt; holding it shows `readReceiptsMenu`. The text is
/// Markdown, shown formatted as it is typed (the marks dimmed); a selection's menu has Format.
/// A pasted or dropped photo, video or file waits in it as one picked with the + does. An `@`
/// and a word ask for the members it offers (`onMentionQuery`); a picked one is a pill, a run of
/// the text that shows their name and goes whole when an edit touches it (`ComposerPills`).
final class ComposerView: UIView, UITextViewDelegate, UITextPasteDelegate, UIGestureRecognizerDelegate {
    /// The round buttons beside the field, and the field's one-line height: as Messages has them.
    static let button: CGFloat = 40

    var onSend: ((ComposedText) -> Void)?
    /// The `@` and the word typed before the cursor changed: nil when there is none.
    var onMentionQuery: ((MentionQuery?) -> Void)?
    private var mentionQuery: MentionQuery?
    var onCancelMode: (() -> Void)?
    var onReadReceipt: (() -> Void)?
    /// Photos, videos or files pasted or dropped into the text: they go with the message.
    var onPasteItems: (([NSItemProvider]) -> Void)?
    /// The user changed the text (not the app, as a draft does).
    var onTextChange: ((String) -> Void)?
    /// What holding the eye offers: how this chat sends read receipts.
    var readReceiptsMenu: UIMenu?
    /// What holding Send offers: send later.
    var sendLaterMenu: UIMenu?
    /// The + before the text was tapped: its panel opens in the keyboard's place, or (×) closes.
    var onAttach: (() -> Void)?
    private var needsReadReceipt = false
    private var showsEye = false
    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    private let stack = UIStackView()
    private let modeBar = ModeBar()
    /// An AI action's result over the text, with ✓ and ✕.
    private let reviewBar = ReviewBar()
    /// The text as written while an AI action's result shows over it; nil otherwise.
    private var reviewed: String?
    /// ✓ on an AI action's result: put it in the composer.
    var onAcceptReview: (() -> Void)?
    /// The AI action at work for this review: ended with it, so its result never lands in a
    /// later one.
    var reviewTask: Task<Void, Never>?
    private let strip = AttachmentStrip()
    /// A file waiting in the composer was taken out.
    var onRemoveAttachment: ((URL) -> Void)?
    /// A waiting video's quality was chosen.
    var onVideoQuality: ((URL, VideoQuality) -> Void)?
    /// The waiting videos with a choice of quality.
    var videos: [URL: PendingVideo] {
        get { strip.videos }
        set { strip.videos = newValue }
    }
    /// The files still on their way to the disk (from the library, iCloud), and how far each is.
    var arriving: [URL: Double] {
        get { strip.arriving }
        set { strip.arriving = newValue }
    }

    /// The picture of a file not on disk yet, from where it comes.
    func showPreview(_ image: UIImage, of file: URL) {
        strip.showPreview(image, of: file)
    }
    /// A photo or a PDF waiting in the composer was tapped, in its tile: it opens in Markup.
    var onMarkUpAttachment: ((URL, UIView) -> Void)?
    /// The files waiting to go with the message; the composer can send with them alone.
    var attachments: [URL] = [] {
        didSet {
            guard attachments != oldValue else { return }
            strip.show(attachments)
            UIView.animate(withDuration: 0.2) {
                self.strip.isHidden = self.attachments.isEmpty
                self.superview?.layoutIfNeeded()
            }
            refresh()
        }
    }
    private let textView = ComposerTextView()
    private lazy var backToKeyboard = UITapGestureRecognizer(target: self, action: #selector(showKeyboard))
    /// In a merged chat, the network a message goes through: a badge on the send button.
    private let network = UIImageView()
    private let placeholder = UILabel()
    /// What the empty field says: "Message", "Reply in Thread".
    var placeholderText: String? {
        get { placeholder.text }
        set { placeholder.text = newValue }
    }
    private lazy var send = UIButton(configuration: .prominentGlass(), primaryAction: UIAction { [weak self] _ in self?.primary() })
    private lazy var height = textView.heightAnchor.constraint(equalToConstant: 36)
    private let attach: UIButton = {
        var configuration = UIButton.Configuration.glass()
        configuration.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))
        configuration.cornerStyle = .capsule
        // + to × and back at twice the system's pace: it answers the tap at once.
        configuration.symbolContentTransition = UISymbolContentTransition(.replace, options: .speed(2))
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = String(localized: "Attach")
        return button
    }()

    /// The text being written.
    var text: String { textView.text }

    /// The text being written, with its pills.
    var composed: ComposedText {
        get { ComposerPills.composed(textView.textStorage) }
        set {
            textView.attributedText = ComposerPills.attributed(newValue, attributes: baseAttributes)
            restyle()
            refresh()
            updateMentionQuery()
        }
    }

    /// Puts the pill of `suggestion` in the place of the `@` and its word at `range`.
    func insertMention(_ suggestion: MentionSuggestion, replacing range: NSRange) {
        guard NSMaxRange(range) <= textView.textStorage.length else { return }
        let caret = ComposerPills.insert(suggestion, replacing: range, in: textView.textStorage, attributes: baseAttributes)
        textView.selectedRange = NSRange(location: caret, length: 0)
        textViewDidChange(textView)
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: textView.font ?? .preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label]
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        glass.cornerConfiguration = .uniformCorners(radius: 22)
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.textContainerInset = UIEdgeInsets(top: 7, left: 4, bottom: 7, right: 4)
        textView.accessibilityIdentifier = "composer"
        // pictures, videos and files paste too, beside the text the view takes as it would; the
        // system asks the user before a paste reads another app's pasteboard.
        textView.pasteDelegate = self
        textView.onPasteItems = { [weak self] providers in self?.onPasteItems?(providers) }
        textView.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers:
            (textView.pasteConfiguration?.acceptableTypeIdentifiers ?? [UTType.text.identifier])
                + [UTType.image, .movie, .fileURL, .data].map(\.identifier))
        placeholder.text = String(localized: "Message")
        placeholder.textColor = .placeholderText
        placeholder.font = textView.font
        send.configuration?.image = UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(weight: .bold))
        send.configuration?.cornerStyle = .capsule
        send.accessibilityLabel = String(localized: "Send")
        send.isEnabled = false
        updateButton()
        attach.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            onAttach?()
        }, for: .primaryActionTriggered)
        // a tap in the text while the panel shows brings the keyboard back.
        backToKeyboard.delegate = self
        backToKeyboard.isEnabled = false
        textView.addGestureRecognizer(backToKeyboard)
        modeBar.isHidden = true
        modeBar.onCancel = { [weak self] in self?.onCancelMode?() }
        stack.axis = .vertical
        strip.isHidden = true
        strip.onRemove = { [weak self] file in self?.onRemoveAttachment?(file) }
        strip.onVideoQuality = { [weak self] file, quality in self?.onVideoQuality?(file, quality) }
        strip.onMarkUp = { [weak self] file, tile in self?.onMarkUpAttachment?(file, tile) }
        reviewBar.isHidden = true
        reviewBar.onReject = { [weak self] in self?.endReview(applying: nil) }
        reviewBar.onAccept = { [weak self] in self?.onAcceptReview?() }
        stack.addArrangedSubview(reviewBar)
        stack.addArrangedSubview(modeBar)
        stack.addArrangedSubview(strip)
        stack.addArrangedSubview(textView)
        network.contentMode = .scaleAspectFit
        network.isHidden = true
        // a ring in the background's colour sets it off the button.
        network.layer.borderWidth = 2
        network.layer.borderColor = UIColor.systemBackground.cgColor
        network.layer.cornerRadius = 9
        network.clipsToBounds = true
        for view in [attach, glass, stack, placeholder, send, network] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(attach)
        addSubview(glass)
        glass.contentView.addSubview(stack)
        glass.contentView.addSubview(placeholder)
        addSubview(send)
        addSubview(network)
        NSLayoutConstraint.activate([
            attach.leadingAnchor.constraint(equalTo: leadingAnchor),
            attach.bottomAnchor.constraint(equalTo: bottomAnchor),
            attach.widthAnchor.constraint(equalToConstant: Self.button),
            attach.heightAnchor.constraint(equalToConstant: Self.button),
            glass.leadingAnchor.constraint(equalTo: attach.trailingAnchor, constant: 8),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            send.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 8),
            send.trailingAnchor.constraint(equalTo: trailingAnchor),
            send.bottomAnchor.constraint(equalTo: bottomAnchor),
            send.widthAnchor.constraint(equalToConstant: Self.button),
            send.heightAnchor.constraint(equalToConstant: Self.button),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -10),
            // on the send button's top corner, as a badge.
            network.centerXAnchor.constraint(equalTo: send.trailingAnchor, constant: -4),
            network.centerYAnchor.constraint(equalTo: send.topAnchor, constant: 4),
            network.widthAnchor.constraint(equalToConstant: 18),
            network.heightAnchor.constraint(equalToConstant: 18),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -2),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 9),
            placeholder.centerYAnchor.constraint(equalTo: textView.centerYAnchor),
            height,
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The network a message goes through, a badge on the send button; nil shows none.
    func showSendNetwork(_ image: UIImage?, name: String?) {
        network.image = image
        network.isHidden = image == nil || showsEye
        network.accessibilityLabel = name.map { String(localized: "Sends through \($0)") }
        network.isAccessibilityElement = image != nil
    }

    /// Shows what sending will do: answer or change the message `detail` shows.
    func setMode(symbol: String, title: String, detail: String) {
        modeBar.show(symbol: symbol, title: title, detail: detail)
        UIView.animate(withDuration: 0.2) {
            self.modeBar.isHidden = false
            self.superview?.layoutIfNeeded()
        }
    }

    // MARK: An AI action's result, in place

    /// An AI action works on the text: the bar says so, the text waits as it is and cannot be
    /// changed meanwhile.
    func beginReview(symbol: String, title: String) {
        reviewed = textView.text
        textView.isEditable = false
        reviewBar.showWorking(symbol: symbol, title: title)
        send.isEnabled = false
        UIView.animate(withDuration: 0.2) {
            self.reviewBar.isHidden = false
            self.superview?.layoutIfNeeded()
        }
    }

    /// The result over the text (`runs`: removed struck through, added marked), ✓ when there is
    /// something to apply; or `note` in the bar (a note, no mistakes, why there is none).
    func showReview(_ runs: [TextActionChange], canApply: Bool, note: String?) {
        guard reviewed != nil, reviewTask?.isCancelled == false else { return }
        if canApply, let font = textView.font { textView.attributedText = Self.review(runs, font: font) }
        reviewBar.showResult(note: note, canApply: canApply)
        refresh()
        send.isEnabled = false
    }

    /// Ends the review: the text as written (✕), or `new` in its place as one edit Undo takes
    /// back (✓).
    func endReview(applying new: String?) {
        guard let original = reviewed else { return }
        reviewed = nil
        reviewTask?.cancel()
        reviewTask = nil
        textView.isEditable = true
        textView.text = original
        restyle()
        if let new { replaceText(with: new) } else { refresh() }
        UIView.animate(withDuration: 0.2) {
            self.reviewBar.isHidden = true
            self.superview?.layoutIfNeeded()
        }
    }

    /// The runs as text: kept as it is, removed struck through in grey, added softly marked.
    private static func review(_ runs: [TextActionChange], font: UIFont) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
            switch run.kind {
            case .kept: break
            case .removed:
                attributes[.foregroundColor] = UIColor.secondaryLabel
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case .added:
                attributes[.backgroundColor] = UIColor.tintColor.withAlphaComponent(0.24)
            }
            text.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return text
    }

    func clearMode() {
        guard !modeBar.isHidden else { return }
        UIView.animate(withDuration: 0.2) {
            self.modeBar.isHidden = true
            self.superview?.layoutIfNeeded()
        }
    }

    func focus() { textView.becomeFirstResponder() }

    // MARK: The +'s panel

    /// What shows in the keyboard's place: the +'s panel, or nil for the keyboard. The + is a ×
    /// while it shows.
    var inputPanel: UIView? {
        get { textView.inputView }
        set {
            guard newValue !== textView.inputView else { return }
            textView.inputView = newValue
            let open = newValue != nil
            backToKeyboard.isEnabled = open
            attach.configuration?.image = UIImage(systemName: open ? "xmark" : "plus", withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))
            attach.accessibilityLabel = open ? String(localized: "Close") : String(localized: "Attach")
            if textView.isFirstResponder {
                textView.reloadInputViews()
            } else if open {
                textView.becomeFirstResponder()
            }
        }
    }

    /// The ×: the keyboard takes the panel's place again.
    func closePanel() {
        inputPanel = nil
    }

    /// The last keyboard's height (with the home indicator's band): the panel takes it, so the
    /// switch between them does not move the composer. Before any keyboard showed, an iPhone's
    /// portrait keyboard with its suggestions bar.
    private(set) static var keyboardHeight: CGFloat = 336

    @objc private func keyboardWillShow(_ notification: Notification) {
        // the panel's own showing is not the keyboard's.
        guard textView.isFirstResponder, textView.inputView == nil,
              let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, frame.height > 0
        else { return }
        Self.keyboardHeight = frame.height
    }

    @objc private func showKeyboard() {
        inputPanel = nil
    }

    /// The tap that brings the keyboard back is the text view's only one: no edit menu with it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer.view === textView
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        inputPanel = nil
    }

    /// Puts `new` in place of the whole text as the user's own edit: Undo takes it back, and it
    /// is kept as the draft (`onTextChange`).
    func replaceText(with new: String) {
        guard let all = textView.textRange(from: textView.beginningOfDocument, to: textView.endOfDocument) else { return }
        textView.replace(all, withText: new)
        // `replace` says nothing to the delegate when the view is not editing.
        if !textView.isFirstResponder { textViewDidChange(textView) }
    }

    func textViewDidChange(_ textView: UITextView) {
        restyle()
        refresh()
        updateMentionQuery()
        onTextChange?(textView.text)
    }

    /// An edit that cuts into a pill takes the whole pill: it is replaced over the pill's run.
    func textView(_ textView: UITextView, shouldChangeTextInRanges ranges: [NSValue], replacementText text: String) -> Bool {
        let range = ranges.map(\.rangeValue).reduce(ranges.first?.rangeValue ?? NSRange()) { NSUnionRange($0, $1) }
        let whole = ComposerPills.expanded(range, in: textView.textStorage)
        guard whole != range else { return true }
        // through the text input, so undo takes it back as one.
        replace(whole, with: text)
        return false
    }

    /// The caret never rests inside a pill, and what is typed after one is plain text.
    func textViewDidChangeSelection(_ textView: UITextView) {
        let selection = textView.selectedRange
        if selection.length == 0 {
            let moved = ComposerPills.expanded(selection, in: textView.textStorage)
            if moved != selection {
                textView.selectedRange = moved
                return
            }
        }
        textView.typingAttributes = baseAttributes
        updateMentionQuery()
    }

    /// The `@` and the word before the caret, unless a pill holds the `@`.
    private func updateMentionQuery() {
        let selection = textView.selectedRange
        var query: MentionQuery?
        if selection.length == 0, textView.markedTextRange == nil,
           let found = ComposedText.mentionQuery(in: textView.text, cursor: selection.location),
           !ComposerPills.ranges(in: textView.textStorage).contains(where: { NSIntersectionRange($0, found.range).length > 0 }) {
            query = found
        }
        guard query != mentionQuery else { return }
        mentionQuery = query
        onMentionQuery?(query)
    }

    /// A photo, a video or a file goes with the message; text pastes as the text view pastes it.
    func textPasteConfigurationSupporting(_ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
                                          transform item: UITextPasteItem) {
        guard PastedItems.attachableType(of: item.itemProvider.registeredTypeIdentifiers) != nil else { return item.setDefaultResult() }
        onPasteItems?([item.itemProvider])
        item.setNoResult()
    }

    // MARK: Formatting

    /// Shows the Markdown formatted: bold as bold, code in a fixed-width font, the marks dimmed.
    /// Only attributes change, so the text, the cursor and undo stay as they are.
    private func restyle() {
        guard let font = textView.font else { return }
        let storage = textView.textStorage
        let all = NSRange(location: 0, length: storage.length)
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
        let pills = ComposerPills.marks(in: storage)
        storage.beginEditing()
        storage.setAttributes(base, range: all)
        ComposerPills.mark(storage, pills)
        for run in Markdown.runs(in: textView.text) where NSMaxRange(run.range) <= storage.length {
            switch run.kind {
            case .bold: Self.add(.traitBold, to: storage, in: run.range)
            case .italic: Self.add(.traitItalic, to: storage, in: run.range)
            case .strikethrough: storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: run.range)
            case .code, .codeBlock:
                storage.addAttributes([.font: UIFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular),
                                       .backgroundColor: UIColor.tertiarySystemFill], range: run.range)
            case .quote: storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: run.range)
            case .mark: storage.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel, range: run.range)
            }
        }
        ComposerPills.style(storage, tint: tintColor)
        storage.endEditing()
        textView.typingAttributes = base
    }

    private static func add(_ traits: UIFontDescriptor.SymbolicTraits, to storage: NSTextStorage, in range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            guard let font = value as? UIFont,
                  let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)) else { return }
            storage.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: run)
        }
    }

    /// A selection's menu gets Format: bold, italic, strikethrough, code.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard range.length > 0 else { return UIMenu(children: suggestedActions) }
        let formats: [(String, String, String)] = [
            (String(localized: "Bold"), "bold", Markdown.boldMark),
            (String(localized: "Italic"), "italic", Markdown.italicMark),
            (String(localized: "Strikethrough"), "strikethrough", Markdown.strikethroughMark),
            (String(localized: "Code"), "chevron.left.forwardslash.chevron.right", Markdown.codeMark),
        ]
        let format = UIMenu(title: String(localized: "Format"), image: UIImage(systemName: "textformat"), children: formats.map { title, symbol, mark in
            UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in self?.toggle(mark) }
        })
        return UIMenu(children: [format] + suggestedActions)
    }

    private func toggle(_ mark: String) {
        // a pill is not cut by marks: they go around its whole run, and the text between them
        // (its pills) stays as it is.
        let selection = ComposerPills.expanded(textView.selectedRange, in: textView.textStorage)
        let before = (textView.text as NSString).length
        let changed = Markdown.toggle(mark, in: textView.text, selection: selection)
        let length = (mark as NSString).length
        if (changed.text as NSString).length > before {
            replace(NSRange(location: NSMaxRange(selection), length: 0), with: mark)
            replace(NSRange(location: selection.location, length: 0), with: mark)
        } else {
            replace(NSRange(location: NSMaxRange(selection), length: length), with: "")
            replace(NSRange(location: selection.location - length, length: length), with: "")
        }
        textView.selectedRange = changed.selection
        textViewDidChange(textView)
    }

    /// Replaces `range` through the text input: undo takes it back.
    private func replace(_ range: NSRange, with text: String) {
        guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
              let end = textView.position(from: start, offset: range.length),
              let span = textView.textRange(from: start, to: end) else { return }
        textView.replace(span, withText: text)
    }

    private func refresh() {
        let empty = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholder.isHidden = !textView.text.isEmpty
        updateButton()
        send.isEnabled = !empty || showsEye || !attachments.isEmpty
        // grow to eight lines, then scroll.
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        let maximum = (textView.font ?? .preferredFont(forTextStyle: .body)).lineHeight * 8 + 14
        textView.isScrollEnabled = fitting > maximum
        let new = min(max(fitting, 36), maximum)
        guard new != height.constant else { return }
        height.constant = new
        UIView.animate(withDuration: 0.15) { self.superview?.layoutIfNeeded() }
    }

    /// Shows the eye while nothing is written, if the chat has messages the receipt does not cover.
    func setNeedsReadReceipt(_ needed: Bool) {
        needsReadReceipt = needed
        refresh()
    }

    private func updateButton() {
        let eye = needsReadReceipt && textView.text.isEmpty && attachments.isEmpty
        send.menu = eye ? readReceiptsMenu : sendLaterMenu
        // the network a message goes through, on the send button only (not on the eye).
        network.isHidden = eye || network.image == nil
        guard eye != showsEye || send.configuration?.image == nil else { return }
        showsEye = eye
        let symbol = eye ? "eye" : "arrow.up"
        send.configuration?.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(weight: .bold))
        send.accessibilityLabel = eye ? String(localized: "Send Read Receipt") : String(localized: "Send")
        send.accessibilityHint = eye ? String(localized: "Hold for how this chat sends read receipts") : nil
    }

    private func primary() {
        if showsEye { onReadReceipt?() } else { submit() }
    }

    private func submit() {
        onSend?(composed)
        composed = ""
    }
}

/// "Replying to Anna — hi there" / "Editing — old text", with a button that cancels.
/// An AI action above the composer's text: its name, working (a spinner), then its result's ✓
/// and ✕ on the right, all in one plain box.
private final class ReviewBar: UIView {
    /// Its gap from the composer's glass, the same all round.
    static let gap: CGFloat = 6
    var onAccept: (() -> Void)?
    var onReject: (() -> Void)?
    private let icon = UIImageView()
    private let title = UILabel()
    private let note = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private lazy var accept = Self.button("checkmark", label: String(localized: "Apply"), color: .label) { [weak self] in self?.onAccept?() }
    private lazy var reject = Self.button("xmark", label: String(localized: "Cancel"), color: .secondaryLabel) { [weak self] in self?.onReject?() }
    /// The two side by side.
    private let capsule = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: font)
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        title.font = font.bold
        title.textColor = .label
        title.adjustsFontForContentSizeCategory = true
        note.font = .preferredFont(forTextStyle: .footnote)
        note.textColor = .secondaryLabel
        note.numberOfLines = 0
        spinner.hidesWhenStopped = true
        let buttons = UIStackView(arrangedSubviews: [accept, reject])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 4),
            buttons.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -4),
            buttons.topAnchor.constraint(equalTo: capsule.topAnchor),
            buttons.bottomAnchor.constraint(equalTo: capsule.bottomAnchor),
        ])
        let labels = UIStackView(arrangedSubviews: [title, note])
        labels.axis = .vertical
        labels.spacing = 1
        // the name takes the room; the capsule keeps to the right.
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [icon, labels, spinner, capsule])
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        // the name and its buttons in one box: a plain fill, as the composer around it is glass.
        let box = UIView()
        box.backgroundColor = .secondarySystemFill
        // concentric with the composer's glass, the same gap all round: the system takes the
        // radius from the container. The composer's rows sit 10 in and 2 down; the box reaches
        // out to the gap.
        box.cornerConfiguration = .uniformCorners(radius: .containerConcentric(minimum: 12))
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        box.addSubview(row)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.gap - 10),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 10 - Self.gap),
            box.topAnchor.constraint(equalTo: topAnchor, constant: Self.gap - 2),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: box.topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -5),
            icon.widthAnchor.constraint(equalToConstant: 22),
        ])
        icon.setContentHuggingPriority(.required, for: .horizontal)
        capsule.setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static func button(_ symbol: String, label: String, color: UIColor, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium).applying(UIImage.SymbolConfiguration(weight: .semibold)))
        configuration.baseForegroundColor = color
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 32),
        ])
        return button
    }

    func showWorking(symbol: String, title: String) {
        icon.image = UIImage(systemName: symbol)
        self.title.text = title
        note.text = nil
        note.isHidden = true
        spinner.startAnimating()
        accept.isHidden = true
        accessibilityLabel = title
    }

    func showResult(note text: String?, canApply: Bool) {
        spinner.stopAnimating()
        note.text = text
        note.isHidden = text == nil
        accept.isHidden = !canApply
    }
}

private final class ModeBar: UIView {
    var onCancel: (() -> Void)?
    private let icon = UIImageView()
    private let title = UILabel()
    private let detail = UILabel()
    private lazy var cancel = UIButton(primaryAction: UIAction { [weak self] _ in self?.onCancel?() })

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.tintColor = .tintColor
        icon.contentMode = .scaleAspectFit
        title.font = .preferredFont(forTextStyle: .caption1).bold
        title.textColor = .tintColor
        detail.font = .preferredFont(forTextStyle: .caption1)
        detail.textColor = .secondaryLabel
        cancel.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        cancel.tintColor = .tertiaryLabel
        cancel.accessibilityLabel = String(localized: "Cancel")
        let labels = UIStackView(arrangedSubviews: [title, detail])
        labels.axis = .vertical
        let row = UIStackView(arrangedSubviews: [icon, labels, cancel])
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            icon.widthAnchor.constraint(equalToConstant: 18),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(symbol: String, title: String, detail: String) {
        icon.image = UIImage(systemName: symbol)
        self.title.text = title
        self.detail.text = detail
        accessibilityLabel = "\(title), \(detail)"
    }
}

/// The composer's text: Paste (the menu's and ⌘V) is offered, and pastes, also when the pasteboard
/// holds only a picture, a video or a file. A plain text view offers it for text alone, whatever
/// its `pasteConfiguration` takes, so they never reached its paste delegate; with text among them,
/// the text view pastes as it does and its delegate takes the rest.
final class ComposerTextView: UITextView {
    /// The pasteboard pastes come from: the system's, or one of a test's.
    var pasteboard = UIPasteboard.general
    var onPasteItems: (([NSItemProvider]) -> Void)?

    /// Only the pasteboard's types are read, which asks the user nothing.
    private var hasOnlyAttachables: Bool {
        !pasteboard.hasStrings && PastedItems.attachableType(of: pasteboard.types) != nil
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), isEditable, hasOnlyAttachables { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        guard hasOnlyAttachables else { return super.paste(sender) }
        onPasteItems?(pasteboard.itemProviders)
    }
}
