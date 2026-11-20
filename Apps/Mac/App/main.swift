import AppIntents
import AppKit
import LuxCore

// `Lux agent …`: the app's executable as the agents' CLI, or their MCP server over stdio. It reaches
// the running app's socket and opens no window.
if CommandLine.arguments.dropFirst().first == "agent" {
    exit(Agents.runClient(arguments: Array(CommandLine.arguments.dropFirst(2))))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `-LuxDemo`: made-up chats, no account (measurements, screenshots).
    /// The view tests' host closes it as their bundle ends (`HostSessionCloser`).
    let session = LaunchOptions.isDemo ? Session.demo(preferences: .shared) : Session(preferences: .shared)
    private var window: NSWindow!
    private var settings: SettingsWindowController?
    private var agentDialogs: AgentDialogs?
    private var notifications: MacNotifications?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // the notification center's delegate before launching ends: a click on a notification
        // that launched the app reaches it.
        notifications = MacNotifications(session: session)
        // Siri's and Shortcuts' intents reach the session, and open a chat as Handoff does.
        let host = IntentHost(session: session) { [weak self] chat in self?.open(chat) }
        AppDependencyManager.shared.add(dependency: host)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        app.mainMenu = Self.menu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 420)
        window.setFrameAutosaveName("Main")
        window.center()
        window.makeKeyAndOrderFront(nil)
        // an account that cannot be opened after all (its sign-in revoked): back to signing in.
        session.onAccountLost = { [weak self] in self?.show(signedIn: false) }
        Task { show(signedIn: await session.restore()) }
        // after the Mac sleeps, the sync's connection is gone: it runs again on waking.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [session] _ in
            MainActor.assumeIsolated { session.enterForeground() }
        }
    }

    /// A chat continued from another of the account's devices (Handoff): the same chat opens here,
    /// once the chats show if they do not yet.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard let chat = ChatActivity(userActivity) else { return false }
        open(chat)
        return true
    }

    /// Opens `chat`, once the chats show if they do not yet: from Handoff, or an intent.
    private func open(_ chat: ChatActivity) {
        if let split = window?.contentViewController as? MainSplitViewController { open(chat, in: split) } else { chatToOpen = chat }
    }

    /// A chat continued before the chats showed.
    private var chatToOpen: ChatActivity?

    private func open(_ chat: ChatActivity, in split: MainSplitViewController) {
        window.makeKeyAndOrderFront(nil)
        split.openChat(roomId: chat.roomId, thread: chat.threadRoot)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The long work and the account's session end, its stores closed, before the app does:
    /// AppKit exits the process once it is told to go on.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await session.closeAsTheAppEnds(within: .seconds(5))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func show(signedIn: Bool) {
        // a new content view controller would size the window to its view: keep the window's size.
        let frame = window.frame
        defer { window.setFrame(frame, display: true) }
        if signedIn {
            let split = MainSplitViewController(session: session)
            split.onAccount = { [weak self] in self?.showSettings(nil) }
            split.onBadge = { [weak self] in self?.notifications?.setBadge($0) }
            window.contentViewController = split
            window.initialFirstResponder = split.initialFocus
            window.makeFirstResponder(split.initialFocus)
            window.toolbar = split.toolbar
            window.toolbarStyle = .unified
            // the toolbar shows the open chat's picture and name itself (`ChatTitleView`).
            window.titleVisibility = .hidden
            if let chat = chatToOpen {
                chatToOpen = nil
                open(chat, in: split)
            }
            notifications?.openChat = { [weak self, weak split] room, thread in
                self?.window.makeKeyAndOrderFront(nil)
                split?.openChat(roomId: room, thread: thread)
            }
            notifications?.isShowing = { [weak self, session] room, thread in
                self?.window.isKeyWindow == true && session.showsMessage(of: room, thread: thread)
            }
            // agents' approvals, drafts and messages to send come to this window.
            agentDialogs = AgentDialogs(window: window, split: split)
            session.agents.presenter = agentDialogs
            // the demo has no server: nothing to notify.
            if !LaunchOptions.isDemo { notifications?.start() }
            // another of the account's devices asks to verify: a sheet on the window.
            session.security?.onRequest = { [weak self] verification in
                self?.window.makeKeyAndOrderFront(nil)
                self?.presentSheet(VerificationController(model: verification))
            }
            Task {
                // encryption first: the networks' welcome waits until this Mac can read.
                await offerEncryptionSetup()
                welcomeToNetworks()
            }
        } else {
            notifications?.stop()
            notifications?.openChat = nil
            session.security?.onRequest = nil
            settings?.close()
            settings = nil
            window.toolbar = nil
            window.titleVisibility = .visible
            window.title = "Lux"
            window.contentViewController = SignInController(session: session) { [weak self] in self?.show(signedIn: true) }
        }
    }

    /// A sheet over the window's content; one already up keeps its place, the new one comes
    /// after it.
    private func presentSheet(_ sheet: NSViewController) {
        var top = window.contentViewController
        while let presented = top?.presentedViewControllers?.last { top = presented }
        top?.presentAsSheet(sheet)
    }

    /// After signing in: what this Mac needs to read encrypted messages. An unverified Mac is
    /// asked to verify at each launch; an account without recovery is offered it once. Returns
    /// once the sheet is gone (or none was needed).
    private func offerEncryptionSetup() async {
        guard let security = session.security else { return }
        let sheet: NSViewController
        switch await security.knownSetup() {
        case .verifyThisDevice(let withRecoveryKey):
            sheet = ConfirmIdentityController(session: session, withRecoveryKey: withRecoveryKey)
        case .setUpRecovery where !Preferences.shared.recoverySetupOffered || LaunchOptions.demoNoRecovery:
            if !LaunchOptions.isDemo { Preferences.shared.recoverySetupOffered = true }
            sheet = RecoverySetupController(security: security)
        case .setUpRecovery, .ready, .unknown:
            return
        }
        guard window.attachedSheet == nil else { return }
        presentSheet(sheet)
        // the sheet, and whichever took its place, gone.
        let ends = NotificationCenter.default.notifications(named: NSWindow.didEndSheetNotification, object: window).map { _ in () }
        for await _ in ends where window.attachedSheet == nil {
            break
        }
    }

    /// After signing in, once: the server's networks, to pick the ones to bring. Their states load
    /// either way, for the list's bubble.
    private func welcomeToNetworks() {
        guard let networks = session.networks else { return }
        Task { [weak self] in
            await networks.load()
            guard let self else { return }
            let welcomed = Preferences.shared.networksWelcomed && !LaunchOptions.showsNetworksWelcome
            guard !welcomed, !LaunchOptions.isDemo || LaunchOptions.showsNetworksWelcome, window.attachedSheet == nil else { return }
            // the demo never marks the account's welcome as shown.
            if !LaunchOptions.isDemo { Preferences.shared.networksWelcomed = true }
            guard !networks.offered.isEmpty, networks.hasNoLogins else { return }
            let welcome = NetworksController(model: networks, mode: .welcome)
            let sheet = NSWindow(contentViewController: welcome)
            sheet.styleMask = [.titled]
            welcome.onDone = { [weak self, weak sheet] in
                if let sheet { self?.window.endSheet(sheet) }
            }
            window.beginSheet(sheet, completionHandler: nil)
        }
    }

    @objc func showSettings(_ sender: Any?) {
        guard session.isSignedIn else { return }
        if settings == nil {
            let list = (window.contentViewController as? MainSplitViewController)?.listModel
            settings = SettingsWindowController(session: session, model: SettingsModel(session: session), list: list) { [weak self] in
                self?.signOut(nil)
            }
            settings?.window?.center()
        }
        settings?.showWindow(nil)
    }

    @objc func signOut(_ sender: Any?) {
        Task {
            await session.signOut()
            show(signedIn: false)
        }
    }

    private static func menu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About Lux"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Settings…"), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide Lux"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: String(localized: "Quit Lux"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenu(title: String(localized: "File"))
        file.addItem(withTitle: String(localized: "New Message"), action: #selector(MainSplitViewController.newMessage(_:)), keyEquivalent: "n")
        file.addItem(withTitle: String(localized: "Attach Files…"), action: #selector(ThreadController.attachFiles(_:)), keyEquivalent: "A")
        file.addItem(.separator())
        file.addItem(withTitle: String(localized: "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = edit.addItem(withTitle: String(localized: "Find…"), action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f")
        find.action = #selector(NSTextView.performFindPanelAction(_:))
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        // Format: wraps the composer's selection in Markdown (ThreadController's actions).
        let format = NSMenu(title: String(localized: "Format"))
        for (title, action, key) in [(String(localized: "Bold"), #selector(ThreadController.formatBold(_:)), "b"),
                                     (String(localized: "Italic"), #selector(ThreadController.formatItalic(_:)), "i"),
                                     (String(localized: "Strikethrough"), #selector(ThreadController.formatStrikethrough(_:)), "x"),
                                     (String(localized: "Code"), #selector(ThreadController.formatCode(_:)), "k")] {
            let item = format.addItem(withTitle: title, action: action, keyEquivalent: key)
            if key == "x" { item.keyEquivalentModifierMask = [.command, .shift] }
        }
        // Message: sends what is written later (ThreadController's action).
        let message = NSMenu(title: String(localized: "Message"))
        let later = message.addItem(withTitle: String(localized: "Send Later"), action: nil, keyEquivalent: "")
        later.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        later.submenu = NSMenu(title: String(localized: "Send Later"))
        later.submenu?.delegate = SendLaterMenu.shared
        let through = message.addItem(withTitle: String(localized: "Send Through"), action: nil, keyEquivalent: "")
        through.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        through.submenu = NSMenu(title: String(localized: "Send Through"))
        through.submenu?.delegate = SendThroughMenu.shared
        let view = NSMenu(title: String(localized: "View"))
        view.addItem(withTitle: String(localized: "Show Sidebar"), action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        view.addItem(withTitle: String(localized: "Chat Details"), action: #selector(MainSplitViewController.showDetails(_:)), keyEquivalent: "i")
        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        app.windowsMenu = window
        for submenu in [appMenu, file, edit, format, message, view, window] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        return main
    }
}
