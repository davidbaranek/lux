import UIKit

/// The app's text field: filled, rounded, with a symbol before the text, at least 48 points tall,
/// as signing in and the networks' forms show them. A PIN or code shows large, centred and
/// spaced, without the symbol.
final class FilledTextField: UITextField {
    enum Look {
        /// A line of text after `symbol`.
        case text(symbol: String)
        /// A short code of digits (a PIN, a two-factor code).
        case code
    }

    init(placeholder: String, look: Look) {
        super.init(frame: .zero)
        self.placeholder = placeholder
        adjustsFontForContentSizeCategory = true
        autocapitalizationType = .none
        autocorrectionType = .no
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        switch look {
        case .text(let symbol):
            font = .preferredFont(forTextStyle: .body)
            // the symbol in a fixed box: the field sizes its left view, so the box keeps the gaps.
            let icon = UIImageView(image: UIImage(systemName: symbol))
            icon.tintColor = .secondaryLabel
            icon.contentMode = .scaleAspectFit
            icon.translatesAutoresizingMaskIntoConstraints = false
            let box = UIView()
            box.addSubview(icon)
            NSLayoutConstraint.activate([
                box.widthAnchor.constraint(equalToConstant: 44),
                icon.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 20),
                icon.heightAnchor.constraint(equalToConstant: 20),
            ])
            leftView = box
            leftViewMode = .always
            heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        case .code:
            font = UIFontMetrics(forTextStyle: .title1).scaledFont(for: .monospacedDigitSystemFont(ofSize: 28, weight: .semibold))
            textAlignment = .center
            keyboardType = .numberPad
            defaultTextAttributes[.kern] = 8
            heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
