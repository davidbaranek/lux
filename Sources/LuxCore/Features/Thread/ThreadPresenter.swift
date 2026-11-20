import CoreGraphics
import Foundation

/// What a chat's screen does for its presenter: it shows measured messages (its snapshot and
/// their animation) and puts the list where the presenter says, says where its rows are and where
/// it is scrolled, and glides.
@MainActor
public protocol ThreadScreen: AnyObject {
    /// Shows `messages`, measured; `changed`: the rows that look different (every row after a
    /// relayout). Right after the snapshot is applied and laid out, the list goes where `scroll`
    /// says, once (`place(_:)`): no other code moves it for the update.
    func show(_ messages: [MessageItem], layouts: [String: MessageLayout], changed: [String], scroll: ScrollIntent)
    /// The draft the chat had, for the composer.
    func showDraft(_ text: String)
    /// Where the list is scrolled now.
    var scrollGeometry: ScrollGeometry { get }
    /// The top and bottom of the message's row in the content; nil while it is not in the list.
    func rowSpan(of id: String) -> (minY: CGFloat, maxY: CGFloat)?
    /// Scrolls to `offset`. Animated, it calls `didEndScrolling()` when the glide stops, once; a
    /// later scroll asked for while it goes takes over, and the glide it replaces ends silently.
    /// It stops the reader's own scroll (a fling's momentum): only for a scroll the app asks for.
    func scrollList(to offset: CGFloat, animated: Bool)
    /// The reader moves the list: their finger is on it, or it glides on after a fling.
    var isUserScrolling: Bool { get }
    /// Moves the content `delta` points under the reader, as the list's layout does for rows that
    /// change above them: their drag and the list's momentum go on.
    func shiftList(by delta: CGFloat)
    /// Puts the list where `intent` says, writing nothing when it is there; a glide under way stops
    /// there.
    func place(_ intent: ScrollIntent)
    /// The message a jump brought into view, whose row flashes once as it shows (a row shown
    /// later, or shown again, reads it too); nil once the flash is over.
    func highlight(_ id: String?)
    /// The row the reader looks at: the first whose top half is on screen.
    var readingRow: String? { get }
    /// Opens a Matrix thread of the chat, at one of its messages if given (a jump to a thread's reply).
    func openThread(_ thread: MatrixThread, at message: MessageLink?)
}

extension ThreadScreen {
    /// Puts the list where `intent` says: nowhere when it is there already (an animation to where
    /// it is would never end, and a scroll to it would stop a fling), animated when it asks, else
    /// at once. While the reader scrolls, the content shifts under them instead: a scroll would
    /// stop their fling dead.
    public func place(_ intent: ScrollIntent) {
        let geometry = scrollGeometry
        guard let offset = geometry.offset(for: intent, rowSpan: rowSpan), abs(offset - geometry.offset) > 0.5 else { return }
        if isUserScrolling, !intent.isAnimated { return shiftList(by: offset - geometry.offset) }
        scrollList(to: offset, animated: intent.isAnimated)
    }
}

/// One chat's screen without its views, the same on iPhone and Mac: it opens the chat (the draft,
/// the first unread message, the opening fill, a message to open at), measures every update off
/// the main thread and hands the newest to the screen with where its list goes, brings quoted
/// messages into view, asks for older messages as the reader nears the top, and tells the session
/// the chat is on screen. The screen keeps its views, its snapshot and their animation.
@MainActor
public final class ThreadPresenter {
    public let model: ThreadModel
    public weak var screen: ThreadScreen?
    /// The layouts of the messages, kept while a message and the width stay the same.
    public let layoutCache = MessageLayoutCache()
    /// Measures the messages' text (each platform's fonts); nothing is measured before it is known.
    private var text: (any TextMeasuring)?
    /// The width the messages are measured for; nothing is measured before it is known.
    public private(set) var width: CGFloat = 0
    public let isGroup: Bool
    /// Messages started or stopped coming from the server (after the presenter's own use of it).
    public var onLoading: ((Bool) -> Void)?

