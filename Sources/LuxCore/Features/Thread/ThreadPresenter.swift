import CoreGraphics
import Foundation

/// What a chat's screen does for its presenter: it shows measured messages (its snapshot and
/// their animation), says where its rows are and where it is scrolled, and scrolls.
@MainActor
public protocol ThreadScreen: AnyObject {
    /// Shows `messages`, measured; `changed`: the rows that look different (every row after a relayout).
    func show(_ messages: [MessageItem], layouts: [String: MessageLayout], changed: [String])
    /// The draft the chat had, for the composer.
    func showDraft(_ text: String)
    /// Where the list is scrolled now.
    var scrollGeometry: ScrollGeometry { get }
    /// The top and bottom of the message's row in the content; nil while it is not in the list.
    func rowSpan(of id: String) -> (minY: CGFloat, maxY: CGFloat)?
    /// Scrolls to `offset`. Animated, it calls `didEndScrolling()` when the glide stops, once; a
    /// later scroll asked for while it goes takes over, and the glide it replaces ends silently.
    func scrollList(to offset: CGFloat, animated: Bool)
    /// Draws the eye to a message the chat glided to.
    func flash(_ id: String)
    /// The row the reader looks at: the first whose top half is on screen.
    var readingRow: String? { get }
    /// Opens a Matrix thread of the chat, at one of its messages if given (a jump to a thread's reply).
    func openThread(_ thread: MatrixThread, at message: MessageLink?)
}

