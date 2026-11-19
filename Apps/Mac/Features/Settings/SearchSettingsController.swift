import AppKit
import LuxCore

/// Search: the index on this Mac (messages, and the photos read for their words), and semantic
/// search: photos found by what they show and messages by what they mean, by a model on this Mac.
final class SearchSettingsController: NSViewController {
    private let model: SettingsModel
    private let index = NSTextField(labelWithString: "")
    /// How far back each chat is read.
    private lazy var history = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Where the photos stand now, with a spinner while they are read.
    private let photoStatus = NSTextField(labelWithString: "")
    private let photoSpinner = NSProgressIndicator()
    /// Stop, or read the waiting photos now; hidden when there is nothing to do.
    private lazy var photoAction = NSButton(title: "", target: self, action: #selector(photoActionClicked))
    private lazy var looks = NSButton(checkboxWithTitle: String(localized: "Semantic search"), target: self,
                                      action: #selector(looksChanged))
    /// Where the model is, under its checkbox while it is on: downloading (with its progress),
    /// being prepared, ready, or why it could not be had, with Try Again.
    private let modelStatus = NSTextField(wrappingLabelWithString: "")
    private let modelProgress = NSProgressIndicator()
    private lazy var modelState = NSStackView(views: [modelProgress, modelStatus])
    private lazy var modelRetry = NSButton(title: String(localized: "Try Again"), target: self, action: #selector(retryModel))
    private let looksNote = NSTextField(wrappingLabelWithString: "")
    private var observation: AnyObject?

    private static let looksAbout = String(localized: """
        Search always finds words. This also finds photos by what they show ("dog on the beach") and messages by \
        what they mean ("trip to the mountains"), with a model of about 650 MB read on this Mac. Nothing leaves \
        this Mac.
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
        looksNote.stringValue = Self.looksAbout
        photoSpinner.style = .spinning
        photoSpinner.controlSize = .small
        photoSpinner.isDisplayedWhenStopped = false
        let status = NSStackView(views: [photoStatus, photoSpinner])
        status.spacing = 6
        modelStatus.textColor = .secondaryLabelColor
        modelStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        modelStatus.preferredMaxLayoutWidth = 300
        modelProgress.style = .bar
        modelProgress.controlSize = .small
        modelProgress.minValue = 0
        modelProgress.maxValue = 1
        modelProgress.widthAnchor.constraint(equalToConstant: 80).isActive = true
        modelState.spacing = 6
        modelRetry.controlSize = .small
        // the model's state and its button go with the checkbox: hidden, they take no room.
        let semantic = NSStackView(views: [looks, modelState, modelRetry])
        semantic.orientation = .vertical
        semantic.alignment = .leading
        semantic.spacing = 6
        history.addItems(withTitles: SearchHistory.allCases.map(\.title))
        history.target = self
        history.action = #selector(historyChanged)
        view = settingsForm([
            [NSTextField(labelWithString: String(localized: "Messages:")), index],
            [NSTextField(labelWithString: String(localized: "Search back:")), history],
            [NSTextField(labelWithString: String(localized: "Photos:")), status],
            [NSGridCell.emptyContentView, photoAction],
            [NSGridCell.emptyContentView, semantic],
            [NSGridCell.emptyContentView, looksNote],
        ])
        observation = model.changes.observe { [weak self] in self?.update() }
        update()
    }

    private func update() {
        index.stringValue = model.searchIndex ?? String(localized: "Opening…")
        photoStatus.stringValue = model.photoStatus ?? String(localized: "Opening…")
        if model.isPhotoWorkUnderWay { photoSpinner.startAnimation(nil) } else { photoSpinner.stopAnimation(nil) }
        photoAction.isHidden = model.photoAction == nil
        photoAction.title = model.photoAction == .stop ? String(localized: "Stop Reading") : String(localized: "Read Waiting Photos Now")
        looks.state = model.searchesPhotosByLook ? .on : .off
        updateModel()
        // only when the choice changed: the menu stays as it is while the progress beside it moves.
        let chosen = SearchHistory.allCases.firstIndex(of: model.searchHistory) ?? 0
        if history.indexOfSelectedItem != chosen { history.selectItem(at: chosen) }
    }

    /// The model's line: its words, a bar while it downloads (moving on its own while it is
    /// prepared), and Try Again once it could not be had.
    private func updateModel() {
        let status = model.photoModelStatus
        modelState.isHidden = status == nil
        if modelStatus.stringValue != status ?? "" { modelStatus.stringValue = status ?? "" }
        switch model.photoModel {
        case .downloading(let fraction)?:
            modelProgress.isHidden = false
            modelProgress.stopAnimation(nil)
            modelProgress.isIndeterminate = false
            modelProgress.doubleValue = fraction
        case .preparing?:
            modelProgress.isHidden = false
            modelProgress.isIndeterminate = true
            modelProgress.startAnimation(nil)
        default:
            modelProgress.stopAnimation(nil)
            modelProgress.isHidden = true
        }
        modelRetry.isHidden = !model.canRetryPhotoModel
    }

    @objc private func historyChanged() {
        guard let chosen = SearchHistory.allCases[safe: history.indexOfSelectedItem] else { return }
        model.searchHistory = chosen
    }

    @objc private func photoActionClicked() {
        switch model.photoAction {
        case .stop?: Task { await model.stopReadingPhotos() }
        case .readNow?: model.readPhotosNow()
        case nil: break
        }
    }

    @objc private func looksChanged() {
        let on = looks.state == .on
        Task { await model.setSearchesPhotosByLook(on) }
    }

    @objc private func retryModel() {
        model.retryPhotoModel()
    }
}
