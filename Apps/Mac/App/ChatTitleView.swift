import AppKit
import LuxCore

/// The open chat's title in the toolbar: its picture, its name and under it the networks (or
/// that it is a group). Nothing shows while no chat is open.
final class ChatTitleView: NSStackView {
    private static let pictureSide: CGFloat = 28
    private let picture = AvatarView(side: pictureSide)
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let lines = NSStackView(views: [name, detail])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 0
        picture.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            picture.widthAnchor.constraint(equalToConstant: Self.pictureSide),
            picture.heightAnchor.constraint(equalToConstant: Self.pictureSide),
        ])
        // the name and the networks keep their width; the toolbar's space gives way first.
        for label in [name, detail] {
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }
        setViews([picture, lines], in: .leading)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        isHidden = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Starts the picture at `x` in the window, where the chat's messages start below: the space
    /// before it grows or shrinks by the picture's distance from there, measured where the picture
    /// is now (wherever the toolbar put the view), so lining up again moves nothing.
    func lineUp(at x: CGFloat) {
        layoutSubtreeIfNeeded()
        let start = picture.convert(NSPoint.zero, to: nil).x
        let inset = max(0, edgeInsets.left + x - start).rounded()
        guard abs(edgeInsets.left - inset) >= 1 else { return }
        edgeInsets.left = inset
    }

    /// Shows `row`'s picture and name; nil shows nothing.
    func show(_ row: ChatRow?, images: ImagePipeline?) {
        isHidden = row == nil
        guard let row else { return }
        picture.show(row.avatar, name: row.name, members: row.memberAvatars, images: images)
        name.stringValue = row.name
        updateAccessibility()
    }

    /// The networks a merged chat shows, or that it is a group; empty hides the line.
    var subtitle: String {
        get { detail.stringValue }
        set {
            detail.stringValue = newValue
            detail.isHidden = newValue.isEmpty
            updateAccessibility()
        }
    }

    private func updateAccessibility() {
        setAccessibilityLabel([name.stringValue, detail.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}
