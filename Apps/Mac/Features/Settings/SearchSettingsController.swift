import AppKit
import LuxCore

/// Search: the index on this Mac (messages, and the photos read for their words), and whether
/// photos are found by what they show too, by a model that reads them on this Mac.
final class SearchSettingsController: NSViewController {
    private let model: SettingsModel
    private let index = NSTextField(labelWithString: "")
    private let photos = NSTextField(labelWithString: "")
    private lazy var looks = NSButton(checkboxWithTitle: String(localized: "Find photos by what they show"), target: self,
                                      action: #selector(looksChanged))
    private let looksNote = NSTextField(wrappingLabelWithString: "")
    private var observation: AnyObject?

    private static let looksAbout = String(localized: """
        Photos are always found by the words in them and the messages sent with them. This also finds them by what \
        they show ("dog on the beach"). It downloads a model of about 450 MB and reads the photos on this Mac, in \
        the background. Nothing leaves this Mac.
        """)

    init(model: SettingsModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Search")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        looksNote.textColor = .secondaryLabelColor
        looksNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        looksNote.preferredMaxLayoutWidth = 340
        view = settingsForm([
            [NSTextField(labelWithString: String(localized: "Index:")), index],
            [NSGridCell.emptyContentView, photos],
            [NSTextField(labelWithString: String(localized: "Photos:")), looks],
            [NSGridCell.emptyContentView, looksNote],
        ])
        observation = model.changes.observe { [weak self] in self?.update() }
        update()
    }

    private func update() {
        index.stringValue = model.searchIndex ?? String(localized: "Opening…")
        photos.stringValue = model.photosRead ?? ""
        photos.isHidden = model.photosRead == nil
        looks.state = model.searchesPhotosByLook ? .on : .off
        looksNote.stringValue = model.photoLooksStatus ?? Self.looksAbout
    }

    @objc private func looksChanged() {
        let on = looks.state == .on
        Task { await model.setSearchesPhotosByLook(on) }
    }
}
