import AppKit
import LuxCore

/// The members a mention's word offers, above the composer on glass: their picture, name and user
/// id, the best match first, at most five rows tall (the rest scroll). The first is selected; the
/// arrow keys move the selection (`move(by:)`) and Return or Tab picks it, as the composer's text
/// view asks; a click picks a row.
final class MentionSuggestionsView: NSGlassEffectView, NSTableViewDelegate {
    var onPick: ((MentionSuggestion) -> Void)?
    var images: ImagePipeline?
    /// What shows, in order.
    private(set) var suggestions: [MentionSuggestion] = []
    private static let row: CGFloat = 40
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var dataSource: NSTableViewDiffableDataSource<Int, MentionSuggestion>?
    private lazy var height = heightAnchor.constraint(equalToConstant: 0)

    override init(frame: NSRect) {
        super.init(frame: frame)
        cornerRadius = 14
        isHidden = true
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("member")))
        table.headerView = nil
        table.rowHeight = Self.row
        table.backgroundColor = .clear
        table.style = .plain
        table.intercellSpacing = .zero
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.setAccessibilityIdentifier("mention suggestions")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
        ])
        contentView = content
        height.isActive = true
        dataSource = NSTableViewDiffableDataSource(tableView: table) { [weak self] table, _, _, suggestion in
            let cell = table.makeView(withIdentifier: SuggestionCell.reuse, owner: nil) as? SuggestionCell ?? SuggestionCell()
            cell.show(suggestion, images: self?.images)
            return cell
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Shows `suggestions`, the first selected; none hides the list.
    func show(_ suggestions: [MentionSuggestion]) {
        guard suggestions != self.suggestions else { return }
        self.suggestions = suggestions
        var snapshot = NSDiffableDataSourceSnapshot<Int, MentionSuggestion>()
        snapshot.appendSections([0])
        snapshot.appendItems(suggestions)
        dataSource?.apply(snapshot, animatingDifferences: false)
        height.constant = CGFloat(min(suggestions.count, 5)) * Self.row + 8
        isHidden = suggestions.isEmpty
        if !suggestions.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    /// The suggestion Return would pick.
    var selected: MentionSuggestion? {
        suggestions.indices.contains(table.selectedRow) ? suggestions[table.selectedRow] : nil
    }

    /// Moves the selection up (-1) or down (1), not past the ends.
    func move(by step: Int) {
        guard !suggestions.isEmpty else { return }
        let row = min(max(table.selectedRow + step, 0), suggestions.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clicked() {
        guard suggestions.indices.contains(table.clickedRow) else { return }
        onPick?(suggestions[table.clickedRow])
    }
}

/// A suggestion's row: the picture (a megaphone for `@room`), the name, the user id under it.
private final class SuggestionCell: NSTableCellView {
    static let reuse = NSUserInterfaceItemIdentifier("mention suggestion")
    private let avatar = AvatarView(side: 28)
    private let symbol = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuse
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        symbol.contentTintColor = .controlAccentColor
        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        for view in [avatar, symbol, labels] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            labels.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ suggestion: MentionSuggestion, images: ImagePipeline?) {
        switch suggestion {
        case .member(let member):
            avatar.isHidden = false
            symbol.isHidden = true
            avatar.show(member.avatar, name: member.name, images: images)
            name.stringValue = member.name
            detail.stringValue = member.id
        case .room:
            avatar.isHidden = true
            symbol.isHidden = false
            symbol.image = NSImage(systemSymbolName: "megaphone.fill", accessibilityDescription: nil)
            name.stringValue = "@room"
            detail.stringValue = String(localized: "Notify everyone in this chat")
        }
        setAccessibilityLabel("\(name.stringValue), \(detail.stringValue)")
    }
}
