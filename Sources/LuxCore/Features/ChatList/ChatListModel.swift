import Foundation

/// The chat list of one place, newest message first, and the places with their unread counts.
/// The list itself lives in the Rust core (`lux_core::list`), which composes it and sends one
/// batch of row diffs per frame; this adapter applies each batch on the main actor and tells the
/// UI which rows changed, and forwards the user's intents.
@MainActor
public final class ChatListModel {
    /// The sections of the place shown. A batch the core sent before it took the newest place
    /// asked for is of the place before: it builds `listed`, and shows with the newest place's.
    public private(set) var sections: [ChatSection] = []
    /// Every row shown, in order.
    public var rows: [ChatRow] { sections.flatMap(\.rows) }
    public private(set) var places: [PlaceItem] = []
    /// The place the list shows; setting it shows that place's chats. The user's choice: a batch
    /// changes it only when it shows the newest choice and the core moved away from it (the place
    /// went away), never with a place asked for before it.
    public var place: Place = .inbox {
        didSet {
            guard place != oldValue, !followingPlace, let list else { return }
            askedSelection = list.select(place)
        }
    }
    /// The newest selection asked of the core (0: the place the list opened at), and the newest a
    /// batch showed.
    private var askedSelection: UInt64 = 0
    private var shownSelection: UInt64 = 0
    /// The core's sections as its batches built them, shown once they are of the newest place.
    private var listed: [ChatSection] = []
    /// The rows changed in batches of a place asked for before, and whether there were any such
    /// batches: they show with the newest place's.
    private var heldChanges: [String] = []
    private var held = false
    /// Which of the place's chats show; nil shows them all.
    public var filter: ChatFilter? {
        didSet {
            guard filter != oldValue else { return }
            if filter == .drafts { list?.setDrafts(preferences.chatsWithDrafts) }
            list?.setFilter(filter)
        }
    }

    /// The order of the place's chats; kept on this device.
    public var order: ChatOrder {
        didSet {
            guard order != oldValue else { return }
            preferences.chatOrder = order
            list?.setOrder(order)
        }
    }

    /// Puts the places in this order (the user dragged one); shown at once, kept with the account.
    public func reorder(_ places: [Place]) { list?.reorder(places) }

    /// Hides a place from the rail, or shows it again; the inbox always shows.
    public func setHidden(_ place: Place, _ hidden: Bool) { list?.setHidden(place, hidden) }

    /// Shows every hidden place again.
    public func showAllPlaces() { list?.showAllPlaces() }

    /// The colour of the places without one of their own; kept with the account.
    public private(set) var defaultTheme = PlaceTheme.neutral

    /// The colour the shown place shows in.
    public var theme: PlaceTheme { places.first { $0.id == place }?.theme ?? defaultTheme }

    /// Gives a place its own colour, or (nil) the one for every place; shown at once, kept with the account.
    public func setTheme(_ place: Place, _ theme: PlaceTheme?) { list?.setTheme(place, theme) }

    /// Sets the colour of the places without one of their own.
    public func setDefaultTheme(_ theme: PlaceTheme) { list?.setDefaultTheme(theme) }

    /// The chats (by id) a place's rule keeps out of the inbox, into low priority, with that place.
    private var keptOut: [String: Place] = [:]

    /// The network or space whose rule keeps a chat out of the inbox, into low priority; nil
    /// when none does.
    public func keepingOut(_ chatId: String) -> PlaceItem? {
        guard let place = keptOut[chatId] else { return nil }
        return places.first { $0.id == place }
    }

    /// Says how much of a network's or a space's chats the inbox shows; what it keeps out is of
    /// low priority. Shown at once, kept with the account.
    public func setInbox(_ place: Place, _ rule: InboxRule) { list?.setInbox(place, rule) }

    /// Sets when a chat's messages notify.
    public func setNotifications(_ chatId: String, _ setting: NotificationSetting) { list?.setNotifications(chatId, setting) }

    /// Sets when each chat a network or a space has now notifies, as if set on its own.
    public func setNotifications(_ place: Place, _ setting: NotificationSetting) { list?.setNotifications(place, setting) }

    /// Shows the list again with what may have changed outside it (drafts, for the Drafts filter).
    public func refresh() {
        if filter == .drafts { list?.setDrafts(preferences.chatsWithDrafts) }
    }

    /// The new sections, and the ids of rows that were there before and now show something else.
    public var onUpdate: ((_ sections: [ChatSection], _ changed: [String]) -> Void)?
    public var onPlaces: ((_ places: [PlaceItem]) -> Void)?
    /// The app's badge (the inbox's count, `PlaceItem.unread`), with what the notification
    /// extension needs to keep it while the app is not running.
    public var onBadge: ((BadgeState) -> Void)?
    public var onError: ((Error) -> Void)?

