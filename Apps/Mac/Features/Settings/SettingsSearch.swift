import AppKit
import LuxCore
import SwiftUI

/// A setting search finds: its pane, the title and description its row shows (the row takes them
/// from here, so what is found is what is shown), and other words people look for it by.
struct SettingsItem: Identifiable, Hashable, Sendable {
    let id: String
    let pane: SettingsPane
    let title: String
    var detail: String?
    var keywords: [String] = []

    /// Every word of `query` is in its title, description, keywords or pane's name, ignoring case
    /// and diacritics.
    func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        let texts = [title, detail ?? "", pane.title] + keywords
        return !words.isEmpty && words.allSatisfy { word in texts.contains { $0.localizedStandardContains(word) } }
    }

    /// The settings of `panes` that match `query`, in the panes' order and then the rows'.
    static func matching(_ query: String, in panes: [SettingsPane]) -> [SettingsItem] {
        panes.flatMap { pane in all.filter { $0.pane == pane && $0.matches(query) } }
    }

    static let all: [SettingsItem] = [
        name, picture, device, readReceipts, signOut,
        placesColour, messageStyle,
        networks,
        thisMac, devices, keyBackup, recoveryKey,
        searchIndex, searchBack, photos, semanticSearch,
        aiFeatures, appleIntelligence, agents, command, mcpServer, claudeCode, claudeDesktop, skill, hiddenFromAI,
        alwaysAllowed, lately,
    ]

    // MARK: Account

    static let name = Self(id: "name", pane: .account, title: String(localized: "Name"),
                           keywords: [String(localized: "display name"), String(localized: "profile")])
    static let picture = Self(id: "picture", pane: .account, title: String(localized: "Picture"),
                              detail: String(localized: "People see this name and picture in your Matrix chats. Bridged networks such as WhatsApp keep their own."),
                              keywords: [String(localized: "avatar"), String(localized: "photo"), String(localized: "profile")])
    static let device = Self(id: "device", pane: .account, title: String(localized: "Device"),
                             keywords: [String(localized: "this Mac")])
    static let readReceipts = Self(id: "readReceipts", pane: .account, title: String(localized: "Send read receipts"),
                                   detail: String(localized: "Others see when you have read their messages, on WhatsApp and Instagram too."),
                                   keywords: [String(localized: "seen"), String(localized: "privacy")])
    static let signOut = Self(id: "signOut", pane: .account, title: String(localized: "Sign Out"),
                              keywords: [String(localized: "log out"), String(localized: "account")])

    // MARK: Appearance

    static let placesColour = Self(id: "placesColour", pane: .appearance, title: String(localized: "Places’ colour"),
                                   detail: String(localized: "For places without their own colour. Right-click a place in the rail to give it one."),
                                   keywords: [String(localized: "color"), String(localized: "theme"), String(localized: "tint")])
    static let messageStyle = Self(id: "messageStyle", pane: .appearance, title: String(localized: "Messages"),
                                   keywords: [String(localized: "bubbles"), String(localized: "plain"), String(localized: "chat style")])

    // MARK: Networks

    static let networks = Self(id: "networks", pane: .networks, title: String(localized: "Networks"),
                               detail: String(localized: "Your server's bridges connect these networks. Signing out here disconnects the network from your account, on every device."),
                               keywords: ["WhatsApp", "Signal", "Messenger", "Instagram", "Telegram", String(localized: "bridges"),
                                          String(localized: "connect")])

    // MARK: Encryption

    static let thisMac = Self(id: "thisMac", pane: .encryption, title: String(localized: "This Mac"),
                              keywords: [String(localized: "verify"), String(localized: "verification")])
    static let devices = Self(id: "devices", pane: .encryption, title: String(localized: "Devices"),
                              keywords: [String(localized: "sessions"), String(localized: "sign out"), String(localized: "verify")])
    static let keyBackup = Self(id: "keyBackup", pane: .encryption, title: String(localized: "Key backup"),
                                keywords: [String(localized: "recovery"), String(localized: "history")])
    static let recoveryKey = Self(id: "recoveryKey", pane: .encryption, title: String(localized: "Recovery key"),
                                  detail: String(localized: """
                                      Encrypted messages from before this device signed in are in your account's key backup. \
                                      Enter the recovery key you saved when you set it up (in Lux, Element or another app).
                                      """),
                                  keywords: [String(localized: "unlock"), String(localized: "security key")])

    // MARK: Search

    static let searchIndex = Self(id: "searchIndex", pane: .search, title: String(localized: "Messages"),
                                  keywords: [String(localized: "index")])
    static let searchBack = Self(id: "searchBack", pane: .search, title: String(localized: "Search back"),
                                 keywords: [String(localized: "history"), String(localized: "months")])
    static let photos = Self(id: "photos", pane: .search, title: String(localized: "Photos"),
                             keywords: [String(localized: "images"), String(localized: "text in photos")])
    static let semanticSearch = Self(id: "semanticSearch", pane: .search, title: String(localized: "Semantic search"),
                                     detail: String(localized: """
                                         Search always finds words. This also finds photos by what they show ("dog on the beach") and messages by \
                                         what they mean ("trip to the mountains"), with a model of about 650 MB read on this Mac. Nothing leaves \
                                         this Mac.
                                         """))

    // MARK: AI

    static let aiFeatures = Self(id: "aiFeatures", pane: .ai, title: String(localized: "AI features"),
                                 detail: String(localized: """
                                     Proofread and format a message from the + or the composer's menu in a chat. Off, no AI in Lux \
                                     reads anything.
                                     """),
                                 keywords: [String(localized: "writing tools")])
    static let appleIntelligence = Self(id: "appleIntelligence", pane: .ai, title: String(localized: "Apple Intelligence"))
    static let agents = Self(id: "agents", pane: .ai, title: String(localized: "Allow AI agents on this Mac"),
                             keywords: [String(localized: "agents"), "MCP", "Claude", "Codex", "Cursor"])
    static let command = Self(id: "command", pane: .ai, title: String(localized: "Command"),
                              keywords: [String(localized: "agents"), String(localized: "terminal")])
    static let mcpServer = Self(id: "mcpServer", pane: .ai, title: String(localized: "MCP server"),
                                keywords: [String(localized: "agents")])
    static let claudeCode = Self(id: "claudeCode", pane: .ai, title: String(localized: "Claude Code"),
                                 keywords: [String(localized: "agents")])
    static let claudeDesktop = Self(id: "claudeDesktop", pane: .ai, title: String(localized: "Claude Desktop"),
                                    keywords: [String(localized: "agents"), String(localized: "extension")])
    static let skill = Self(id: "skill", pane: .ai, title: String(localized: "Skill"),
                            keywords: [String(localized: "agents"), String(localized: "install")])
    static let hiddenFromAI = Self(id: "hiddenFromAI", pane: .ai, title: String(localized: "Hidden from AI"),
                                   keywords: [String(localized: "agents"), String(localized: "privacy"), String(localized: "hide chats")])
    static let alwaysAllowed = Self(id: "alwaysAllowed", pane: .ai, title: String(localized: "Always allowed"),
                                    keywords: [String(localized: "agents"), String(localized: "approved"), String(localized: "forget")])
    static let lately = Self(id: "lately", pane: .ai, title: String(localized: "Lately"),
                             keywords: [String(localized: "agents"), String(localized: "activity")])
}

