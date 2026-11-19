import LuxCore
import UIKit

/// The chat's pinned messages, in a bar over its top: one at a time, the newest pinned first.
/// A tap goes to it and shows the one pinned before it (round again after the oldest); a long
/// press lists them all, to go to any. Hidden while none is pinned.
final class PinnedBar: UIButton {
    /// Go to a pinned message.
    var onJump: ((PinnedMessage) -> Void)?
    private var pinned: [PinnedMessage] = []
    /// The one shown, counted from the newest.
    private var shown = 0

    init() {
        var configuration = UIButton.Configuration.glass()
        configuration.image = UIImage(systemName: "pin.fill")
        configuration.imagePadding = 10
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.subtitleLineBreakMode = .byTruncatingTail
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        super.init(frame: .zero)
        self.configuration = configuration
        contentHorizontalAlignment = .leading
        isHidden = true
        addAction(UIAction { [weak self] _ in self?.jump() }, for: .primaryActionTriggered)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Shows `pinned` (in the order they were pinned): a message just pinned first, else the one
    /// shown while it stays pinned.
    func show(_ pinned: [PinnedMessage]) {
        let current = self.pinned.reversed().dropFirst(shown).first
        let newlyPinned = pinned.last.map { !self.pinned.contains($0) } ?? false
        self.pinned = pinned
        shown = newlyPinned ? 0 : current.flatMap { current in Array(pinned.reversed()).firstIndex(of: current) } ?? 0
        isHidden = pinned.isEmpty
        update()
        menu = UIMenu(title: String(localized: "Pinned Messages"), children: pinned.reversed().map { pin in
            UIAction(title: pin.text.isEmpty ? pin.senderName : pin.text, subtitle: pin.senderName,
                     image: UIImage(systemName: "pin")) { [weak self] _ in self?.onJump?(pin) }
        })
    }

    private func update() {
        let newestFirst = Array(pinned.reversed())
        guard let pin = newestFirst.indices.contains(shown) ? newestFirst[shown] : nil else { return }
        var title = AttributedString(newestFirst.count > 1
            ? String(localized: "Pinned Message \(shown + 1) of \(newestFirst.count)")
            : String(localized: "Pinned Message"))
        title.font = .preferredFont(forTextStyle: .caption1).bold
        title.foregroundColor = .tintColor
        var subtitle = AttributedString(pin.text.isEmpty ? pin.senderName : "\(pin.senderName): \(pin.text)")
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        configuration?.attributedTitle = title
        configuration?.attributedSubtitle = subtitle
        accessibilityLabel = String(localized: "Pinned message from \(pin.senderName): \(pin.text)")
        accessibilityHint = String(localized: "Goes to the message. Hold to see all pinned messages.")
    }

    private func jump() {
        let newestFirst = Array(pinned.reversed())
        guard newestFirst.indices.contains(shown) else { return }
        onJump?(newestFirst[shown])
        shown = (shown + 1) % newestFirst.count
        update()
    }
}