    /// How far the list is: no chats yet; the chats this device keeps shown while the server's
    /// first answer comes (with the chats that arrived since, on a first sign-in); done once the
    /// server has answered and no more chats arrive.
    public enum LoadState: Equatable, Sendable {
        case loading
        case syncing(newChats: Int)
        case done
    }
    public private(set) var loadState = LoadState.loading {
        didSet {
            guard loadState != oldValue else { return }
            if loadState == .done {
                Log.metrics.notice("launch: chats up to date at \(Signposts.sinceProcessStart(), format: .fixed(precision: 3), privacy: .public) s")
            }
            onLoadState?(loadState)
        }
    }
    public var onLoadState: ((LoadState) -> Void)?
    private var answered = false

    private let account: Task<any ChatListPort, any Error>
    private let preferences: Preferences
    /// The core's list: it takes intents at once, also before its account opens. Nil when
    /// signed out.
    private let list: (any ChatListView)?
    private var following: Task<Void, Never>?
    private var scheduledObserver: AnyObject?
    /// The place is set from a batch (the shown place went away): not asked of the core again.
    private var followingPlace = false
    /// What measures how long `chat(ofRoom:within:)` waits: the system's clock, or a test's.
    private let clock: any Clock<Duration>

    public init(session: Session, clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
        account = Task { [account = session.account] in try await account.value }
        preferences = session.preferences
        order = preferences.chatOrder
        list = session.openChatList(place: .inbox, filter: nil, order: order, drafts: preferences.chatsWithDrafts)
        // in order: each batch builds on the one before.
        following = Task { [weak self, events = list?.events] in
            guard let events else { return }
            for await event in events {
                guard let self else { return }
                switch event {
                case .batch(let batch): apply(batch)
                case .failed(let error): onError?(error)
                }
            }
        }
        scheduledObserver = session.scheduledChanges.observe { [weak self] in self?.list?.refresh() }
    }

    isolated deinit {
        following?.cancel()
        for waiter in batchWaiters.values { waiter.resume() }
    }

    /// The list follows the account by itself; this reads what it cannot follow (the waiting
    /// messages) again (pull to refresh).
    public func reload() {
        list?.refresh()
    }

    /// The chat a room is part of (a merged chat's, else the room's own). Right after launch the
    /// account may not list it yet: it asks again at each of the list's next batches, up to `limit`.
    public func chat(ofRoom roomId: String, within limit: Duration = .seconds(5)) async -> ChatRow? {
        // a local the call opens as its own clock type (a stored existential is not opened).
        let clock = clock
        return await waitForChat(ofRoom: roomId, within: limit, on: clock)
    }

    private func waitForChat(ofRoom roomId: String, within limit: Duration, on clock: some Clock<Duration>) async -> ChatRow? {
        let deadline = clock.now.advanced(by: limit)
        while true {
            let found = await bestEffort("the chat of a room") { try await account.value.chats(ofRooms: [roomId])[roomId] }
            if let row = found ?? nil { return row }
            guard clock.now < deadline, !Task.isCancelled else { return nil }
            await nextBatch(before: deadline, on: clock)
        }
    }