/// A row's label from its setting: the title, and the description under it.
@ViewBuilder
func settingsLabel(_ item: SettingsItem) -> some View {
    Text(item.title)
    if let detail = item.detail { Text(detail) }
}

/// The setting a pane is asked to show: it scrolls to its row and marks it a moment.
@MainActor @Observable
final class SettingsFocus {
    private(set) var target: SettingsItem.ID?
    /// Counts the asks, so the same setting found twice is shown twice.
    private(set) var asks = 0
    var marked: SettingsItem.ID?

    func reveal(_ item: SettingsItem) {
        target = item.id
        asks += 1
    }
}

/// A pane's form, which scrolls to the setting its focus asks for.
struct PaneRoot<Content: View>: View {
    let focus: SettingsFocus
    let content: Content

    var body: some View {
        ScrollViewReader { proxy in
            content
                .environment(focus)
                .onChange(of: focus.asks, initial: true) {
                    guard let id = focus.target else { return }
                    Task {
                        // a pane just put in the window lays its rows out first.
                        await Task.yield()
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                        focus.marked = id
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation(.easeOut(duration: 0.6)) { if focus.marked == id { focus.marked = nil } }
                    }
                }
        }
    }
}

extension View {
    /// Marks this as `item`'s row: where search scrolls to, lit while it is found.
    func settingsRow(_ item: SettingsItem) -> some View {
        modifier(SettingsRow(id: item.id))
    }
}

private struct SettingsRow: ViewModifier {
    let id: SettingsItem.ID
    @Environment(SettingsFocus.self) private var focus: SettingsFocus?

    func body(content: Content) -> some View {
        content
            .id(id)
            .background {
                if focus?.marked == id {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.2))
                        .padding(-6)
                }
            }
    }
}

/// A Settings pane's form in its window, at the size the window gives it rather than its own, and
/// scrolled to the setting search found.
@MainActor
final class PaneForm<Form: View> {
    let focus = SettingsFocus()
    let view: NSHostingView<PaneRoot<Form>>

    init(_ form: Form) {
        view = NSHostingView(rootView: PaneRoot(focus: focus, content: form))
        view.sizingOptions = []
    }

    func show(_ form: Form) {
        view.rootView = PaneRoot(focus: focus, content: form)
    }
}

/// A pane that search can take to one of its settings.
@MainActor
protocol SearchablePane: NSViewController {
    /// The setting it is asked to show, and the one it marks.
    var focus: SettingsFocus { get }
}