/// One chat's screen without its views, the same on iPhone and Mac: it opens the chat (the draft,
/// the first unread message, the opening fill, a message to open at), measures every update off
/// the main thread and hands the newest to the screen, glides to quoted messages, asks for older
/// messages as the reader nears the top, and tells the session the chat is on screen. The screen
/// keeps its views, its snapshot and their animation.
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
    /// The first messages (or "No messages") are drawn.
    public private(set) var shownFirst = false
    /// The user moved the chat: a first unread message found late no longer moves it.
    public private(set) var userScrolled = false
    /// The first unread message came late: the next update moves the chat to it.
    private var scrollsToLateUnread = false
    /// The message a quote or the way up asked for: glided to (and flashed) once it is shown.
    private var jumpTarget: String?
    /// The message the chat glides to, until it is in the middle of the list and flashes.
    private var gliding: String?
    /// Gliding to a message: older pages wait, one landing above would move it.
    public var isJumping: Bool { gliding != nil }
    /// The message whose shared post's caption the user just unfolded or folded: its next change animates.
    private var unfolding: String?
    /// The rows switched between a jump's and the live ones: this row goes where the reader's was,
    /// `top` below the list's top, once the screen shows it.
    private var switchTo: (id: String, top: CGFloat)?
    /// The reader returned to the live rows: the next update lands at the bottom.
    private var landsAtBottom = false

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
        model.onUpdate = { [weak self] messages in self?.show(messages) }
        model.onSwitch = { [weak self] from, to in self?.switching(from: from, to: to) }
        model.onFirstUnread = { [weak self] _ in self?.showLateFirstUnread() }
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

    /// On screen: no notifications for the chat (or its thread), and what it notified is seen.
    /// A thread and its chat can both be on screen (side by side on the Mac).
    public func appeared() {
        model.watchTyping()
        guard let session else { return }
        if let thread = model.thread {
            session.threadsOnScreen.insert(thread.rootEventId)
        } else {
            session.roomsOnScreen = rooms
            tasks.run { [rooms, removeDelivered] in await removeDelivered(rooms) }
        }
    }

    /// Off screen: notifications come again, and the draft is kept.
    public func disappeared(draft: String) {
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

    /// Measures `new` off the main thread, then the screen shows it, unless a newer update came
    /// meanwhile, and a jump goes on with the rows shown. `relayout`: every row may have a new size.
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
            screen?.show(new, layouts: layouts, changed: relayout ? new.map(\.id) : changed)
            jumpOn()
        }
    }

    @concurrent
    private static func measure(_ messages: [MessageItem], cache: MessageLayoutCache, showsSender: Bool, firstUnread: String?,
                                style: ChatStyle, width: CGFloat, text: any TextMeasuring) async -> ([String: MessageLayout], [String]) {
        cache.update(messages, showsSender: showsSender, firstUnread: firstUnread, style: style, width: width, measure: text)
    }

    // MARK: Showing

    /// The screen drew its first messages (or "No messages").
    public func didShowFirst() { shownFirst = true }

    /// The first unread message was found after the chat opened: its marker shows, and a chat the
    /// user has not moved yet opens there, as it would have at once.
    private func showLateFirstUnread() {
        scrollsToLateUnread = shownFirst && !userScrolled
        show(model.messages)
    }

    /// Whether this update moves the chat to the first unread message, found late; asked once.
    public func takeLateUnreadScroll() -> Bool {
        defer { scrollsToLateUnread = false }
        return scrollsToLateUnread
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

    /// The reader took the chat over (dragged it, scrolled it, went to the newest): a glide under
    /// way stops there, unflashed, and a first unread message found late no longer moves the chat.
    public func userStartedScrolling() {
        userScrolled = true
        gliding = nil
    }

    /// The list scrolled: older messages are asked for as the reader nears the top, unless the
    /// screen still shows an older update or glides to a message.
    public func scrolled(_ geometry: ScrollGeometry) {
        guard shownFirst, !isJumping, shownGeneration == generation else { return }
        if !model.isLive {
            // a jump's rows: the switch back to live keeps the row read; newer ones come near the end.
            if let row = screen?.readingRow { model.setAnchor(row) }
            if geometry.nearsBottom, model.canLoadNewer { model.loadNewer() }
        }
        if geometry.nearsTop, model.canLoadOlder { model.loadOlder() }
    }

    // MARK: Jumping to a message

    /// Glides to the message a quote answers, once the core brought it in.
    public func jump(toRepliedMessageOf id: String) {
        tasks.run("jump") { [weak self, model] in
            let landed: Result<JumpResult, JumpError>
            do throws(JumpError) { landed = .success(try await model.repliedMessage(of: id)) } catch { landed = .failure(error) }
            self?.land(landed)
        }
    }

    /// Glides to a message of the chat (a saved one, a search result): among the live rows, or a
    /// jump's rows around it.
    public func jump(toMessage message: MessageLink) {
        tasks.run("jump") { [weak self, model] in
            let landed: Result<JumpResult, JumpError>
            do throws(JumpError) { landed = .success(try await model.jump(to: message)) } catch { landed = .failure(error) }
            self?.land(landed)
        }
    }

    /// Where a jump landed: its row, glided to; its Matrix thread, opened at it; or why not.
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

    /// The core switched the rows: `to` will go where the reader's `from` is now.
    private func switching(from: String, to: String) {
        guard let screen, let span = screen.rowSpan(of: from) else { return }
        switchTo = (to, span.minY - screen.scrollGeometry.offset)
    }

    /// Glides to the first unread message, as to a quoted one.
    public func jumpToFirstUnread() {
        guard let id = model.firstUnreadId else { return }
        jump(to: id)
    }

    private func jump(to id: String) {
        jumpTarget = id
        jumpIfShown()
    }

    /// After every update the screen shows, the first one too: the switched row keeps its place, a
    /// message asked for glides once its row is shown, and a glide under way aims at its row again,
    /// which the update may have moved, or whose glide it may have stopped.
    private func jumpOn() {
        keepSwitchedRow()
        if jumpTarget != nil { jumpIfShown() } else { glide() }
    }

    /// Once the message asked for is in the list: glide it to the middle, then flash it.
    private func jumpIfShown() {
        guard let target = jumpTarget, screen?.rowSpan(of: target) != nil else { return }
        jumpTarget = nil
        gliding = target
        glide()
    }

    /// Glides to the middle of the message's row, from a screen away when it is far, or, there
    /// already, flashes it; a row gone from the list (the rows switched) ends the glide.
    private func glide() {
        guard let target = gliding, let screen else { return }
        guard let span = screen.rowSpan(of: target) else {
            gliding = nil
            return
        }
        let geometry = screen.scrollGeometry
        let plan = JumpPlan(toRowFrom: span.minY, to: span.maxY, in: geometry)
        if plan.arrived(from: geometry.offset) {
            gliding = nil
            return screen.flash(target)
        }
        if let start = plan.start { screen.scrollList(to: start, animated: false) }
        screen.scrollList(to: plan.end, animated: true)
    }

    /// The rows switched: the reader's message stays where it was; back to live, the newest shows.
    private func keepSwitchedRow() {
        guard let screen, model.isLive else { return }
        if landsAtBottom {
            landsAtBottom = false
            switchTo = nil
            screen.scrollList(to: screen.scrollGeometry.bottomOffset, animated: false)
            return
        }
        guard let kept = switchTo, let span = screen.rowSpan(of: kept.id) else { return }
        switchTo = nil
        screen.scrollList(to: span.minY - kept.top, animated: false)
    }

    /// An update switching the rows between a jump's and the live ones goes in unanimated.
    public var isSwitching: Bool { switchTo != nil || landsAtBottom }

    /// An animated scroll ended: a message glided to flashes, in the middle of the list; a glide
    /// something stopped short of it goes on.
    public func didEndScrolling() { glide() }
}
