import LuxCore
import UIKit

/// An AI action's sheet over the chat: working while the model answers, then the result over the
/// text written (what is removed struck through, what is added marked) with Apply, or a note, or
/// why there is none. It shows any action's result alike: how it looks follows from its kind.
final class TextActionSheet: UIViewController {
    private let action: TextAction
    private let original: String
    private let apply: (String) -> Void
    private let preview = UITextView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let message = UILabel()
    private lazy var applyButton = UIBarButtonItem(title: String(localized: "Apply"), style: .prominent, target: self,
                                                   action: #selector(applyTapped))
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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        applyButton.isEnabled = false
        navigationItem.rightBarButtonItem = applyButton
        preview.isEditable = false
        preview.font = .preferredFont(forTextStyle: .body)
        preview.adjustsFontForContentSizeCategory = true
        preview.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        preview.isHidden = true
        message.numberOfLines = 0
        message.textAlignment = .center
        message.font = .preferredFont(forTextStyle: .body)
        message.textColor = .secondaryLabel
        message.isHidden = true
        spinner.startAnimating()
        for subview in [preview, spinner, message] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            preview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            message.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])
    }

    /// The model's answer: shown over the text, Apply when there is something to apply.
    func show(_ result: TextActionResult) {
        spinner.stopAnimating()
        applied = result.applied(to: original)
        applyButton.isEnabled = applied != nil
        if case .corrections(let corrections) = result, corrections.isEmpty {
            return show(message: String(localized: "No mistakes found."))
        }
        preview.attributedText = Self.attributed(result.preview(of: original))
        preview.isHidden = false
    }

    /// Why there is no answer.
    func show(message text: String) {
        spinner.stopAnimating()
        message.text = text
        message.isHidden = false
        applyButton.isEnabled = false
    }

    @objc private func applyTapped() {
        guard let applied else { return }
        apply(applied)
        dismiss(animated: true)
    }

    /// The preview's runs as text: kept as it is, removed struck through in red, added in green.
    private static func attributed(_ runs: [TextActionChange]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let body = UIFont.preferredFont(forTextStyle: .body)
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: UIColor.label]
            switch run.kind {
            case .kept: break
            case .removed:
                attributes[.foregroundColor] = UIColor.systemRed
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case .added:
                attributes[.foregroundColor] = UIColor.systemGreen
                attributes[.backgroundColor] = UIColor.systemGreen.withAlphaComponent(0.12)
            }
            text.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return text
    }
}