    /// Those waiting for the list's next batch.
    private var batchWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Returns at the list's next batch, at `deadline`, or once cancelled, whichever comes first.
    private func nextBatch<C: Clock<Duration>>(before deadline: C.Instant, on clock: C) async {
        let id = UUID()
        let timeout = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline, tolerance: nil)
            } catch {
                // the batch came first, or the wait was cancelled: the waiter has already gone.
                return
            }
            self?.resumeWaiter(id)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { batchWaiters[id] = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeWaiter(id) }
        }
        timeout.cancel()
    }

    private func resumeWaiter(_ id: UUID) {
        batchWaiters.removeValue(forKey: id)?.resume()
    }

    /// A batch of the newest place showed: `sections` are the list, not the empty one before it.
    public private(set) var hasShown = false

    private func apply(_ batch: ChatListBatch) {
        defer { for id in Array(batchWaiters.keys) { resumeWaiter(id) } }
        let state = Signposts.list.beginInterval("batch")
        let first = !hasShown
        if let selection = batch.selection { shownSelection = selection }
        let current = shownSelection == askedSelection
        let changed = listed.apply(batch)
        saved.merge(batch.saved) { _, new in new }
        scheduled.merge(batch.scheduled) { _, new in new }
        if let labels = batch.labels { self.labels = labels }
        if let keptOut = batch.keptOut { self.keptOut = keptOut }
        if let badge = batch.badge { onBadge?(badge) }
        if let reminders = batch.reminders {
            notifications.sync(reminders.map { (roomId: $0.chatId, name: $0.name, date: $0.date) })
        }
        if current, batch.place != place {
            followingPlace = true
            place = batch.place
            followingPlace = false
        }
        if let loading = batch.loading {
            if loading.answered, !answered {
                answered = true
                Log.metrics.notice("launch: first sync answered at \(Signposts.sinceProcessStart(), format: .fixed(precision: 3), privacy: .public) s")
            }
            loadState = loading.state
        }
        if let theme = batch.theme { defaultTheme = theme }
        if let places = batch.places {
            self.places = places
            onPlaces?(places)
        } else if batch.theme != nil {
            onPlaces?(places)
        }
        Signposts.list.endInterval("batch", state, "\(changed.count) changed")
        guard current else {
            heldChanges.append(contentsOf: changed)
            held = true
            return
        }
        guard first || held || batch.sections != nil || !batch.rows.isEmpty else { return }
        sections = listed
        let shownChanges = heldChanges + changed
        heldChanges.removeAll()
        held = false
        if first {
            for row in sections.flatMap(\.rows).prefix(Self.prefetchedOnLaunch) { prefetch(row.id) }
        }
        hasShown = true
        onUpdate?(sections, shownChanges)
    }

    // MARK: Prefetching

    /// How many of the newest chats open ahead of time after launch.
    static let prefetchedOnLaunch = 5
    private var prefetched: Set<String> = []
    private var prefetching: Task<Void, Never>?

    /// Starts opening a chat the user is about to open (the pointer is over it, a finger is down).
    /// Each chat once; one at a time, behind what the user does.
    public func prefetch(_ roomId: String) {
        // a request's room is not the account's yet: it has no chat to open, and the server
        // refuses its messages.
        guard place != .requests, prefetched.insert(roomId).inserted else { return }
        let previous = prefetching, account = account
        prefetching = Task(priority: .utility) {
            await previous?.value
            let state = Signposts.thread.beginInterval("prefetch")
            defer { Signposts.thread.endInterval("prefetch", state) }
            // ahead of the user: a failure costs only the head start, the chat opens as usual.
            await bestEffort("prefetch a chat") { try await account.value.prefetch(roomId: roomId, thread: nil) }
        }
    }

    /// Marks a chat unread, or read.
    public func setUnread(_ roomId: String, _ unread: Bool) {
        list?.change(roomId, unread ? .unread : .read)
    }

    // MARK: Saved, reminders, scheduled

    /// What a row of the list leads to: a chat, a message in it (Saved), a waiting message, a request.
    public enum Destination: Sendable {
        case chat(ChatRow)
        case message(ChatRow, MessageLink)
        case scheduled(ScheduledMessage)
        case request(ChatRow)
    }

    /// The saved and the waiting messages the list showed, by their row's id.
    private var saved: [String: SavedMessage] = [:]
    private var scheduled: [String: ScheduledMessage] = [:]

    public func destination(of row: ChatRow) -> Destination {
        if place == .requests { return .request(row) }
        if let saved = saved[row.id] {
            var chat = row
            chat.id = saved.roomId
            return .message(chat, MessageLink(roomId: saved.roomId, eventId: saved.id))
        }
        if let waiting = scheduled[row.id] { return .scheduled(waiting) }
        return .chat(row)
    }

    /// Reminds the user to answer a chat (asking once to show notifications), or stops.
    public func setReminder(_ roomId: String, at date: Date?) {
        Task { [list, notifications] in
            if date != nil { await notifications.requestPermission() }
            list?.setReminder(roomId, at: date)
        }
    }

    public func unsave(_ saved: SavedMessage) {
        list?.unsave(roomId: saved.roomId, eventId: saved.id)
    }

    public func saved(of row: ChatRow) -> SavedMessage? { saved[row.id] }

    public func cancel(_ waiting: ScheduledMessage) {
        list?.cancelScheduled(id: waiting.id)
    }

    private let notifications = ReminderNotifications()

    /// Does one of a chat's menu actions; the list follows when the change comes.
    public func change(_ roomId: String, _ change: ChatChange) {
        list?.change(roomId, change)
    }

    // MARK: Merged chats

    /// Shows `other` (one person's chat on another network) together with `row`, as one chat
    /// named as `row`, writing where `row` does.
    public func merge(_ row: ChatRow, with other: ChatRow) {
        guard row.id != other.id else { return }
        list?.merge([row.id, other.id], name: row.name, defaultRoom: row.defaultRoom ?? row.id)
    }

    /// Shows a merged chat's rooms as their own chats again.
    public func unmerge(_ row: ChatRow) {
        list?.unmerge(row.id)
    }

    /// Accepts or declines a request.
    public func answer(request roomId: String, accept: Bool) {
        list?.answer(request: roomId, accept: accept)
    }

    /// Labels the user can put a chat in, and whether it is in each.
    public private(set) var labels: [ChatLabel] = []

    public func setChat(_ roomId: String, inLabel id: String, _ included: Bool) {
        list?.setChat(roomId, inLabel: id, included)
    }

    /// Makes a label and puts the chat in it.
    public func makeLabel(named name: String, with roomId: String?) {
        list?.makeLabel(named: name, with: roomId)
    }

    public func removeLabel(id: String) {
        list?.removeLabel(id: id)
    }

    public func createRoom(name: String) async throws -> String {
        try await account.value.createRoom(name: name)
    }
}