    private weak var session: Session?
    /// The chat's rooms, whose notifications it stands for.
    private let rooms: Set<String>
    private let focus: MessageLink?
    /// Removes what the chat's rooms notified (the system's notification centre; a test's own).
    private let removeDelivered: @Sendable (Set<String>) async -> Void
    private let tasks = TaskBag()
    private var styleObservation: AnyObject?

    /// The newest update; an older one still measuring is dropped.
    private var generation = 0
    /// The last update the screen shows: until it catches up, its rows are not the model's.
    private var shownGeneration = 0
    /// The screen is applying an update: rows it puts on screen meanwhile are not the reader's.
    private var isShowing = false
    /// The first messages (or "No messages") are drawn.
    public private(set) var shownFirst = false
    /// Messages are on screen: the next update keeps the reader's place, it does not open the chat.
    private var shownRows = false
    /// Why the updates not shown yet came, as the core says: the strongest of them (a message sent
    /// from here over others arriving), for the one the screen shows next.
    private var cause: ThreadCause?
    /// The rows the screen shows are the live ones (not a jump's).
    private var shownLive = true
    /// The user moved the chat: a first unread message found late no longer moves it.
    public private(set) var userScrolled = false
    /// The first unread message came late: the next update moves the chat to it.
    private var scrollsToLateUnread = false
    /// The message a jump brings into view (a quote, a search result, the way up): every update
    /// centres it, unanimated, until it is shown and nothing loads; then it flashes.
    private var target: String?
    /// The target is shown and nothing loaded: one animated glide brings it to the middle.
    private var gliding = false
    /// The list slides to the newest message (a new one came): it counts as there until it arrives.
    private var followsBottom = false
    /// Bringing a message into view; the reader scrolling ends it.
    public var isJumping: Bool { target != nil }
    /// The message whose shared post's caption the user just unfolded or folded: its next change animates.
    private var unfolding: String?
    /// The reader returned to the live rows: the next update lands at the bottom.
    private var landsAtBottom = false
    /// The update the screen is showing switches the rows between a jump's and the live ones (the
    /// reader's row, the same message in both, keeps its place): it goes in unanimated.
    public private(set) var isSwitching = false

    /// The chat of `row`, or its Matrix thread `thread`; `focus`: a message to open at (a saved one,
    /// a search result).
    public init(session: Session, row: ChatRow, thread: MatrixThread? = nil, focus: MessageLink? = nil,
                removeDelivered: @escaping @Sendable (Set<String>) async -> Void = { await PushNotifications.removeDelivered(rooms: $0) }) {
        self.removeDelivered = removeDelivered
        model = ThreadModel(session: session, row: row, thread: thread)
        self.session = session
        rooms = Set([row.id] + row.rooms.map(\.id))
        isGroup = row.isGroup
        self.focus = focus
        model.onUpdate = { [weak self] messages, cause in
            self?.heard(cause)
            self?.show(messages)
        }
        model.onFirstUnread = { [weak self] _ in self?.showLateFirstUnread() }
        model.onLoading = { [weak self] loading in
            self?.settle()
            self?.onLoading?(loading)
        }
        // bubbles or plain rows, as the chat or Settings has it: every row is measured again.
        styleObservation = session.preferences.chatStyleChanges.observe { [weak self] in self?.remeasure() }
    }

    // MARK: Opening

    /// Opens the chat: its draft, where its unread messages start, its first messages, and the
    /// message it opens at.
    public func start() {
        // the core takes the message the chat opens at as soon as the room's messages are in.
        if let focus { jump(toMessage: focus) }
        tasks.run { [weak self, model] in
            let draft = await model.loadDraft()
            self?.screen?.showDraft(draft)
            await model.findFirstUnread()
            await model.start()
        }
    }

    /// The chat (its thread) offered to the account's other devices while it is on screen.
    private var handoff: NSUserActivity?

