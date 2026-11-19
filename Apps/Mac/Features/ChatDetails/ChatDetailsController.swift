import AppKit
import LuxCore
import SwiftUI

/// A chat's details, in the window's inspector beside the chat (its title in the toolbar, or the
/// info button, opens and closes it), as Messages shows a conversation's: its picture, name and
/// topic, a row of quick actions (mute, mark read, edit), then tabs: Info (its settings as a
/// grouped form, as System Settings draws one), its pinned messages, its members, its Matrix
/// threads and what it shared, one at a time.
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
    /// The open chat's model, which follows its pinned messages: a tab lists them.
    weak var pins: ThreadModel? {
        didSet { show(pinned: pins?.pinned ?? []) }
    }
    /// A pinned message was picked: the chat goes to it.
    var onJump: ((PinnedMessage) -> Void)?
    private var hasPins = false

    private let avatar = AvatarView(side: 72)
    private let name = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let topic = NSTextField(wrappingLabelWithString: "")
    private lazy var mute = QuickAction(target: self, action: #selector(toggleMute))
    private lazy var markRead = QuickAction(target: self, action: #selector(toggleRead))
    private lazy var edit = QuickAction(target: self, action: #selector(openEdit))
    private let tabs = CapsuleTabs()
    private lazy var tabStrip = OverflowStrip(document: tabs)
    private let pane = NSView()
    private var tabKinds: [Tab] = []
    private var shown: NSViewController?
    /// The Info tab's form, kept while other tabs show so it keeps its scroll.
    private lazy var info = NSHostingController(rootView: ChatInfoForm(state: infoState, actions: infoActions))

    /// Where every tab's content starts and ends, the Info form's sections and the lists alike.
    static let inset: CGFloat = 16

    private enum Tab: Equatable {
        case info
        case pinned
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
        actions.spacing = 10
        // as wide as its tiles, so the column centres it.
        actions.setHuggingPriority(.required, for: .horizontal)

        // capsule tabs, as Messages' details; they scroll sideways when the inspector is narrow.
        tabs.onSelect = { [weak self] in self?.chooseTab() }
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        pane.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [header, actions, tabStrip, pane])
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
            // the tabs start where the sections under them do, and scroll when they are wider.
            tabStrip.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.inset),
            tabStrip.heightAnchor.constraint(equalToConstant: 28),
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
            isGroup: model.isGroup,
            canSeparate: model.canSeparate
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
            separate: { [weak self] in
                // its rooms go back to the list as their own chats: this one is gone.
                self?.model.separate()
                self?.onLeave?()
            },
            leave: { [weak self] in self?.confirmLeave() }
        )
    }

    /// Info, then members (a group's, each room's for a merged one), threads and what it shared.
    private func updateTabs() {
        let groups = model.info?.rooms.filter { !$0.isDirect } ?? []
        let kinds = [Tab.info] + (hasPins ? [.pinned] : []) + groups.map { Tab.members($0.id, network: $0.network) } + [.threads]
            + SharedKind.allCases.map(Tab.shared)
        guard kinds != tabKinds else { return }
        let selected = tabKinds[safe: tabs.selected]
        tabKinds = kinds
        tabs.titles = kinds.map { kind in
            switch kind {
            case .info: String(localized: "Info")
            case .pinned: String(localized: "Pinned")
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
        case .pinned:
            guard let pins else { return }
            let pane = PinnedPane(pins: pins, images: session.images)
            pane.onJump = { [weak self] pin in self?.onJump?(pin) }
            controller = pane
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

    /// The chat's pinned messages changed: their tab comes or goes, and lists them.
    func show(pinned: [PinnedMessage]) {
        (shown as? PinnedPane)?.show(pinned: pinned)
        guard hasPins != !pinned.isEmpty else { return }
        hasPins = !pinned.isEmpty
        if isViewLoaded { updateTabs() }
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
/// A row wider than its place, scrolled sideways: an end with more beyond it fades out, with an
/// arrow that scrolls on.
private final class OverflowStrip: NSView {
    let scroll = NSScrollView()
    private let fade = CAGradientLayer()
    private let back = OverflowStrip.arrow("chevron.left", label: String(localized: "Scroll Back"))
    private let forward = OverflowStrip.arrow("chevron.right", label: String(localized: "Scroll On"))
    private static let fadeWidth: CGFloat = 32

    init(document: NSView) {
        super.init(frame: .zero)
        scroll.documentView = document
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.wantsLayer = true
        scroll.layer?.mask = fade
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        back.target = self
        back.action = #selector(scrollBack)
        forward.target = self
        forward.action = #selector(scrollOn)
        for view in [scroll, back, forward] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            back.leadingAnchor.constraint(equalTo: leadingAnchor),
            back.centerYAnchor.constraint(equalTo: centerYAnchor),
            forward.trailingAnchor.constraint(equalTo: trailingAnchor),
            forward.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static func arrow(_ symbol: String, label: String) -> NSButton {
        let button = NSButton(image: NSImage.symbol(symbol, label: label), target: nil, action: nil)
        button.isBordered = false
        button.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        return button
    }

    override func layout() {
        super.layout()
        update()
    }

    @objc private func scrolled() { update() }

    /// The fade and the arrow at each end that has more of the row beyond it.
    private func update() {
        let clip = scroll.contentView.bounds, width = scroll.documentView?.frame.width ?? 0
        let before = clip.minX > 1, after = clip.maxX < width - 1
        back.isHidden = !before
        forward.isHidden = !after
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = scroll.bounds
        let edge = scroll.bounds.width > 0 ? Self.fadeWidth / scroll.bounds.width : 0
        let shown = NSColor.black.cgColor, gone = NSColor.clear.cgColor
        fade.colors = [before ? gone : shown, shown, shown, after ? gone : shown]
        fade.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        CATransaction.commit()
    }

    @objc private func scrollBack() { scroll(by: -1) }
    @objc private func scrollOn() { scroll(by: 1) }

    /// Most of a width further along, as far as the row goes.
    private func scroll(by direction: CGFloat) {
        let clip = scroll.contentView, width = scroll.documentView?.frame.width ?? 0
        let x = min(max(0, clip.bounds.minX + direction * clip.bounds.width * 0.6), max(0, width - clip.bounds.width)).rounded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            clip.animator().setBoundsOrigin(NSPoint(x: x, y: clip.bounds.minY))
        }
        scroll.reflectScrolledClipView(clip)
    }
}

private final class CapsuleTabs: NSView {
    var onSelect: (() -> Void)?
    private let row = NSStackView()
    /// Behind the chosen tab: Liquid Glass, as Messages marks it.
    private let glass = NSGlassEffectView()

    var titles: [String] = [] {
        didSet {
            row.setViews(titles.enumerated().map { index, title in
                let button = NSButton(title: title, target: self, action: #selector(pick))
                button.tag = index
                button.isBordered = false
                button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
                button.translatesAutoresizingMaskIntoConstraints = false
                button.heightAnchor.constraint(equalToConstant: 26).isActive = true
                button.widthAnchor.constraint(equalToConstant: ceil(button.intrinsicContentSize.width) + 24).isActive = true
                return button
            }, in: .leading)
            mark()
            needsLayout = true
            centresChosen = true
        }
    }

    /// The chosen tab; set from outside (a new chat), the glass moves at once.
    var selected = 0 {
        didSet {
            mark()
            if !picking {
                needsLayout = true
                centresChosen = true
            }
        }
    }
    /// The next layout scrolls the chosen tab to the middle (a new chat, new tabs).
    private var centresChosen = false
    /// The user is choosing a tab: the glass animates there, and no layout pass jumps it.
    private var picking = false

    init() {
        super.init(frame: .zero)
        glass.cornerRadius = 13
        addSubview(glass)
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
        guard button.tag != selected else { return }
        picking = true
        selected = button.tag
        picking = false
        // the glass slides from the tab it marked to the chosen one.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            glass.animator().frame = glassFrame
            centreChosen(animated: true)
        }
        onSelect?()
    }

    /// The glass centred on the chosen tab's title as drawn (a borderless button draws its title
    /// a little off its own centre), as wide as the tab.
    override func layout() {
        super.layout()
        // the tabs placed first: on the first pass the glass would measure them before they are.
        row.layoutSubtreeIfNeeded()
        glass.frame = glassFrame
        if centresChosen, let clip = enclosingScrollView?.contentView, clip.bounds.width > 0 {
            centresChosen = false
            centreChosen(animated: false)
        }
    }

    /// Scrolls the tabs so the chosen one sits in the middle, as far as the row goes.
    private func centreChosen(animated: Bool) {
        guard let scroll = enclosingScrollView, let button = row.views[safe: selected] else { return }
        let clip = scroll.contentView
        let x = min(max(0, button.frame.midX - clip.bounds.width / 2), max(0, bounds.width - clip.bounds.width)).rounded()
        guard abs(clip.bounds.minX - x) > 0.5 else { return }
        if animated {
            clip.animator().setBoundsOrigin(NSPoint(x: x, y: clip.bounds.minY))
        } else {
            clip.setBoundsOrigin(NSPoint(x: x, y: clip.bounds.minY))
        }
        scroll.reflectScrolledClipView(clip)
    }

    private var glassFrame: CGRect {
        guard let button = row.views[safe: selected] as? NSButton, let cell = button.cell else { return .zero }
        let title = convert(cell.titleRect(forBounds: button.bounds), from: button)
        let height = button.frame.height
        return CGRect(x: button.frame.minX, y: (title.midY - height / 2).rounded(), width: button.frame.width, height: height)
            .offsetBy(dx: (title.midX - button.frame.midX).rounded(), dy: 0)
    }

    private func mark() {
        for case let button as NSButton in row.views {
            let on = button.tag == selected
            button.contentTintColor = on ? .labelColor : .secondaryLabelColor
            button.setAccessibilityValue(on ? String(localized: "Selected") : nil)
        }
        glass.isHidden = row.views.isEmpty
    }
}

/// A quick action under a chat's name, as Messages draws them: a symbol centred over a short
/// title, on a rounded tile.
private final class QuickAction: NSControl {
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")

    convenience init(target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        symbol.symbolConfiguration = .init(pointSize: 16, weight: .medium)
        symbol.contentTintColor = .labelColor
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        title.alignment = .center
        let content = NSStackView(views: [symbol, title])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 4
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.heightAnchor.constraint(equalToConstant: 20),
            heightAnchor.constraint(equalToConstant: 54),
            widthAnchor.constraint(equalToConstant: 76),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    func set(_ symbolName: String, _ text: String) {
        symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        title.stringValue = text
        setAccessibilityLabel(text)
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.5 }
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        alphaValue = 0.7
    }

    override func mouseUp(with event: NSEvent) {
        alphaValue = isEnabled ? 1 : 0.5
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        sendAction(action, to: target)
    }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
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
        var canSeparate: Bool
    }

    /// What the form's controls do, on the main actor (as SwiftUI calls them).
    struct Actions {
        var notifications: @MainActor (NotificationSetting) -> Void
        var lowPriority: @MainActor (Bool) -> Void
        var chatStyle: @MainActor (Int) -> Void
        var separate: @MainActor () -> Void
        var leave: @MainActor () -> Void
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
                // the networks by name where they fit beside the label, else by their pictures
                // alone; never under it (a labeled row would move a value that does not fit there).
                HStack {
                    row(String(localized: "Networks"), "point.3.connected.trianglepath.dotted", .purple)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    ViewThatFits(in: .horizontal) {
                        networks(named: true)
                        networks(named: false)
                    }
                    .foregroundStyle(.secondary)
                }
                if state.canSeparate {
                    Button(action: actions.separate) {
                        Label(String(localized: "Separate Chats"), systemImage: "arrow.triangle.branch")
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.borderless)
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
        // the sections start where the tabs and the other tabs' lists do: a grouped form insets
        // its sections 9 points within its margins.
        .contentMargins(.horizontal, ChatDetailsController.inset - 9, for: .scrollContent)
    }

    /// A row's title beside its symbol on a coloured tile, as System Settings shows them.
    private func networks(named: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(state.networks, id: \.self) { network in
                Image(nsImage: NetworkImage.image(network)).resizable().frame(width: 16, height: 16)
                    .help(Networks.name(network))
                if named { Text(Networks.name(network)).lineLimit(1) }
            }
        }
        .fixedSize()
    }

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
