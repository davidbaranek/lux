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

    /// How far back search reads each chat; changing it reads on at once.
    public var searchHistory: SearchHistory {
        get { Preferences.shared.searchHistory }
        set {
            if let search = session.search {
                search.readHistory(newValue)
            } else {
                Preferences.shared.searchHistory = newValue
            }
            changes.send()
        }
    }

    /// Search finds photos by how they look too (the model, on this device); the words in them
    /// and the messages near them it finds always.
    public var searchesPhotosByLook: Bool {
        session.search?.photos.searchesByLook ?? Preferences.shared.searchesPhotosByLook
    }

    /// Where the photos stand now, in one line: what is happening, never what a button would do.
    /// "Downloading the model · 34 %", "Reading · 120 of 224", "96 photos waiting", "All 224
    /// photos read"; nil before the index opens.
    public var photoStatus: String? {
        guard let photos = session.search?.photos else { return nil }
        let progress = photos.progress
        let byWordsOnly = if case .on(hasModel: false) = photos.looks { true } else { false }
        let status: String
        if case .downloading(let fraction) = photos.looks {
            status = String(localized: "Downloading the model · \(fraction.formatted(.percent.precision(.fractionLength(0))))")
        } else if progress.isReading {
            status = String(localized: "Reading · \(progress.read.formatted(.number)) of \(progress.total.formatted(.number))")
        } else if photos.hasUnread {
            let left = max(progress.total - progress.read, 0).formatted(.number)
            status = switch photos.readNowBlocked {
            case .battery?: String(localized: "\(left) photos waiting · Low Power Mode is on")
            case .data?: String(localized: "\(left) photos waiting · Low Data Mode is on")
            case nil: String(localized: "\(left) photos waiting")
            }
        } else if progress.total == 0 {
            status = String(localized: "No photos yet")
        } else {
            status = String(localized: "All \(progress.total.formatted(.number)) photos read")
        }
        return byWordsOnly ? status + " · " + String(localized: "by their words only") : status
    }

    /// Photos are being read or the model downloads: Settings shows it as under way.
    public var isPhotoWorkUnderWay: Bool {
        guard let photos = session.search?.photos else { return false }
        if case .downloading = photos.looks { return true }
        return photos.progress.isReading
    }

    /// What Settings offers for the photos now: to stop the reading, to read the waiting photos
    /// now, or nothing.
    public enum PhotoAction { case stop, readNow }
    public var photoAction: PhotoAction? {
        guard let photos = session.search?.photos else { return nil }
        if photos.progress.isReading { return .stop }
        return photos.hasUnread && photos.readNowBlocked == nil ? .readNow : nil
    }


    /// Reads every photo not read yet, now; on the iPhone in a task the system shows as a Live
    /// Activity, which goes on when the user leaves the app.
    public func readPhotosNow() {
        session.search?.photos.readNow()
    }

    /// Stops the reading; the rest is read on Read Now, or the next time the app opens.
    public func stopReadingPhotos() async {
        await session.search?.photos.pause()
    }

    /// Turns the search by how photos look on (the model downloads; the photos are read again
    /// while the app is open) or off (the model and what it read go).
    public func setSearchesPhotosByLook(_ on: Bool) async {
        await session.search?.photos.setSearchesByLook(on)
        changes.send()
    }

    private let account: Task<any SecurityPort, any Error>
    private let session: Session
    private var indexProgress: AnyObject?
    private var photoProgress: AnyObject?
    private var securityChanges: AnyObject?
    private var profileChanges: AnyObject?

    public init(session: Session) {
        self.session = session
        account = Task { [account = session.account] in try await account.value }
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
        // the index reports many times a second while it reads: its count (a query of the index)
        // follows at most once a second, the newest report's.
        indexProgress = session.search?.progressChanges.observe { [weak self] in
            self?.indexCount.schedule { await self?.loadSearchIndex() }
        }
        photoProgress = session.search?.photos.changes.observe { [weak self] in self?.changes.send() }
        await loadSearchIndex()
    }

    private func loadSecurity() async {
        guard let account = await bestEffort("settings: the account", { try await account.value }) else { return }
        isVerified = await account.isDeviceVerified()
        recovery = account.recoveryState()
        changes.send()
    }

    private func loadSearchIndex() async {
        let summary = await bestEffort("settings: the search index") { try await session.search?.summary() } ?? nil
        // the screens lay out again only for what changed.
        guard summary != searchIndex else { return }
        searchIndex = summary
        changes.send()
    }

    /// The index's count, read one at a time, at most once a second.
    private let indexCount = Throttle(interval: .seconds(1))

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
