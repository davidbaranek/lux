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

    /// Search finds photos too (read on this device); off until the user turns it on.
    public var searchesPhotos: Bool { session.search?.photos.isOn ?? Preferences.shared.searchesPhotos }

    /// Where photo search is, in words: "Downloading the model · 40 %", "1 200 of 5 000 photos
    /// read"; nil while it is off.
    public var photoSearchStatus: String? {
        switch session.search?.photos.state {
        case nil, .off: nil
        case .downloading(let fraction):
            String(localized: "Downloading the model · \(fraction.formatted(.percent.precision(.fractionLength(0))))")
        case .on(let read, let total, _, let hasModel):
            hasModel || total == 0
                ? String(localized: "\(read.formatted(.number)) of \(total.formatted(.number)) photos read")
                : String(localized: "The model is not on this device: only the words in photos are read")
        }
    }

    /// Turns photo search on (the model downloads, the photos are read on this device) or off
    /// (what was read and the model go).
    public func setSearchesPhotos(_ on: Bool) async {
        guard let photos = session.search?.photos else { return }
        if on { photos.turnOn() } else { await photos.turnOff() }
        changes.send()
    }

    private let account: Task<RustAccount, any Error>
    private let session: Session
    private var indexProgress: AnyObject?
    private var photoProgress: AnyObject?
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
        photoProgress = session.search?.photos.changes.observe { [weak self] in self?.changes.send() }
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
