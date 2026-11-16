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
    /// Scrolls to `offset`; animated, it calls `didEndScrolling()` once there.
    func scrollList(to offset: CGFloat, animated: Bool)
    /// Draws the eye to a message the chat glided to.
    func flash(_ id: String)
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
    private let focusEvent: String?
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
    public var userScrolled = false
    /// The first unread message came late: the next update moves the chat to it.
    private var scrollsToLateUnread = false
    /// The message a quote or the way up asked for: glided to (and flashed) once it is shown.
    private var jumpTarget: String?
    /// Gliding to a message: older pages wait, one landing above would move it.
    public private(set) var isJumping = false
    private var flashOnArrival: String?
    /// The message whose shared post's caption the user just unfolded or folded: its next change animates.
    private var unfolding: String?

    /// The chat of `row`, or its Matrix thread `thread`; `focusEvent`: a message to open at (a saved one).
    public init(session: Session, row: ChatRow, thread: MatrixThread? = nil, focusEvent: String? = nil,
                removeDelivered: @escaping @Sendable (Set<String>) async -> Void = { await PushNotifications.removeDelivered(rooms: $0) }) {
        self.removeDelivered = removeDelivered
        model = ThreadModel(session: session, row: row, thread: thread)
        self.session = session
        rooms = Set([row.id] + row.rooms.map(\.id))
        isGroup = row.isGroup
        self.focusEvent = focusEvent
        model.onUpdate = { [weak self] messages in self?.show(messages) }
        model.onFirstUnread = { [weak self] _ in self?.showLateFirstUnread() }
        // bubbles or plain rows, as the chat or Settings has it: every row is measured again.
        styleObservation = Preferences.shared.chatStyleChanges.observe { [weak self] in self?.remeasure() }
    }

    // MARK: Opening

    /// Opens the chat: its draft, where its unread messages start, its first messages, and the
    /// message it opens at.
    public func start() {
        tasks.run { [weak self, model, focusEvent] in
            let draft = await model.loadDraft()
            self?.screen?.showDraft(draft)
            await model.findFirstUnread()
            await model.start()
            guard let focusEvent, let target = await model.message(ofEvent: focusEvent) else { return }
            self?.jump(to: target)
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
    /// meanwhile. `relayout`: every row may have a new size.
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

    /// The list scrolled: older messages are asked for as the reader nears the top, unless the
    /// screen still shows an older update or glides to a message.
    public func scrolled(_ geometry: ScrollGeometry) {
        guard shownFirst, !isJumping, shownGeneration == generation, geometry.nearsTop, model.canLoadOlder else { return }
        model.loadOlder()
    }

    // MARK: Jumping to a message

    /// Glides to the message a quote answers, once the core brought it in.
    public func jump(toRepliedMessageOf id: String) {
        tasks.run("jump") { [weak self, model] in
            guard let target = await model.repliedMessage(of: id) else { return }
            self?.jump(to: target)
        }
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

    /// Once the message asked for is in the list: glide it to the middle, then flash it. The screen
    /// calls this after each update it shows.
    public func jumpIfShown() {
        guard let target = jumpTarget, let screen, let span = screen.rowSpan(of: target) else { return }
        jumpTarget = nil
        let geometry = screen.scrollGeometry
        let plan = JumpPlan(toRowFrom: span.minY, to: span.maxY, in: geometry)
        if let start = plan.start { screen.scrollList(to: start, animated: false) }
        isJumping = true
        flashOnArrival = target
        if plan.arrived(from: geometry.offset) { return didEndScrolling() }
        screen.scrollList(to: plan.end, animated: true)
    }

    /// An animated scroll ended: a message glided to flashes.
    public func didEndScrolling() {
        isJumping = false
        if let id = flashOnArrival { screen?.flash(id) }
        flashOnArrival = nil
    }
}
