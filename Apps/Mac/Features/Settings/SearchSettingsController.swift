import AppKit
import LuxCore
import SwiftUI

/// Search: the index on this Mac (messages, and the photos read for their words), and semantic
/// search: photos found by what they show and messages by what they mean, by a model on this Mac.
final class SearchSettingsController: NSViewController, SearchablePane {
    private let model: SettingsModel
    private var observation: AnyObject?
    private lazy var form = PaneForm(makeForm())

    init(model: SettingsModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Search")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var focus: SettingsFocus { form.focus }

    override func loadView() {
        view = form.view
        observation = model.changes.observe { [weak self] in self?.update() }
    }

    private func update() {
        form.show(makeForm())
    }

    private func makeForm() -> SearchForm {
        SearchForm(
            index: model.searchIndex, history: model.searchHistory, photoStatus: model.photoStatus,
            isPhotoWorkUnderWay: model.isPhotoWorkUnderWay, photoAction: model.photoAction,
            searchesByLook: model.searchesPhotosByLook, photoModel: model.photoModel,
            photoModelStatus: model.photoModelStatus, canRetry: model.canRetryPhotoModel,
            actions: .init(
                history: { [weak self] in self?.model.searchHistory = $0 },
                photoAction: { [weak self] in
                    guard let model = self?.model else { return }
                    switch model.photoAction {
                    case .stop?: Task { await model.stopReadingPhotos() }
                    case .readNow?: model.readPhotosNow()
                    case nil: break
                    }
                },
                searchByLook: { [weak self] on in
                    guard let model = self?.model else { return }
                    Task { await model.setSearchesPhotosByLook(on) }
                },
                retry: { [weak self] in self?.model.retryPhotoModel() }
            )
        )
    }
}

/// The Search pane's form: the messages' index and how far back it reads, the photos, and
/// semantic search with where its model is.
struct SearchForm: View {
    struct Actions {
        var history: @MainActor (SearchHistory) -> Void
        var photoAction: @MainActor () -> Void
        var searchByLook: @MainActor (Bool) -> Void
        var retry: @MainActor () -> Void
    }

    let index: String?
    let history: SearchHistory
    let photoStatus: String?
    let isPhotoWorkUnderWay: Bool
    let photoAction: SettingsModel.PhotoAction?
    let searchesByLook: Bool
    let photoModel: PhotoSearch.Looks?
    let photoModelStatus: String?
    let canRetry: Bool
    let actions: Actions

    var body: some View {
        Form {
            Section {
                LabeledContent(SettingsItem.searchIndex.title, value: index ?? String(localized: "Opening…"))
                    .settingsRow(.searchIndex)
                Picker(SettingsItem.searchBack.title, selection: Binding(get: { history }, set: actions.history)) {
                    ForEach(SearchHistory.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .settingsRow(.searchBack)
            }
            Section {
                LabeledContent(SettingsItem.photos.title) {
                    HStack {
                        if isPhotoWorkUnderWay { ProgressView().controlSize(.small) }
                        Text(photoStatus ?? String(localized: "Opening…"))
                    }
                }
                .settingsRow(.photos)
                if let photoAction {
                    HStack {
                        Spacer()
                        Button(photoAction == .stop ? String(localized: "Stop Reading") : String(localized: "Read Waiting Photos Now"),
                               action: actions.photoAction)
                    }
                }
            }
            Section {
                Toggle(isOn: Binding(get: { searchesByLook }, set: actions.searchByLook)) { settingsLabel(.semanticSearch) }
                    .settingsRow(.semanticSearch)
                // where the model is while semantic search is on: downloading (with its
                // progress), being prepared, ready, or why it could not be had, with Try Again.
                if let photoModelStatus {
                    HStack {
                        Text(photoModelStatus).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        switch photoModel {
                        case .downloading(let fraction)?: ProgressView(value: fraction).frame(width: 100)
                        case .preparing?: ProgressView().progressViewStyle(.linear).frame(width: 100)
                        default: EmptyView()
                        }
                        if canRetry { Button(String(localized: "Try Again"), action: actions.retry) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }
}
