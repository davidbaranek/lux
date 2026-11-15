import AppKit
import LuxCore
import SwiftUI

/// A chat's details, in the window's inspector beside the chat (its title in the toolbar, or the
/// info button, opens and closes it), as Messages shows a conversation's: its picture, name and
/// topic, a row of quick actions (mute, mark read, edit), then tabs: Info (its settings as a
/// grouped form, as System Settings draws one), its members, its Matrix threads and what it
/// shared, one at a time.
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
    private lazy var mute = QuickAction(target: self, action: #selector(toggleMute))
    private lazy var markRead = QuickAction(target: self, action: #selector(toggleRead))
    private lazy var edit = QuickAction(target: self, action: #selector(openEdit))
    private let tabs = CapsuleTabs()
    private let tabsScroll = NSScrollView()
    private let pane = NSView()
    private var tabKinds: [Tab] = []
    private var shown: NSViewController?
    /// The Info tab's form, kept while other tabs show so it keeps its scroll.
    private lazy var info = NSHostingController(rootView: ChatInfoForm(state: infoState, actions: infoActions))

    private enum Tab: Equatable {
        case info
        /// A group room's, by its id and network.
        case members(String, network: String)
        case threads
        case shared(SharedKind)
    }

    init(session: Session, row: ChatRow, list: ChatListModel?) {
        self.session = session
        model = session.details(of: row, in: list)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        name.font = .systemFont(ofSize: 17, weight: .semibold)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.alignment = .center
        topic.alignment = .center
        topic.isSelectable = true
        topic.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let header = NSStackView(views: [avatar, name, subtitle, topic])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 2
        header.setCustomSpacing(10, after: avatar)
        header.setCustomSpacing(6, after: subtitle)

        let actions = NSStackView(views: [mute, markRead, edit])
        actions.spacing = 8
        actions.distribution = .fillEqually

        // capsule tabs, as Messages' details; they scroll sideways when the inspector is narrow.
        tabs.onSelect = { [weak self] in self?.chooseTab() }
        tabsScroll.documentView = tabs
        tabsScroll.hasHorizontalScroller = false
        tabsScroll.drawsBackground = false
        tabsScroll.horizontalScrollElasticity = .allowed
        tabsScroll.verticalScrollElasticity = .none
        tabsScroll.translatesAutoresizingMaskIntoConstraints = false
        pane.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [header, actions, tabsScroll, pane])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(16, after: header)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 0, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // the tab's content takes what is left of the inspector's height.
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        pane.setContentHuggingPriority(.defaultLow, for: .vertical)
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // under the window's toolbar, which spans the inspector too.
            stack.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            topic.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -40),
            actions.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32),
            tabsScroll.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -24),
            tabsScroll.heightAnchor.constraint(equalToConstant: 28),
            pane.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pane.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        view = container
        observation = model.changes.observe { [weak self] in self?.update() }
        update()
        Task {
            do { try await model.load() } catch { report(error, of: "chat details") }
        }
    }

    private func update() {
        let row = model.row
        avatar.show(row.avatar, name: row.name, members: row.memberAvatars, images: session.images)
        name.stringValue = row.name
        subtitle.stringValue = model.subtitle
        topic.stringValue = model.topic ?? ""
        topic.isHidden = model.topic == nil

        let muted = model.info?.notifications == .off
        mute.set(muted ? "bell" : "bell.slash", muted ? String(localized: "Unmute") : String(localized: "Mute"))
        mute.isEnabled = model.info != nil && !model.isSaving
        markRead.set(row.isUnread ? "checkmark.message" : "message.badge",
                     row.isUnread ? String(localized: "Read") : String(localized: "Unread"))
        markRead.isEnabled = !model.isSaving
        edit.set("pencil", String(localized: "Edit"))
        edit.isHidden = !(model.canRename || model.canChangeTopic || model.canChangePicture)
        edit.isEnabled = !model.isSaving

        info.rootView = ChatInfoForm(state: infoState, actions: infoActions)
        updateTabs()
        onChange?(row)
    }

    /// What the Info tab shows, read from the model.
    private var infoState: ChatInfoForm.State {
        let choices = model.chatStyleChoices
        return ChatInfoForm.State(
            notifications: model.info?.notifications,
            isLoaded: model.info != nil,
            isSaving: model.isSaving,
            isLowPriority: model.isLowPriority,
            keptOutNote: model.keptOutNote,
            chatStyles: choices.map(\.title),
            chatStyle: choices.firstIndex { $0.style == model.chatStyleOverride } ?? choices.count - 1,
            isEncrypted: model.info.map(\.isEncrypted),
            networks: model.row.chatRooms.map(\.network),
            address: model.mainRoom?.address,
            isGroup: model.isGroup
        )
    }

    private var infoActions: ChatInfoForm.Actions {
        ChatInfoForm.Actions(
            notifications: { [weak self] setting in
                self?.change(String(localized: "The notifications could not be changed.")) { try await $0.setNotifications(setting) }
            },
            lowPriority: { [weak self] on in
                self?.change(String(localized: "The chat could not be moved.")) { try await $0.setLowPriority(on) }
            },
            chatStyle: { [weak self] index in
                guard let self else { return }
                model.chatStyleOverride = model.chatStyleChoices[safe: index]?.style
            },
            leave: { [weak self] in self?.confirmLeave() }
        )
    }

    /// Info, then members (a group's, each room's for a merged one), threads and what it shared.
    private func updateTabs() {
        let groups = model.info?.rooms.filter { !$0.isDirect } ?? []
        let kinds = [Tab.info] + groups.map { Tab.members($0.id, network: $0.network) } + [.threads]
            + SharedKind.allCases.map(Tab.shared)
        guard kinds != tabKinds else { return }
        let selected = tabKinds[safe: tabs.selected]
        tabKinds = kinds
        tabs.titles = kinds.map { kind in
            switch kind {
            case .info: String(localized: "Info")
            case .members(_, let network): groups.count > 1 ? Networks.name(network) : String(localized: "Members")
            case .threads: String(localized: "Threads")
            case .shared(let kind): kind.title
            }
        }
        tabs.selected = selected.flatMap { kinds.firstIndex(of: $0) } ?? 0
        // the tabs' own width: the scroll view shows them, or scrolls them when they are wider.
        tabs.setFrameSize(tabs.fittingSize)
        chooseTab()
    }

    private func chooseTab() {
        let controller: NSViewController
        switch tabKinds[safe: tabs.selected] {
        case .info:
            controller = info
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
        guard controller !== shown else { return }
        shown?.view.removeFromSuperview()
        shown?.removeFromParent()
        addChild(controller)
        controller.view.frame = pane.bounds
        controller.view.autoresizingMask = [.width, .height]
        pane.addSubview(controller.view)
        shown = controller
    }

    // MARK: Changes

    @objc private func toggleMute() {
        let setting: NotificationSetting = model.info?.notifications == .off ? .default : .off
        change(String(localized: "The notifications could not be changed.")) { try await $0.setNotifications(setting) }
    }

    @objc private func toggleRead() {
        let read = model.row.isUnread
        change(String(localized: "The chat could not be marked.")) { try await $0.markRead(read) }
    }

    @objc private func openEdit() {
        presentAsSheet(EditChatController(model: model, images: session.images))
    }

    private func confirmLeave() {
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

/// Tabs as Messages' details draws them: titles side by side, the chosen one on a capsule.
private final class CapsuleTabs: NSView {
    var onSelect: (() -> Void)?
    private let row = NSStackView()

    var titles: [String] = [] {
        didSet {
            row.setViews(titles.enumerated().map { index, title in
                let button = NSButton(title: title, target: self, action: #selector(pick))
                button.tag = index
                button.isBordered = false
                button.wantsLayer = true
                button.layer?.cornerRadius = 11
                button.layer?.cornerCurve = .continuous
                button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
                button.translatesAutoresizingMaskIntoConstraints = false
                button.heightAnchor.constraint(equalToConstant: 22).isActive = true
                button.widthAnchor.constraint(equalToConstant: ceil(button.intrinsicContentSize.width) + 20).isActive = true
                return button
            }, in: .leading)
            mark()
        }
    }

    var selected = 0 { didSet { mark() } }

    init() {
        super.init(frame: .zero)
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func pick(_ button: NSButton) {
        selected = button.tag
        onSelect?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        mark()
    }

    private func mark() {
        for case let button as NSButton in row.views {
            let on = button.tag == selected
            effectiveAppearance.performAsCurrentDrawingAppearance {
                button.layer?.backgroundColor = on ? NSColor.quaternaryLabelColor.cgColor : nil
            }
            button.contentTintColor = on ? .labelColor : .secondaryLabelColor
            button.setAccessibilityValue(on ? String(localized: "Selected") : nil)
        }
    }
}

/// A quick action under a chat's name, as Messages draws them: a symbol over a short title, in
/// a rounded tile.
private final class QuickAction: NSButton {
    convenience init(target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
        bezelStyle = .flexiblePush
        imagePosition = .imageAbove
        controlSize = .large
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        symbolConfiguration = .init(pointSize: 15, weight: .medium)
        contentTintColor = .controlAccentColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 52).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
    }

    func set(_ symbol: String, _ title: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.title = title
    }
}

/// A chat's settings as a grouped form, as System Settings draws one: notifications and low
/// priority, how its messages show, its encryption, networks and address, and leaving it.
struct ChatInfoForm: View {
    struct State {
        var notifications: NotificationSetting?
        var isLoaded: Bool
        var isSaving: Bool
        var isLowPriority: Bool
        var keptOutNote: String?
        var chatStyles: [String]
        var chatStyle: Int
        var isEncrypted: Bool?
        var networks: [String]
        var address: String?
        var isGroup: Bool
    }

    struct Actions {
        var notifications: (NotificationSetting) -> Void
        var lowPriority: (Bool) -> Void
        var chatStyle: (Int) -> Void
        var leave: () -> Void
    }

    let state: State
    let actions: Actions

    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(get: { state.notifications ?? .default }, set: actions.notifications)) {
                    ForEach(NotificationSetting.allCases, id: \.self) { setting in
                        Label(setting.title, systemImage: setting.symbol).tag(setting)
                    }
                } label: {
                    row(String(localized: "Notifications"), "bell.fill", .red)
                }
                .disabled(!state.isLoaded || state.isSaving)
                Toggle(isOn: Binding(get: { state.isLowPriority }, set: actions.lowPriority)) {
                    row(String(localized: "Low Priority"), "arrow.down", .gray)
                }
                .disabled(state.isSaving)
            } footer: {
                if let note = state.keptOutNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Picker(selection: Binding(get: { state.chatStyle }, set: actions.chatStyle)) {
                    ForEach(state.chatStyles.indices, id: \.self) { Text(state.chatStyles[$0]).tag($0) }
                } label: {
                    row(String(localized: "Messages"), "text.bubble.fill", .blue)
                }
            }
            Section {
                LabeledContent {
                    if let encrypted = state.isEncrypted {
                        Text(encrypted ? String(localized: "End-to-end encrypted") : String(localized: "Not encrypted"))
                    }
                } label: {
                    row(String(localized: "Encryption"), state.isEncrypted == false ? "lock.open.fill" : "lock.fill",
                        state.isEncrypted == false ? .orange : .green)
                }
                LabeledContent {
                    HStack(spacing: 6) {
                        ForEach(state.networks, id: \.self) { network in
                            Image(nsImage: NetworkImage.image(network)).resizable().frame(width: 16, height: 16)
                            Text(Networks.name(network))
                        }
                    }
                } label: {
                    row(String(localized: "Networks"), "point.3.connected.trianglepath.dotted", .purple)
                }
                if let address = state.address {
                    LabeledContent {
                        Text(address).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    } label: {
                        row(String(localized: "Address"), "at", .teal)
                    }
                }
            }
            Section {
                Button(role: .destructive, action: actions.leave) {
                    Text(state.isGroup ? String(localized: "Leave Group…") : String(localized: "Leave Chat…"))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .disabled(state.isSaving)
            }
        }
        .formStyle(.grouped)
    }

    /// A row's title beside its symbol on a coloured tile, as System Settings shows them.
    private func row(_ title: String, _ symbol: String, _ color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
