import LuxCore
import UIKit

/// A note over the chat's top of a message pinned since the user last saw the chat's pins (on any
/// of their devices). A tap goes to it; the close button puts it away. Either way the pins are
/// seen, and the note stays away until another message is pinned. The chat's details list all
/// its pinned messages.
final class NewPinBar: UIView {
    /// Go to the pinned message.
    var onJump: ((PinnedMessage) -> Void)?
    /// The user saw the pin: went to it or closed the note.
    var onSeen: (() -> Void)?
    private let pinButton = UIButton(configuration: .glass())
    private let closeButton = UIButton(configuration: .glass())
    private var pin: PinnedMessage?

    init() {
        super.init(frame: .zero)
        var pinConfiguration = UIButton.Configuration.glass()
        pinConfiguration.image = UIImage(systemName: "pin.fill")
        pinConfiguration.imagePadding = 10
        pinConfiguration.titleLineBreakMode = .byTruncatingTail
        pinConfiguration.subtitleLineBreakMode = .byTruncatingTail
        pinConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        pinButton.configuration = pinConfiguration
        pinButton.contentHorizontalAlignment = .leading
        pinButton.accessibilityHint = String(localized: "Goes to the message.")
        pinButton.addAction(UIAction { [weak self] _ in self?.jump() }, for: .primaryActionTriggered)

        var closeConfiguration = UIButton.Configuration.glass()
        closeConfiguration.image = UIImage(systemName: "xmark")
        closeConfiguration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
        closeConfiguration.cornerStyle = .capsule
        closeButton.configuration = closeConfiguration
        closeButton.accessibilityLabel = String(localized: "Close")
        closeButton.accessibilityHint = String(localized: "Hides the newly pinned message.")
        closeButton.addAction(UIAction { [weak self] _ in self?.close() }, for: .primaryActionTriggered)

        let row = UIStackView(arrangedSubviews: [pinButton, closeButton])
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            closeButton.widthAnchor.constraint(equalTo: closeButton.heightAnchor),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        isHidden = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Tells of `pin`, the newest the user has not seen, or hides when there is none.
    func show(_ pin: PinnedMessage?) {
        self.pin = pin
        isHidden = pin == nil
        guard let pin else { return }
        var title = AttributedString(String(localized: "New Pinned Message"))
        title.font = .preferredFont(forTextStyle: .caption1).bold
        title.foregroundColor = .tintColor
        var subtitle = AttributedString(pin.text.isEmpty ? pin.senderName : "\(pin.senderName): \(pin.text)")
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        pinButton.configuration?.attributedTitle = title
        pinButton.configuration?.attributedSubtitle = subtitle
        pinButton.accessibilityLabel = String(localized: "New pinned message from \(pin.senderName): \(pin.text)")
    }

    private func jump() {
        guard let pin else { return }
        onJump?(pin)
        close()
    }

    private func close() {
        show(nil)
        onSeen?()
    }
}
