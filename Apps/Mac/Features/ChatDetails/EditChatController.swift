import AppKit
import LuxCore
import UniformTypeIdentifiers

/// A sheet that changes a chat's name, topic and picture for everyone in it, as far as the
/// account may: the picture at once (its centre square), the name and topic with Save.
final class EditChatController: NSViewController {
    private let model: ChatDetailsModel
    private let images: ImagePipeline?
    private var observation: AnyObject?
    private let avatar = AvatarView(side: 56)
    private let name = NSTextField()
    private let topic = NSTextField()
    private lazy var choosePicture = NSButton(title: String(localized: "Choose…"), target: self, action: #selector(pickPicture))
    private lazy var removePicture = NSButton(title: String(localized: "Remove"), target: self, action: #selector(removeThePicture))
    private lazy var save = NSButton(title: String(localized: "Save"), target: self, action: #selector(saveText))
    private let saving = NSProgressIndicator()

    init(model: ChatDetailsModel, images: ImagePipeline?) {
        self.model = model
        self.images = images
        super.init(nibName: nil, bundle: nil)
        title = model.isGroup ? String(localized: "Edit Group") : String(localized: "Edit Chat")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        name.stringValue = model.row.name
        name.placeholderString = String(localized: "Name")
        name.isEnabled = model.canRename
        name.widthAnchor.constraint(equalToConstant: 280).isActive = true
        topic.stringValue = model.topic ?? ""
        topic.placeholderString = String(localized: "What the chat is about")
        topic.isEnabled = model.canChangeTopic
        topic.usesSingleLineMode = false
        topic.cell?.wraps = true
        topic.heightAnchor.constraint(equalToConstant: 60).isActive = true
        saving.style = .spinning
        saving.controlSize = .small
        saving.isDisplayedWhenStopped = false
        let pictureButtons = NSStackView(views: [avatar, choosePicture, removePicture, saving])
        pictureButtons.spacing = 8
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(close))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, save])
        buttons.spacing = 8
        var rows: [[NSView]] = [[NSTextField(labelWithString: String(localized: "Picture:")), pictureButtons]]
        if model.canRename { rows.append([NSTextField(labelWithString: String(localized: "Name:")), name]) }
        if model.canChangeTopic { rows.append([NSTextField(labelWithString: String(localized: "Topic:")), topic]) }
        rows.append([NSGridCell.emptyContentView, buttons])
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 0).rowAlignment = .none
        grid.row(at: 0).yPlacement = .center
        grid.cell(for: buttons)?.xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
        ])
        view = container
        observation = model.changes.observe { [weak self] in self?.update() }
        update()
    }

    private func update() {
        avatar.show(model.row.avatar, name: model.row.name, members: model.row.memberAvatars, images: images)
        choosePicture.isEnabled = model.canChangePicture && !model.isSaving
        removePicture.isEnabled = model.canChangePicture && model.row.avatar != nil && !model.isSaving
        save.isEnabled = !model.isSaving
        model.isSaving ? saving.startAnimation(nil) : saving.stopAnimation(nil)
    }

    @objc private func pickPicture() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a picture for the chat. Its centre square is used.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let file = panel.url else { return }
            self?.change(String(localized: "The picture could not be set.")) { try await $0.setPicture(try Data(contentsOf: file)) }
        }
    }

    @objc private func removeThePicture() {
        change(String(localized: "The picture could not be removed.")) { try await $0.removePicture() }
    }

    @objc private func saveText() {
        let typedName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedTopic = topic.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let renamed = model.canRename && !typedName.isEmpty && typedName != model.row.name
        let retopiced = model.canChangeTopic && typedTopic != (model.topic ?? "")
        change(String(localized: "The changes could not be saved.")) { model in
            if renamed { try await model.rename(to: typedName) }
            if retopiced { try await model.setTopic(typedTopic) }
        } then: { [weak self] in
            self?.close()
        }
    }

    @objc private func close() {
        dismiss(nil)
    }

    private func change(_ title: String, _ action: @escaping (ChatDetailsModel) async throws -> Void, then done: (() -> Void)? = nil) {
        Task {
            do {
                try await action(model)
                done?()
            } catch {
                Log.app.error("chat edit: \(String(describing: error), privacy: .public)")
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = error.localizedDescription
                if let window = view.window { _ = await alert.beginSheetModal(for: window) }
            }
        }
    }
}