    /// On screen: no notifications for the chat (or its thread), and what it notified is seen;
    /// the account's other devices offer to continue it (Handoff).
    /// A thread and its chat can both be on screen (side by side on the Mac).
    public func appeared() {
        model.watchTyping()
        let handoff = handoff ?? ChatActivity(roomId: model.thread?.roomId ?? model.sendRoom, threadRoot: model.thread?.rootEventId).activity()
        self.handoff = handoff
        handoff.becomeCurrent()
        guard let session else { return }
        if let thread = model.thread {
            session.threadsOnScreen.insert(thread.rootEventId)
        } else {
            session.roomsOnScreen = rooms
            tasks.run { [rooms, removeDelivered] in await removeDelivered(rooms) }
        }
    }

    /// Off screen: notifications come again, the draft is kept, and Handoff no longer offers it.
    public func disappeared(draft: String) {
        handoff?.resignCurrent()
        if let thread = model.thread {
            session?.threadsOnScreen.remove(thread.rootEventId)
        } else if session?.roomsOnScreen == rooms {
            session?.roomsOnScreen = []
        }
        model.stopWatchingTyping()
        model.saveDraft(draft)
    }

    // MARK: Measuring

    /// The width changed: every message is measured again for it.
    public func resize(to width: CGFloat) {
        guard width > 0, width != self.width else { return }
        self.width = width
        show(model.messages, relayout: true)
    }

    /// Measures the messages with `text`: the first, or a new text size (every message again).
    public func measure(with text: any TextMeasuring) {
        if self.text != nil { layoutCache.reset() }
        self.text = text
        remeasure()
    }

    private func remeasure() { show(model.messages, relayout: true) }

    /// Measures `new` off the main thread, then the screen shows it, where this update puts the
    /// list, unless a newer update came meanwhile. `relayout`: every row may have a new size.
    public func show(_ new: [MessageItem], relayout: Bool = false) {
        // nothing to draw before the model's first answer (an empty chat is drawn as one).
        guard width > 0, let text, model.hasLoaded else { return }
        generation += 1
        let generation = generation, width = width, cache = layoutCache, isGroup = isGroup
        let firstUnread = model.firstUnreadId, style = model.chatStyle
        tasks.run { [weak self] in
            let state = Signposts.thread.beginInterval("measure")
            let (layouts, changed) = await Self.measure(new, cache: cache, showsSender: isGroup, firstUnread: firstUnread,
                                                        style: style, width: width, text: text)
            Signposts.thread.endInterval("measure", state, "\(new.count) messages, \(changed.count) changed")
            guard let self, generation == self.generation else { return }
            shownGeneration = generation
            present(new, layouts: layouts, changed: relayout ? new.map(\.id) : changed)
        }
    }

    @concurrent
    private static func measure(_ messages: [MessageItem], cache: MessageLayoutCache, showsSender: Bool, firstUnread: String?,
                                style: ChatStyle, width: CGFloat, text: any TextMeasuring) async -> ([String: MessageLayout], [String]) {
        cache.update(messages, showsSender: showsSender, firstUnread: firstUnread, style: style, width: width, measure: text)
    }

    /// Hands an update to the screen with the one place its list goes; a jump's message shown in
    /// the middle with nothing loading has arrived.
    private func present(_ new: [MessageItem], layouts: [String: MessageLayout], changed: [String]) {
        guard let screen else { return }
        isSwitching = shownLive != model.isLive
        shownLive = model.isLive
        let intent = intent(for: layouts)
        cause = nil
        // the update centres the jump's message: a glide under way ends there.
        if case .centre = intent { gliding = false }
        isShowing = true
        screen.show(new, layouts: layouts, changed: changed, scroll: intent)
        isShowing = false
        isSwitching = false
        // sliding to the newest: until it arrives (`didEndScrolling`), the list counts as there.
        followsBottom = intent.isAnimated && screen.scrollGeometry.fromBottom > 0.5
        let opened = !shownRows && !new.isEmpty
        if !new.isEmpty { shownRows = true }
        // the opening fill is a screen or two: the page before it comes at once, while the reader
        // looks, not as they scroll (a page going in under a fling hitches).
        if opened, model.isLive, model.canLoadOlder { model.loadOlder() }
        settle()
        // the update's rows are on screen, in their place: as when the list shows a row.
        displayed(screen.scrollGeometry)
    }

    // MARK: Showing

