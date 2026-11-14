import AppKit
import LuxCore

/// The account: its picture, name and Matrix ID, and Sign Out.
final class AccountSettingsController: NSViewController {
    private let model: SettingsModel
    private var observation: AnyObject?
    private let signOut: () -> Void
    private let images: ImagePipeline?
    private let avatar = AvatarView(side: 56)
    private let name = NSTextField(labelWithString: "")
    private let userId = NSTextField(labelWithString: "")
    private let searchIndex = NSTextField(labelWithString: "")
    private lazy var receipts = NSButton(checkboxWithTitle: String(localized: "Send read receipts"), target: self, action: #selector(receiptsChanged))

    init(model: SettingsModel, images: ImagePipeline?, signOut: @escaping () -> Void) {
        self.model = model
        self.images = images
        self.signOut = signOut
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Account")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        name.font = .systemFont(ofSize: 17, weight: .semibold)
        userId.textColor = .secondaryLabelColor
        userId.isSelectable = true
        let identity = NSStackView(views: [name, userId])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 2
        let header = NSStackView(views: [avatar, identity])
        header.spacing = 14
        let signOutButton = NSButton(title: String(localized: "Sign Out…"), target: self, action: #selector(confirmSignOut))
        receipts.state = model.sendsReadReceipts ? .on : .off
        let receiptsNote = NSTextField(wrappingLabelWithString: String(localized: "Others see when you have read their messages, on WhatsApp and Instagram too."))
        receiptsNote.textColor = .secondaryLabelColor
        receiptsNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        receiptsNote.preferredMaxLayoutWidth = 340
        view = settingsForm([
            [NSGridCell.emptyContentView, header],
            [NSTextField(labelWithString: String(localized: "Device:")), NSTextField(labelWithString: String(localized: "This Mac"))],
            [NSTextField(labelWithString: String(localized: "Privacy:")), receipts],
            [NSGridCell.emptyContentView, receiptsNote],
            [NSTextField(labelWithString: String(localized: "Search index:")), searchIndex],
            [NSGridCell.emptyContentView, signOutButton],
        ])
        observation = model.changes.observe { [weak self] in self?.update() }
        update()
    }

    private func update() {
        name.stringValue = model.profile?.name ?? ""
        userId.stringValue = model.profile?.userId ?? ""
        searchIndex.stringValue = model.searchIndex ?? String(localized: "Opening…")
        avatar.show(model.profile?.avatar, name: model.profile?.name ?? "", images: images)
    }

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
