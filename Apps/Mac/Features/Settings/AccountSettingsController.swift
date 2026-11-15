import AppKit
import LuxCore
import UniformTypeIdentifiers

/// The account: its picture and name (changed here, seen in every chat), its Matrix ID, and Sign
/// Out.
final class AccountSettingsController: NSViewController, NSTextFieldDelegate {
    private let model: SettingsModel
    private let profile: ProfileModel?
    private var observation: AnyObject?
    private let signOut: () -> Void
    private let images: ImagePipeline?
    private let avatar = AvatarView(side: 56)
    private let shownName = NSTextField(labelWithString: "")
    private let userId = NSTextField(labelWithString: "")
    private let name = NSTextField()
    private lazy var choosePicture = NSButton(title: String(localized: "Choose…"), target: self, action: #selector(pickPicture))
    private lazy var removePicture = NSButton(title: String(localized: "Remove"), target: self, action: #selector(confirmRemovePicture))
    private let saving = NSProgressIndicator()
    private lazy var receipts = NSButton(checkboxWithTitle: String(localized: "Send read receipts"), target: self, action: #selector(receiptsChanged))

    init(model: SettingsModel, profile: ProfileModel?, images: ImagePipeline?, signOut: @escaping () -> Void) {
        self.model = model
        self.profile = profile
        self.images = images
        self.signOut = signOut
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Account")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        shownName.font = .systemFont(ofSize: 17, weight: .semibold)
        userId.textColor = .secondaryLabelColor
        userId.isSelectable = true
        let identity = NSStackView(views: [shownName, userId])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 2
        let header = NSStackView(views: [avatar, identity])
        header.spacing = 14

        name.placeholderString = String(localized: "Name")
        name.delegate = self
        name.target = self
        name.action = #selector(saveName)
        name.setAccessibilityIdentifier("profile.name")
        name.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let nameNote = note(String(localized: "People see this name and picture in your Matrix chats. Bridged networks such as WhatsApp keep their own."))
        saving.style = .spinning
        saving.controlSize = .small
        saving.isDisplayedWhenStopped = false
        removePicture.setAccessibilityIdentifier("profile.removePicture")
        choosePicture.setAccessibilityIdentifier("profile.choosePicture")
        let pictureButtons = NSStackView(views: [choosePicture, removePicture, saving])
        pictureButtons.spacing = 8

        let signOutButton = NSButton(title: String(localized: "Sign Out…"), target: self, action: #selector(confirmSignOut))
        receipts.state = model.sendsReadReceipts ? .on : .off
        view = settingsForm([
            [NSGridCell.emptyContentView, header],
            [NSTextField(labelWithString: String(localized: "Name:")), name],
            [NSTextField(labelWithString: String(localized: "Picture:")), pictureButtons],
            [NSGridCell.emptyContentView, nameNote],
            [NSTextField(labelWithString: String(localized: "Device:")), NSTextField(labelWithString: String(localized: "This Mac"))],
            [NSTextField(labelWithString: String(localized: "Privacy:")), receipts],
            [NSGridCell.emptyContentView, note(String(localized: "Others see when you have read their messages, on WhatsApp and Instagram too."))],
            [NSGridCell.emptyContentView, signOutButton],
        ])
        observation = model.changes.observe { [weak self] in self?.update() }
        update()
    }

    private func note(_ text: String) -> NSTextField {
        let note = NSTextField(wrappingLabelWithString: text)
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.preferredMaxLayoutWidth = 340
        return note
    }

    private func update() {
        let shown = model.profile
        shownName.stringValue = shown?.name ?? ""
        userId.stringValue = shown?.userId ?? ""
        // the field keeps what the user is typing; it takes the server's name only when untouched.
        if name.currentEditor() == nil { name.stringValue = shown?.displayName ?? "" }
        let saving = model.isSavingProfile
        name.isEnabled = shown?.canChangeName == true && !saving
        choosePicture.isEnabled = shown?.canChangeAvatar == true && !saving
        removePicture.isEnabled = shown?.canChangeAvatar == true && shown?.avatar != nil && !saving
        saving ? self.saving.startAnimation(nil) : self.saving.stopAnimation(nil)
        avatar.show(shown?.avatar, name: shown?.name ?? "", images: images)
    }

    // MARK: Name

    /// Return in the field saves; so does leaving it with a change.
    @objc private func saveName() {
        let typed = name.stringValue
        guard let profile, !profile.isSaving, typed.trimmingCharacters(in: .whitespacesAndNewlines) != (model.profile?.displayName ?? "") else { return }
        change(String(localized: "The name could not be saved.")) { try await profile.rename(to: typed) }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        saveName()
    }

    // MARK: Picture

    @objc private func pickPicture() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a picture for your account. Its centre square is used.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let file = panel.url, let self, let profile else { return }
            change(String(localized: "The picture could not be set.")) {
                let data = try Data(contentsOf: file)
                try await profile.setPicture(data)
            }
        }
    }

    @objc private func confirmRemovePicture() {
        guard let window = view.window, let profile else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove your picture?")
        alert.informativeText = String(localized: "People will see your initials instead.")
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.change(String(localized: "The picture could not be removed.")) { try await profile.removePicture() }
        }
    }

    /// Runs a change of the profile; a failure is told, since the user asked for the change.
    private func change(_ title: String, _ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                Log.app.error("profile change: \(String(describing: error), privacy: .public)")
                // the field shows the server's name again.
                name.stringValue = model.profile?.displayName ?? ""
                guard let window = view.window else { return }
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = error.localizedDescription
                _ = await alert.beginSheetModal(for: window)
            }
        }
    }

    // MARK: Account

    @objc private func receiptsChanged() {
        model.sendsReadReceipts = receipts.state == .on
    }

    @objc private func confirmSignOut() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Sign out of this Mac?")
        alert.informativeText = String(localized: "This device leaves the account. Without a recovery key, it cannot read encrypted messages again.")
        alert.addButton(withTitle: String(localized: "Sign Out"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            window.close()
            self?.signOut()
        }
    }
}
