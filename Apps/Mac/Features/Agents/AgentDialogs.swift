import AppKit
import LuxCore

/// What the agents ask of the user, on the main window: the approval with its match code, a
/// draft put in a chat, a message to send after the user's click.
@MainActor
final class AgentDialogs: AgentsPresenter {
    private weak var window: NSWindow?
    private weak var split: MainSplitViewController?

    init(window: NSWindow, split: MainSplitViewController) {
        self.window = window
        self.split = split
    }

    func approve(_ request: AgentRequest) async -> AgentDecision {
        let alert = NSAlert()
        alert.messageText = request.reason == nil
            ? String(localized: "\(request.client) wants to use your chats")
            : String(localized: "\(request.client) asks for more")
        var lines = [String(localized: "Code: \(request.code)"),
                     String(localized: "Allow it only if the agent shows the same code.")]
        if let reason = request.reason { lines.append(String(localized: "Why: \(reason)")) }
        if let command = request.command { lines.append(command) }
        if let folder = request.folder { lines.append(folder) }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Don't Allow"))
        let access = NSPopUpButton(frame: .zero, pullsDown: false)
        access.addItems(withTitles: AgentGrant.allCases.map(\.title))
        access.selectItem(at: AgentGrant.allCases.firstIndex(of: request.grant) ?? 0)
        let always = NSButton(checkboxWithTitle: String(localized: "Always allow \(request.client)"), target: nil, action: nil)
        let accessory = NSStackView(views: [access, always])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
        alert.accessoryView = accessory
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        guard await present(alert) == .alertFirstButtonReturn else { return .deny }
        let grant = AgentGrant.allCases[max(0, min(access.indexOfSelectedItem, AgentGrant.allCases.count - 1))]
        return .allow(grant, always: always.state == .on)
    }

    func showDraft(_ text: String, inRoom roomId: String) {
        Task {
            guard let thread = await split?.openedChat(roomId: roomId) else { return }
            window?.makeKeyAndOrderFront(nil)
            thread.replaceComposerText(with: text)
        }
    }

    func confirmSend(_ text: String, inRoom roomId: String, client: String) async -> Bool {
        guard let thread = await split?.openedChat(roomId: roomId) else { return false }
        let alert = NSAlert()
        alert.messageText = String(localized: "Send this message for \(client)?")
        alert.informativeText = text
        alert.addButton(withTitle: String(localized: "Send"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        guard await present(alert) == .alertFirstButtonReturn else { return false }
        thread.model.send(text)
        return true
    }

    /// `alert` as a sheet on the window, or on its own without one.
    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in continuation.resume(returning: response) }
        }
    }
}
