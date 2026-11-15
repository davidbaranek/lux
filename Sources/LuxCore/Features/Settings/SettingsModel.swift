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

    /// Search finds photos by how they look too (the model, on this device); the words in them
    /// and the messages near them it finds always.
    public var searchesPhotosByLook: Bool {
        session.search?.photos.searchesByLook ?? Preferences.shared.searchesPhotosByLook
    }

    /// The basic index of photos (their words), in words: "224 photos · complete", "180 of 224
    /// photos read"; nil before the index opens.
    public var photoWords: String? {
        guard let progress = session.search?.photos.progress else { return nil }
        return Self.read(progress.withWords, of: progress.total)
    }

    /// The photo search model on this device, in words: not downloaded (search by look is off),
    /// downloading, ready, or not to be had.
    public var photoModel: String {
        switch session.search?.photos.looks {
        case .off?, nil: String(localized: "Not downloaded")
        case .downloading(let fraction)?:
            String(localized: "Downloading · \(fraction.formatted(.percent.precision(.fractionLength(0))))")
        case .on(hasModel: true)?: String(localized: "Ready on this device")
        case .on(hasModel: false)?: String(localized: "Not available: photos are found by their words")
        }
    }

    /// How many photos the model has read (their embeddings), in words; "Off" while search by look
    /// is off.
    public var photoLooks: String {
        guard let photos = session.search?.photos, case .on(hasModel: true) = photos.looks else {
            return searchesPhotosByLook ? String(localized: "Waiting for the model") : String(localized: "Off")
        }
        return Self.read(photos.progress.withEmbedding, of: photos.progress.total)
    }

    private static func read(_ read: Int, of total: Int) -> String {
        read >= total
            ? String(localized: "\(total.formatted(.number)) photos · complete")
            : String(localized: "\(read.formatted(.number)) of \(total.formatted(.number)) photos read")
    }

    /// Photos are being read now: Settings offers to stop.
    public var isReadingPhotos: Bool { session.search?.photos.isReading ?? false }
    /// Some photos wait to be read: Settings offers to read them now.
    public var hasUnreadPhotos: Bool { session.search?.photos.hasUnread ?? false }

    /// Why photos cannot be read now, in words: the device saves its battery or its data; nil
    /// when they can.
    public var readPhotosBlocked: String? {
        switch session.search?.photos.readNowBlocked {
        case .battery?: String(localized: "Not while Low Power Mode is on.")
        case .data?: String(localized: "Not while Low Data Mode is on.")
        case nil: nil
        }
    }

    /// Reads every photo not read yet, now; on the iPhone in a task the system shows as a Live
    /// Activity, which goes on when the user leaves the app.
    public func readPhotosNow() {
        session.search?.photos.readNow()
    }

    /// Stops the reading; the rest is read the next time the app opens, or while it charges.
    public func stopReadingPhotos() async {
        await session.search?.photos.stop()
    }

    /// Turns the search by how photos look on (the model downloads; the photos are read again
    /// while the device charges) or off (the model and what it read go).
    public func setSearchesPhotosByLook(_ on: Bool) async {
        await session.search?.photos.setSearchesByLook(on)
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
