import Foundation

/// The account and its encryption, for the Settings screens.
@MainActor
public final class SettingsModel {
    /// The account's name and picture, shared with the other screens that show them.
    public var profile: Profile? { session.profile?.profile }
    public var isSavingProfile: Bool { session.profile?.isSaving ?? false }
    public private(set) var recovery: RecoveryState = .unknown
    /// This device is verified by the account; nil until known.
    public private(set) var isVerified: Bool?
    /// Every Settings screen observes the same model.
    public let changes = Broadcast()

    /// The search index on this device: how many messages, and whether it is still reading.
    public private(set) var searchIndex: String?

    private let account: Task<RustAccount, any Error>
    private let session: Session
    private var indexProgress: AnyObject?
    private var securityChanges: AnyObject?
    private var profileChanges: AnyObject?

    public init(session: Session) {
        self.session = session
        account = session.account
    }

    /// Send read receipts: off by default (a bridged chat's other side sees them).
    public var sendsReadReceipts: Bool {
        get { Preferences.shared.sendsReadReceipts }
        set {
            Preferences.shared.sendsReadReceipts = newValue
            changes.send()
        }
    }

    /// Bubbles or plain rows, for every chat on this device.
    public var chatStyle: ChatStyle {
        get { Preferences.shared.chatStyle }
        set {
            Preferences.shared.chatStyle = newValue
            changes.send()
        }
    }

    public func load() async {
        profileChanges = session.profile?.changes.observe { [weak self] in self?.changes.send() }
        await session.profile?.load()
        await loadSecurity()
        // verified on another device, recovery set up: the rows say so as it happens.
        securityChanges = session.security?.changes.observe { [weak self] in
            Task { await self?.loadSecurity() }
        }
        // the index's count follows it while Settings shows.
        indexProgress = session.search?.progressChanges.observe { [weak self] in
            Task { await self?.loadSearchIndex() }
        }
        await loadSearchIndex()
    }

    private func loadSecurity() async {
        guard let account = try? await account.value else { return }
        isVerified = await account.isDeviceVerified()
        recovery = account.recoveryState()
        changes.send()
    }

    private func loadSearchIndex() async {
        searchIndex = await session.search?.summary()
        changes.send()
    }

    /// Opens the key backup; encrypted messages this device could not read come in as the chats show
    /// again. Throws `AccountFailure.wrongRecoveryKey` for a key that does not.
    public func recover(key: String) async throws {
        let account = try await account.value
        try await account.recover(key: key)
        // the key verifies this device too.
        await loadSecurity()
    }
}

extension RecoveryState {
    public var title: String {
        switch self {
        case .enabled: String(localized: "On")
        case .incomplete: String(localized: "Needs your recovery key")
        case .disabled: String(localized: "Off")
        case .unknown: String(localized: "Checking…")
        }
    }
}
