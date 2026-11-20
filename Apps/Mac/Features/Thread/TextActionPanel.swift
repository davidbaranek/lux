import AppKit
import LuxCore

/// An AI action's sheet over the chat: working while the model answers, then the result over the
/// text written (what is removed struck through, what is added marked) with Apply, or a note, or
/// why there is none. It shows any action's result alike: how it looks follows from its kind.
final class TextActionPanel: NSViewController {
    private let action: TextAction
    private let original: String
    private let apply: (String) -> Void
    private let preview = NSTextView()
    private lazy var scroll: NSScrollView = {
        let scroll = NSScrollView()
        scroll.documentView = preview
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        return scroll
    }()
    private let spinner = NSProgressIndicator()
    private let message = NSTextField(wrappingLabelWithString: "")
    private lazy var applyButton = NSButton(title: String(localized: "Apply"), target: self, action: #selector(applyClicked))
    private var applied: String?

    /// `action` over `original`; `apply` takes the text to put in the composer.
    init(action: TextAction, original: String, apply: @escaping (String) -> Void) {
        self.action = action
        self.original = original
        self.apply = apply
        super.init(nibName: nil, bundle: nil)
        title = action.title
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let heading = NSTextField(labelWithString: action.title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        preview.isEditable = false
        preview.drawsBackground = false
        preview.textContainerInset = NSSize(width: 4, height: 8)
        preview.autoresizingMask = [.width]
        scroll.isHidden = true
        spinner.style = .spinning
        spinner.startAnimation(nil)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.isHidden = true
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        applyButton.keyEquivalent = "\r"
        applyButton.isEnabled = false
        let buttons = NSStackView(views: [cancel, applyButton])
        let body = NSView()
        for subview in [scroll, spinner, message] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: body.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            message.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            body.heightAnchor.constraint(equalToConstant: 220),
        ])
        let stack = NSStackView(views: [heading, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        body.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -20).isActive = true
        stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
        view = stack
    }

    /// The model's answer: shown over the text, Apply when there is something to apply.
    func show(_ result: TextActionResult) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        applied = result.applied(to: original)
        applyButton.isEnabled = applied != nil
        if case .corrections(let corrections) = result, corrections.isEmpty {
            return show(message: String(localized: "No mistakes found."))
        }
        preview.textStorage?.setAttributedString(Self.attributed(result.preview(of: original)))
        scroll.isHidden = false
    }

    /// Why there is no answer.
    func show(message text: String) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        message.stringValue = text
        message.isHidden = false
        applyButton.isEnabled = false
    }

    @objc private func applyClicked() {
        guard let applied else { return }
        apply(applied)
        dismiss(nil)
    }

    @objc private func cancelClicked() {
        dismiss(nil)
    }

    /// The preview's runs as text: kept as it is, removed struck through in red, added in green.
    private static func attributed(_ runs: [TextActionChange]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize + 1)
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            switch run.kind {
            case .kept: break
            case .removed:
                attributes[.foregroundColor] = NSColor.systemRed
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case .added:
                attributes[.foregroundColor] = NSColor.systemGreen
                attributes[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.12)
            }
            text.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return text
    }
}
