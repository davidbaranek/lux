import LuxCore
import UIKit
import UniformTypeIdentifiers

/// A growing text view and a send button on Liquid Glass, with a bar above the text when it
/// answers or edits a message. While nothing is written and the chat has unread messages, the
/// button is an eye that sends a read receipt; holding it shows `readReceiptsMenu`. The text is
/// Markdown, shown formatted as it is typed (the marks dimmed); a selection's menu has Format.
/// A pasted or dropped photo, video or file waits in it as one picked with the + does.
final class ComposerView: UIView, UITextViewDelegate, UITextPasteDelegate, UIGestureRecognizerDelegate {
    /// The round buttons beside the field, and the field's one-line height: as Messages has them.
    static let button: CGFloat = 40

    var onSend: ((String) -> Void)?
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
    var text: String {
        get { textView.text }
        set {
            textView.text = newValue
            restyle()
            refresh()
        }
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

    func textViewDidChange(_ textView: UITextView) {
        restyle()
        refresh()
        onTextChange?(textView.text)
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
        storage.beginEditing()
        storage.setAttributes(base, range: all)
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
        let changed = Markdown.toggle(mark, in: textView.text, selection: textView.selectedRange)
        textView.text = changed.text
        textView.selectedRange = changed.selection
        textViewDidChange(textView)
    }

    private func refresh() {
        let empty = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholder.isHidden = !textView.text.isEmpty
        updateButton()
        send.isEnabled = !empty || showsEye || !attachments.isEmpty
        // grow to five lines, then scroll.
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        let maximum = (textView.font ?? .preferredFont(forTextStyle: .body)).lineHeight * 5 + 14
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
        onSend?(textView.text)
        text = ""
    }
}

/// "Replying to Anna — hi there" / "Editing — old text", with a button that cancels.
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