    /// Keeps why an update came until the screen shows one: a message sent from here outweighs
    /// others arriving.
    private func heard(_ new: ThreadCause?) {
        guard let new, !(new == .arrived && cause != nil) else { return }
        cause = new
    }

    /// The screen drew its first messages (or "No messages").
    public func didShowFirst() { shownFirst = true }

    /// The first unread message was found after the chat opened: its marker shows, and a chat the
    /// user has not moved yet opens there, as it would have at once.
    private func showLateFirstUnread() {
        scrollsToLateUnread = shownFirst && !userScrolled
        show(model.messages)
    }

    /// Unfolds or folds a shared post's caption: its next change animates.
    public func togglePost(of id: String) {
        unfolding = id
        model.togglePost(of: id)
    }

    /// Whether `changed` has the caption the user unfolded or folded, to animate; asked once.
    public func takeUnfolding(in changed: [String]) -> Bool {
        guard let id = unfolding, changed.contains(id) else { return false }
        unfolding = nil
        return true
    }

    // MARK: Scrolling

    /// Where the update whose rows are `shown` (their layouts) leaves the list, decided once, in
    /// this order: a message the user just sent, at the bottom (a jump under way gives way); the
    /// jump's message in the middle; a chat opening at its first unread message; the reader's
    /// return to the live rows, at the newest; a first unread message found late; else where the
    /// reader is, sliding to the newest messages that arrived.
    private func intent(for shown: [String: MessageLayout]) -> ScrollIntent {
        if shownRows, model.isLive, case .sent(let echo) = cause, shown[echo] != nil {
            target = nil
            gliding = false
            return .bottom(animated: !model.isLoading)
        }
        if let id = target, shown[id] == nil, !model.messages.contains(where: { $0.id == id }) {
            // the jump's message left the chat (the rows switched): nothing to bring into view.
            target = nil
            gliding = false
        }
        if let target, shown[target] != nil { return .centre(target) }
        if !shownRows { return model.firstUnreadId.map { .firstUnread($0) } ?? .bottom(animated: false) }
        if model.isLive, landsAtBottom {
            landsAtBottom = false
            return .bottom(animated: false)
        }
        if scrollsToLateUnread {
            scrollsToLateUnread = false
            if let unread = model.firstUnreadId { return .firstUnread(unread) }
        }
        // new messages at the newest slide in, as Messages has them; the opening, pages and a
        // switch of the rows do not (the core gives them no cause).
        return standingIntent(animated: cause == .arrived && !model.isLoading)
    }

    /// Where the list stays through a change that is not the reader's (an update, a new inset):
    /// on the jump's message, at the newest (`animated`: sliding there), or on the row the reader
    /// looks at. A list still sliding to the newest counts as there. While the reader scrolls it
    /// is theirs: it stays on their row, wherever their fling takes it.
    public func standingIntent(animated: Bool = false) -> ScrollIntent {
        guard let screen else { return .none }
        if let target, screen.rowSpan(of: target) != nil { return .centre(target) }
        let geometry = screen.scrollGeometry
        if !screen.isUserScrolling, followsBottom || geometry.isAtBottom { return .bottom(animated: animated) }
        guard let row = screen.readingRow, let span = screen.rowSpan(of: row) else { return .none }
        return .keep(row, top: span.minY - geometry.offset)
    }

    /// Runs `change` (a new inset, rows measured again), which moves the content, and puts the
    /// list back where it was: on the jump's message, at the newest, or on the row read.
    public func keepingPlace(during change: () -> Void) {
        let intent = standingIntent()
        change()
        guard let screen else { return }
        if case .centre = intent { gliding = false }
        screen.place(intent)
        followsBottom = false
        settle()
    }

    /// The reader took the chat over (dragged it, scrolled it, went to the newest): a jump under
    /// way stops there, unflashed, and a first unread message found late no longer moves the chat.
    public func userStartedScrolling() {
        userScrolled = true
        followsBottom = false
        target = nil
        gliding = false
    }

