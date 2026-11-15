import AppKit
import LuxCore

/// A chat's details, in a popover from its title in the toolbar, as Messages shows a
/// conversation's: its picture, name and topic, its networks (a merged chat's rooms), its
/// notifications and encryption, marking it read and leaving it; under them its members and what
/// it shared and its Matrix threads, one at a time. Edit… (for who may) changes its name, topic and
/// picture.
final class ChatDetailsController: NSViewController {
    private let session: Session
    private let model: ChatDetailsModel
    private var observation: AnyObject?
    /// The chat was renamed or repictured: the toolbar's title follows.
    var onChange: ((ChatRow) -> Void)?
    /// The chat was left: the window shows no chat.
    var onLeave: (() -> Void)?
    /// A thread was picked from the chat's threads: it opens beside the chat.
    var onOpenThread: ((MatrixThread) -> Void)?

    private let avatar = AvatarView(side: 72)
    private let name = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let topic = NSTextField(wrappingLabelWithString: "")
    private lazy var edit = NSButton(title: String(localized: "Edit…"), target: self, action: #selector(openEdit))
    private let networks = NSStackView()
    private let notifications = NSPopUpButton()
    private let chatStyle = NSPopUpButton()
    private let encryption = NSTextField(labelWithString: "")
    private let encryptionIcon = NSImageView()
    private let address = NSTextField(labelWithString: "")
    private var addressRow: NSGridRow?
    private lazy var markRead = NSButton(title: "", target: self, action: #selector(toggleRead))
    private lazy var leave = NSButton(title: String(localized: "Leave…"), target: self, action: #selector(confirmLeave))
    private let tabs = NSSegmentedControl()
    private let pane = NSView()
    private var tabKinds: [Tab] = []
    private var shown: NSViewController?

    private enum Tab: Equatable {
        /// A group room's, by its id and network.
        case members(String, network: String)
        case threads
        case shared(SharedKind)
    }

    private static let width: CGFloat = 360

    init(session: Session, row: ChatRow) {
        self.session = session
        model = session.details(of: row)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        name.font = .systemFont(ofSize: 17, weight: .semibold)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        topic.alignment = .center
        topic.preferredMaxLayoutWidth = Self.width - 40
        topic.isSelectable = true
        edit.controlSize = .small
        edit.bezelStyle = .push
        let header = NSStackView(views: [avatar, name, subtitle, topic, edit])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 4
        header.setCustomSpacing(10, after: avatar)
        header.setCustomSpacing(8, after: subtitle)
        header.setCustomSpacing(10, after: topic)

        networks.orientation = .vertical
        networks.alignment = .leading
        networks.spacing = 4
        notifications.target = self
        notifications.action = #selector(chooseNotifications)
        notifications.controlSize = .small
        for setting in NotificationSetting.allCases {
            notifications.addItem(withTitle: setting.title)
            notifications.lastItem?.image = NSImage(systemSymbolName: setting.symbol, accessibilityDescription: nil)
            notifications.lastItem?.representedObject = setting
        }
        chatStyle.target = self
        chatStyle.action = #selector(chooseChatStyle)
        chatStyle.controlSize = .small
        encryptionIcon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        let encryptionView = NSStackView(views: [encryptionIcon, encryption])
        encryptionView.spacing = 4
        address.isSelectable = true
        address.lineBreakMode = .byTruncatingMiddle
        let grid = NSGridView(views: [
            [label(String(localized: "Networks:")), networks],
            [label(String(localized: "Notifications:")), notifications],
            [label(String(localized: "Messages:")), chatStyle],
            [label(String(localized: "Encryption:")), encryptionView],
            [label(String(localized: "Address:")), address],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        addressRow = grid.row(at: 4)

        markRead.controlSize = .small
        leave.controlSize = .small
        let actions = NSStackView(views: [markRead, leave])
        actions.spacing = 8

        tabs.segmentStyle = .automatic
        tabs.target = self
        tabs.action = #selector(chooseTab)
        pane.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [header, grid, actions, separator(), tabs, pane])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: Self.width),
            pane.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            pane.heightAnchor.constraint(equalToConstant: 240),
        ])
        view = container
        observation = model.changes.observe { [weak self] in self?.update() }
        update()
        Task {
            do { try await model.load() } catch { report(error, of: "chat details") }
        }
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true
        return line
    }

    private func update() {
        let row = model.row
        avatar.show(row.avatar, name: row.name, members: row.memberAvatars, images: session.images)
        name.stringValue = row.name
        subtitle.stringValue = model.subtitle
        topic.stringValue = model.topic ?? ""
        topic.isHidden = model.topic == nil
        edit.isHidden = !(model.canRename || model.canChangeTopic || model.canChangePicture)
        edit.isEnabled = !model.isSaving

        networks.setViews(row.chatRooms.map(networkRow), in: .top)
        let setting = model.info?.notifications
        notifications.selectItem(at: setting.flatMap { NotificationSetting.allCases.firstIndex(of: $0) } ?? -1)
        notifications.isEnabled = model.info != nil && !model.isSaving
        if setting == nil, model.info != nil { notifications.setTitle(String(localized: "Mixed")) }
        chatStyle.removeAllItems()
        for (index, choice) in model.chatStyleChoices.enumerated() {
            chatStyle.addItem(withTitle: choice.title)
            chatStyle.lastItem?.tag = index
        }
        chatStyle.selectItem(withTag: model.chatStyleChoices.firstIndex { $0.style == model.chatStyleOverride } ?? 0)
        let encrypted = model.info?.isEncrypted == true
        encryptionIcon.image = NSImage(systemSymbolName: encrypted ? "lock.fill" : "lock.open", accessibilityDescription: nil)
        encryptionIcon.contentTintColor = encrypted ? .systemGreen : .secondaryLabelColor
        encryption.stringValue = model.info == nil ? "" : encrypted ? String(localized: "End-to-end encrypted") : String(localized: "Not encrypted")
        address.stringValue = model.mainRoom?.address ?? ""
        addressRow?.isHidden = model.mainRoom?.address == nil
        markRead.title = row.isUnread ? String(localized: "Mark as Read") : String(localized: "Mark as Unread")
        markRead.isEnabled = !model.isSaving
        leave.title = model.isGroup ? String(localized: "Leave Group…") : String(localized: "Leave Chat…")
        leave.isEnabled = !model.isSaving
        updateTabs()
        onChange?(row)
    }

    private func networkRow(_ room: ChatRoom) -> NSView {
        let logo = NSImageView(image: NetworkImage.image(room.network))
        logo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([logo.widthAnchor.constraint(equalToConstant: 16), logo.heightAnchor.constraint(equalToConstant: 16)])
        let row = NSStackView(views: [logo, NSTextField(labelWithString: Networks.name(room.network))])
        row.spacing = 6
        return row
    }

    /// Members (a group's, each room's for a merged one), then what it shared.
    private func updateTabs() {
        // once the rooms are known: a group opens on its members.
        guard let info = model.info else { return }
        let groups = info.rooms.filter { !$0.isDirect }
        let kinds = groups.map { Tab.members($0.id, network: $0.network) } + [.threads] + SharedKind.allCases.map(Tab.shared)
        guard kinds != tabKinds else { return }
        let selected = tabs.selectedSegment >= 0 ? tabKinds[safe: tabs.selectedSegment] : nil
        tabKinds = kinds
        tabs.segmentCount = kinds.count
        for (index, kind) in kinds.enumerated() {
            switch kind {
            case .members(_, let network):
                tabs.setLabel(groups.count > 1 ? Networks.name(network) : String(localized: "Members"), forSegment: index)
            case .threads:
                tabs.setLabel(String(localized: "Threads"), forSegment: index)
            case .shared(let kind):
                tabs.setLabel(kind.title, forSegment: index)
            }
        }
        tabs.selectedSegment = selected.flatMap { kinds.firstIndex(of: $0) } ?? 0
        chooseTab()
    }

    @objc private func chooseTab() {
        let controller: NSViewController
        switch tabKinds[safe: tabs.selectedSegment] {
        case .members(let id, _):
            guard let room = model.info?.rooms.first(where: { $0.id == id }) else { return }
            controller = MembersPane(model: model.members(of: room), images: session.images)
        case .threads:
            let threads = ThreadsPane(model: model.threads(), images: session.images)
            threads.onOpen = { [weak self] thread in self?.onOpenThread?(thread) }
            controller = threads
        case .shared(let kind):
            controller = SharedPane(model: model.shared(kind), images: session.images)
        case nil:
            return
        }
        shown?.view.removeFromSuperview()
        shown?.removeFromParent()
        addChild(controller)
        controller.view.frame = pane.bounds
        controller.view.autoresizingMask = [.width, .height]
        pane.addSubview(controller.view)
        shown = controller
    }

    // MARK: Changes

    @objc private func chooseNotifications() {
        guard let setting = notifications.selectedItem?.representedObject as? NotificationSetting else { return }
        change(String(localized: "The notifications could not be changed.")) { try await $0.setNotifications(setting) }
    }

    @objc private func chooseChatStyle() {
        model.chatStyleOverride = model.chatStyleChoices[safe: chatStyle.selectedTag()]?.style
    }

    @objc private func toggleRead() {
        let read = model.row.isUnread
        change(String(localized: "The chat could not be marked.")) { try await $0.markRead(read) }
    }

    @objc private func openEdit() {
        presentAsSheet(EditChatController(model: model, images: session.images))
    }

    @objc private func confirmLeave() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = model.isGroup ? String(localized: "Leave \(model.row.name)?") : String(localized: "Leave the chat with \(model.row.name)?")
        alert.informativeText = String(localized: "It goes from your chats. To come back, someone has to invite you again.")
        alert.addButton(withTitle: String(localized: "Leave"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.change(String(localized: "The chat could not be left.")) { try await $0.leave() } then: { [weak self] in
                self?.onLeave?()
            }
        }
    }

    /// Runs a change the user asked for; a failure is told.
    private func change(_ title: String, _ action: @escaping (ChatDetailsModel) async throws -> Void, then done: (() -> Void)? = nil) {
        Task {
            do {
                try await action(model)
                done?()
            } catch {
                Log.app.error("chat details change: \(String(describing: error), privacy: .public)")
                update()
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = error.localizedDescription
                if let window = view.window { _ = await alert.beginSheetModal(for: window) }
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
