import AppKit
import LuxCore

/// Agents: AI agents on this Mac (Claude Code, Codex, Claude, Cursor) reach the chats through the
/// `Lux agent` command or its MCP server, each session approved in Lux. Here: the switch, the
/// commands to set them up with, the skill that tells an agent what Lux is, the chats kept from
/// every AI, the clients approved for always, and what they did lately.
final class AgentsSettingsController: NSViewController {
    private let session: Session
    private var agents: Agents { session.agents }
    private lazy var toggle = NSButton(checkboxWithTitle: String(localized: "Allow AI agents on this Mac"), target: self,
                                       action: #selector(toggled))
    private let status = NSTextField(wrappingLabelWithString: "")
    private lazy var hidden = NSPopUpButton(frame: .zero, pullsDown: true)
    private lazy var approved = NSPopUpButton(frame: .zero, pullsDown: true)
    private let activity = NSTextField(wrappingLabelWithString: "")
    private var observation: AnyObject?
    /// The chats kept from AI, as the account last said.
    private var hiddenChats: [HiddenChat] = []

    init(session: Session) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Agents")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for label in [status, activity] {
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.preferredMaxLayoutWidth = 340
        }
        let mcp = "\(Agents.command) mcp"
        view = settingsForm([
            [NSTextField(labelWithString: String(localized: "Agents:")), toggle],
            [NSGridCell.emptyContentView, status],
            [NSTextField(labelWithString: String(localized: "Command:")), copyable(Agents.command)],
            [NSTextField(labelWithString: String(localized: "MCP server:")), copyable(mcp)],
            [NSTextField(labelWithString: String(localized: "Claude Code:")), copyable("claude mcp add lux -- \(mcp)")],
            [NSTextField(labelWithString: String(localized: "Claude Desktop:")),
             NSButton(title: String(localized: "Add to Claude Desktop…"), target: self, action: #selector(addToClaudeDesktop))],
            [NSTextField(labelWithString: String(localized: "Skill:")),
             NSButton(title: String(localized: "Install Skill…"), target: self, action: #selector(installSkill))],
            [NSTextField(labelWithString: String(localized: "Hidden from AI:")), hidden],
            [NSTextField(labelWithString: String(localized: "Always allowed:")), approved],
            [NSTextField(labelWithString: String(localized: "Lately:")), activity],
        ])
        observation = agents.changes.observe { [weak self] in self?.update() }
        update()
        loadHidden()
    }

    /// The hidden chats from the account: another device may have changed them.
    private func loadHidden() {
        Task { [weak self, session] in
            let hidden = await session.hiddenFromAI()
            self?.hiddenChats = hidden
            self?.update()
        }
    }

    /// `text` in a field the user selects and copies, with a Copy button.
    private func copyable(_ text: String) -> NSView {
        let field = NSTextField(labelWithString: text)
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.lineBreakMode = .byTruncatingMiddle
        field.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        let copy = NSButton(title: String(localized: "Copy"), target: self, action: #selector(copy(_:)))
        copy.controlSize = .small
        copy.identifier = NSUserInterfaceItemIdentifier(text)
        return NSStackView(views: [field, copy])
    }

    private func update() {
        toggle.state = agents.isOn ? .on : .off
        toggle.isEnabled = session.textActions.isOn
        status.stringValue = if !session.textActions.isOn {
            String(localized: "Turn on AI features in the AI pane first.")
        } else if agents.isServing {
            String(localized: "Agents can connect. Each session asks you here first, with a code it shows too; it reads only, unless you allow more.")
        } else if agents.isWaiting {
            String(localized: "Waiting for your chats to open.")
        } else {
            String(localized: "Off: no agent reaches your chats.")
        }
        hidden.removeAllItems()
        let chats = hiddenChats
        hidden.addItem(withTitle: chats.isEmpty ? String(localized: "No chats") : String(localized: "\(chats.count) chats"))
        hidden.menu?.addItem(NSMenuItem(title: String(localized: "Add a Chat…"), action: #selector(addHidden), keyEquivalent: ""))
        for chat in chats {
            let item = NSMenuItem(title: String(localized: "Show \(chat.name) to AI"), action: #selector(removeHidden(_:)), keyEquivalent: "")
            item.representedObject = chat.id
            hidden.menu?.addItem(item)
        }
        approved.removeAllItems()
        let clients = agents.approvedClients
        approved.addItem(withTitle: clients.isEmpty ? String(localized: "None") : clients.map(\.client).joined(separator: ", "))
        for client in clients {
            let item = NSMenuItem(title: String(localized: "Forget \(client.client) (\(client.grant.title))"), action: #selector(forget(_:)),
                                  keyEquivalent: "")
            item.representedObject = client.client
            approved.menu?.addItem(item)
        }
        for item in (hidden.menu?.items ?? []) + (approved.menu?.items ?? []) { item.target = self }
        activity.stringValue = agents.activity.prefix(5).map { entry in
            let what = entry.refused.map { String(localized: "refused: \($0)") }
                ?? String(localized: "\(entry.messages) messages from \(entry.chats) chats")
            return "\(entry.date.formatted(date: .omitted, time: .shortened))  \(entry.client) · \(entry.tool) · \(what)"
        }.joined(separator: "\n")
        if agents.activity.isEmpty { activity.stringValue = String(localized: "Nothing yet.") }
    }

    @objc private func toggled() {
        agents.isOn = toggle.state == .on
    }

    @objc private func copy(_ sender: NSButton) {
        guard let text = sender.identifier?.rawValue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The skill, a `SKILL.md` in a `lux` folder of the skills folder the user picks (Claude
    /// Code's `~/.claude/skills`, Codex's `~/.codex/skills`): the sandbox writes only where the
    /// user says.
    @objc private func installSkill() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Install")
        panel.message = String(localized: "Choose your agent's skills folder, such as ~/.claude/skills or ~/.codex/skills.")
        panel.directoryURL = URL(filePath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()).appending(path: ".claude/skills")
        panel.beginSheetModal(for: window) { [weak self, panel] response in
            MainActor.assumeIsolated {
                guard response == .OK, let folder = panel.url else { return }
                self?.writeSkill(in: folder)
            }
        }
    }

    private func writeSkill(in folder: URL) {
        let alert = NSAlert()
        do {
            let skill = folder.appending(path: "lux", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try Agents.skill.write(to: skill.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
            alert.messageText = String(localized: "The skill is installed")
            alert.informativeText = skill.path
        } catch {
            alert.messageText = String(localized: "The skill could not be installed")
            alert.informativeText = error.localizedDescription
        }
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    @objc private func addHidden() {
        let picker = ChatPickerController(session: session, title: String(localized: "Hide a Chat from AI"),
                                          action: String(localized: "Hide")) { [weak self] row in
            self?.setHidden(HiddenChat(id: row.id, name: row.name), hidden: true)
        }
        presentAsSheet(picker)
    }

    @objc private func removeHidden(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let chat = hiddenChats.first(where: { $0.id == id }) else { return }
        setHidden(chat, hidden: false)
    }

    private func setHidden(_ chat: HiddenChat, hidden: Bool) {
        Task { [weak self, session] in
            do {
                try await session.setHiddenFromAI(chat, hidden: hidden)
            } catch {
                self?.show(error, title: String(localized: "The chat could not be changed"))
            }
            self?.loadHidden()
        }
    }

    private func show(_ error: any Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// Claude Desktop installs Lux as an extension: an MCP Bundle (`.mcpb`) whose server is this
    /// app's own executable (`agent mcp`), opened with Claude Desktop, which asks the user.
    @objc private func addToClaudeDesktop() {
        do {
            NSWorkspace.shared.open(try MCPBundle.make())
        } catch {
            show(error, title: String(localized: "The extension could not be made"))
        }
    }

    @objc private func forget(_ sender: NSMenuItem) {
        guard let client = sender.representedObject as? String else { return }
        agents.forget(client: client)
    }
}
