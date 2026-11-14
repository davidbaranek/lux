import Foundation

/// The account and its encryption, for the Settings screens.
@MainActor
public final class SettingsModel {
    public private(set) var profile: Profile?
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

    public func load() async {
        guard let account = try? await account.value else { return }
        async let profile = try? account.profile()
        async let verified = account.isDeviceVerified()
        self.profile = await profile
        recovery = account.recoveryState()
        isVerified = await verified
        changes.send()
        // the index's count follows it while Settings shows.
        indexProgress = session.search?.progressChanges.observe { [weak self] in
            Task { await self?.loadSearchIndex() }
        }
        await loadSearchIndex()
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
        recovery = account.recoveryState()
        changes.send()
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
