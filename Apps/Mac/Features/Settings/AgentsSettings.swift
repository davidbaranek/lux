import AppKit
import LuxCore
import SwiftUI

/// Agents, in the AI pane: AI agents on this Mac (Claude Code, Codex, Claude, Cursor) reach the chats through the
/// `Lux agent` command or its MCP server, each session approved in Lux. Here: the switch, the
/// commands to set them up with, the skill that tells an agent what Lux is, the chats kept from
/// every AI, the clients approved for always, and what they did lately. Its sections are in the AI
/// pane's form; the sheets and panels they open come from that pane (`host`).
@MainActor
final class AgentsSettings {
    private let session: Session
    private var agents: Agents { session.agents }
    private var observation: AnyObject?
    /// The chats kept from AI, as the account last said.
    private var hiddenChats: [HiddenChat] = []
    /// The pane the sections are in.
    weak var host: NSViewController?
    /// The agents, or the chats kept from them, changed: the sections are made again.
    var onChange: (() -> Void)?

    init(session: Session) {
        self.session = session
    }

    func load() {
        observation = agents.changes.observe { [weak self] in self?.onChange?() }
        loadHidden()
    }

    /// The hidden chats from the account: another device may have changed them.
    private func loadHidden() {
        Task { [weak self, session] in
            let hidden = await session.hiddenFromAI()
            self?.hiddenChats = hidden
            self?.onChange?()
        }
    }

    var sections: AgentsSections {
        AgentsSections(
            isOn: agents.isOn, aiIsOn: session.textActions.isOn, status: status, hidden: hiddenChats,
            approved: agents.approvedClients.map { AgentsSections.Approved(client: $0.client, grant: $0.grant.title) },
            activity: agents.activity.prefix(5).map { entry in
                let what = entry.refused.map { String(localized: "refused: \($0)") }
                    ?? String(localized: "\(entry.messages) messages from \(entry.chats) chats")
                return "\(entry.date.formatted(date: .omitted, time: .shortened))  \(entry.client) · \(entry.tool) · \(what)"
            },
            actions: .init(
                turn: { [weak self] in self?.agents.isOn = $0 },
                addToClaudeDesktop: { [weak self] in self?.addToClaudeDesktop() },
                installSkill: { [weak self] in self?.installSkill() },
                hide: { [weak self] in self?.addHidden() },
                show: { [weak self] in self?.setHidden($0, hidden: false) },
                forget: { [weak self] in self?.agents.forget(client: $0) }
            )
        )
    }

    private var status: String {
        if !session.textActions.isOn {
            String(localized: "Turn on AI features above first.")
        } else if agents.isServing {
            String(localized: "Agents can connect. Each session asks you here first, with a code it shows too; it reads only, unless you allow more.")
        } else if agents.isWaiting {
            String(localized: "Waiting for your chats to open.")
        } else {
            String(localized: "Off: no agent reaches your chats.")
        }
    }

    /// The skill, a `SKILL.md` in a `lux` folder of the skills folder the user picks (Claude
    /// Code's `~/.claude/skills`, Codex's `~/.codex/skills`): the sandbox writes only where the
    /// user says.
    private func installSkill() {
        guard let window = host?.view.window else { return }
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
        if let window = host?.view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private func addHidden() {
        let picker = ChatPickerController(session: session, title: String(localized: "Hide a Chat from AI"),
                                          action: String(localized: "Hide")) { [weak self] row in
            self?.setHidden(HiddenChat(id: row.id, name: row.name), hidden: true)
        }
        host?.presentAsSheet(picker)
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
        if let window = host?.view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// Claude Desktop installs Lux as an extension: an MCP Bundle (`.mcpb`) whose server is this
    /// app's own executable (`agent mcp`), opened with Claude Desktop, which asks the user.
    private func addToClaudeDesktop() {
        do {
            NSWorkspace.shared.open(try MCPBundle.make())
        } catch {
            show(error, title: String(localized: "The extension could not be made"))
        }
    }
}

/// The agents' sections of the AI pane's form.
struct AgentsSections: View {
    struct Approved: Hashable {
        var client: String
        var grant: String
    }

    struct Actions {
        var turn: @MainActor (Bool) -> Void
        var addToClaudeDesktop: @MainActor () -> Void
        var installSkill: @MainActor () -> Void
        var hide: @MainActor () -> Void
        var show: @MainActor (HiddenChat) -> Void
        var forget: @MainActor (String) -> Void
    }

    let isOn: Bool
    let aiIsOn: Bool
    let status: String
    let hidden: [HiddenChat]
    let approved: [Approved]
    let activity: [String]
    let actions: Actions

    var body: some View {
        Section(String(localized: "Agents")) {
            Toggle(isOn: Binding(get: { isOn }, set: actions.turn)) {
                Text(String(localized: "Allow AI agents on this Mac"))
                Text(status)
            }
            .disabled(!aiIsOn)
        }
        Section {
            copyable(String(localized: "Command"), Agents.command)
            copyable(String(localized: "MCP server"), "\(Agents.command) mcp")
            copyable(String(localized: "Claude Code"), "claude mcp add lux -- \(Agents.command) mcp")
            LabeledContent(String(localized: "Claude Desktop")) {
                Button(String(localized: "Add to Claude Desktop…"), action: actions.addToClaudeDesktop)
            }
            LabeledContent(String(localized: "Skill")) {
                Button(String(localized: "Install Skill…"), action: actions.installSkill)
            }
        } header: {
            Text(String(localized: "Set Up"))
        }
        Section(String(localized: "Privacy")) {
            LabeledContent(String(localized: "Hidden from AI")) {
                Menu(hidden.isEmpty ? String(localized: "No chats") : String(localized: "\(hidden.count) chats")) {
                    Button(String(localized: "Add a Chat…"), action: actions.hide)
                    if !hidden.isEmpty { Divider() }
                    ForEach(hidden) { chat in
                        Button(String(localized: "Show \(chat.name) to AI")) { actions.show(chat) }
                    }
                }
                .fixedSize()
            }
            LabeledContent(String(localized: "Always allowed")) {
                Menu(approved.isEmpty ? String(localized: "None") : approved.map(\.client).joined(separator: ", ")) {
                    ForEach(approved, id: \.self) { entry in
                        Button(String(localized: "Forget \(entry.client) (\(entry.grant))")) { actions.forget(entry.client) }
                    }
                }
                .fixedSize()
                .disabled(approved.isEmpty)
            }
        }
        Section(String(localized: "Lately")) {
            if activity.isEmpty { Text(String(localized: "Nothing yet.")).foregroundStyle(.secondary) }
            ForEach(activity.indices, id: \.self) { line in
                Text(activity[line]).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    /// `text` under its title, selectable, with a Copy button.
    private func copyable(_ title: String, _ text: String) -> some View {
        LabeledContent {
            Button(String(localized: "Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        } label: {
            Text(title)
            Text(text)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
