import AppKit

/// A list section's heading, small and secondary, as a sidebar's groups are titled.
final class SectionHeader: NSTableCellView {
    static let reuse = NSUserInterfaceItemIdentifier("SectionHeader")
    private let label = NSTextField(labelWithString: "")
    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.reuse
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            // level with the rows' avatars (the source list insets its rows; a header is not inset).
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            // room under the title, so a selected row's highlight does not touch it.
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