    /// The list put a row on screen: older messages are asked for as the reader nears the top,
    /// and newer ones of a jump's rows near their end, unless the screen still shows an older
    /// update or is applying one.
    public func displayed(_ geometry: ScrollGeometry) {
        guard shownFirst, !isShowing, shownGeneration == generation else { return }
        if !model.isLive {
            // a jump's rows: the switch back to live keeps the row read; newer ones come near the end.
            if let row = screen?.readingRow { model.setAnchor(row) }
            if geometry.nearsBottom, model.canLoadNewer { model.loadNewer() }
        }
        if geometry.nearsTop, model.canLoadOlder { model.loadOlder() }
    }

    // MARK: Jumping to a message

    /// Brings the message a quote answers into view, once the core brought it in.
    public func jump(toRepliedMessageOf id: String) {
        tasks.run("jump") { [weak self, model] in
            let landed: Result<JumpResult, JumpError>
            do throws(JumpError) { landed = .success(try await model.repliedMessage(of: id)) } catch { landed = .failure(error) }
            self?.land(landed)
        }
    }

    /// Brings a message of the chat into view (a saved one, a search result): among the live rows,
    /// or a jump's rows around it.
    public func jump(toMessage message: MessageLink) {
        tasks.run("jump") { [weak self, model] in
            let landed: Result<JumpResult, JumpError>
            do throws(JumpError) { landed = .success(try await model.jump(to: message)) } catch { landed = .failure(error) }
            self?.land(landed)
        }
    }

    /// Where a jump landed: its row, brought into view; its Matrix thread, opened at it; or why not.
    private func land(_ landed: Result<JumpResult, JumpError>) {
        switch landed {
        case .success(.here(let row)): jump(to: row)
        case .success(.inThread(let thread, let message)): screen?.openThread(thread, at: message)
        case .failure(let error): model.onError?(error)
        }
    }

    /// "Jump to bottom": a jump's rows give way to the live ones, at the newest; `false` when the
    /// rows are live already (the screen scrolls down itself).
    public func returnToLive() -> Bool {
        guard !model.isLive else { return false }
        landsAtBottom = true
        model.returnToLive()
        return true
    }


    /// Brings the first unread message into view, as a quoted one.
    public func jumpToFirstUnread() {
        guard let id = model.firstUnreadId else { return }
        jump(to: id)
    }

    /// The message to bring into view. Shown, with nothing loading, it glides to the middle (from a
    /// screen away when it is far); while messages load, it is put in the middle at once, and every
    /// update keeps it there; not shown yet, the update that shows it does.
    private func jump(to id: String) {
        target = id
        gliding = false
        guard let screen, let span = screen.rowSpan(of: id), shownRows, !isShowing, shownGeneration == generation else { return }
        guard !model.isLoading else { return screen.place(.centre(id)) }
        let geometry = screen.scrollGeometry
        let plan = JumpPlan(toRowFrom: span.minY, to: span.maxY, in: geometry)
        guard !plan.arrived(from: geometry.offset) else { return settle() }
        if let start = plan.start { screen.scrollList(to: start, animated: false) }
        gliding = true
        screen.scrollList(to: plan.end, animated: true)
    }

    /// An animated scroll ended: the list slid to the newest, or the glide's message is put in the
    /// middle, should anything have moved it meanwhile, and flashes.
    public func didEndScrolling() {
        followsBottom = false
        guard gliding, let target, let screen else { return }
        gliding = false
        screen.place(.centre(target))
        settle()
    }

    /// The jump's message is in the middle, no glide goes, and nothing loads: it has arrived, and
    /// flashes. Until then each update (or the glide's end) brings it back to the middle.
    private func settle() {
        guard let id = target, !gliding, !model.isLoading, shownGeneration == generation, !isShowing,
              screen?.rowSpan(of: id) != nil else { return }
        target = nil
        highlight(id)
    }

    /// The message's row flashes, then the highlight ends.
    private func highlight(_ id: String) {
        screen?.highlight(id)
        tasks.run("highlight") { [weak self] in
            try await Task.sleep(for: Self.flash)
            self?.screen?.highlight(nil)
        }
    }

    /// How long the jump's message stays highlighted: its rows' pulse.
    public static let flash = Duration.milliseconds(1_600)
}
