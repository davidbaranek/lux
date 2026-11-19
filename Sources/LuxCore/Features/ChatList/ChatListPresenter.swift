import Foundation

/// The list's sections as a screen draws them, with what it needs to know about the change.
public struct ChatListUpdate {
    public var sections: [ChatSection]
    /// The ids of rows that were there before and now show something else.
    public var changed: [String]
    /// The first chats the list shows: they appear at once, unanimated.
    public var isFirst: Bool
    /// Another place's chats: they replace the last place's at once (a quick cross-fade), not row by row.
    public var isNewPlace: Bool
    /// The sections' titles by section id (a space's own spaces); a section without one has no header.
    public var titles: [String: String]
    /// The chats drawn as a grid (the inbox's pinned ones), and their section.
    public var pinned: [ChatRow]
    public var gridSections: Set<String>
}

/// What a chat list's screen does for its presenter: it draws the list and the activity bubble,
/// and scrolls itself for the benchmark.
@MainActor
public protocol ChatListScreen: AnyObject {
    func show(_ update: ChatListUpdate)
    /// What the app is doing, for the bubble (nil: nothing, the bubble goes); `toggles`: it
    /// appears or goes now, rather than changing its words.
    func showActivity(_ activity: ListActivity?, toggles: Bool)
    /// `-LuxBenchmark`: the list scrolls itself, then opens `rows`' first group.
    func runBenchmark(_ rows: [ChatRow])
}

/// The chat list's screen without its views, the same on iPhone and Mac: it reads the list once
/// the screen is there, tells the screen each update with what changed about it (the first
/// chats, another place), and keeps the activity bubble (connecting, loading chats, preparing
/// search, a network to sign in to again) following the list, the networks and the search index.
@MainActor
public final class ChatListPresenter {
    public let model: ChatListModel
    /// The screen may come after the list's first batches (a scene connected in the background
    /// loads its views once it shows): it is told the bubble and the list as they are now.
    public weak var screen: ChatListScreen? {
        didSet {
            screen?.showActivity(activity, toggles: true)
            if model.hasShown { show(model.sections, changed: []) }
        }
    }
    private weak var session: Session?
    private let tasks = TaskBag()
    private var shownFirst = false
    private var shownPlace: Place?
    /// What the bubble says now; nil while it is gone.
    public private(set) var activity: ListActivity?
    private var searchOpened: AnyObject?
    private var searchProgress: AnyObject?
    private var networksChanged: AnyObject?

    public init(session: Session, model: ChatListModel) {
        self.session = session
        self.model = model
        activity = Self.describe(model, session)
        model.onUpdate = { [weak self] sections, changed in self?.show(sections, changed: changed) }
        model.onLoadState = { [weak self] _ in self?.updateActivity() }
        // the index and the networks open a moment after the account: followed once they have.
        searchOpened = session.searchChanges.observe { [weak self] in self?.follow() }
        follow()
    }

    /// The screen is there: the list reads what it cannot follow by itself.
    public func start() {
        model.reload()
    }

    // MARK: Updates

    private func show(_ sections: [ChatSection], changed: [String]) {
        // no screen yet: it draws the sections as they are once it comes.
        guard let screen else { return }
        let isFirst = !shownFirst
        shownFirst = true
        let isNewPlace = !isFirst && shownPlace != model.place
        shownPlace = model.place
        let grid = sections.filter { $0.style == .grid }
        let update = ChatListUpdate(
            sections: sections, changed: changed, isFirst: isFirst, isNewPlace: isNewPlace,
            titles: Dictionary(sections.compactMap { section in section.title.map { (section.id, $0) } }, uniquingKeysWith: { first, _ in first }),
            pinned: grid.flatMap(\.rows), gridSections: Set(grid.map(\.id)))
        screen.show(update)
        guard isFirst else { return }
        let rows = sections.flatMap(\.rows)
        Signposts.firstChatsShown(count: rows.count)
        // a moment for the first chats' pictures to come, then the list scrolls itself.
        if LaunchOptions.isBenchmark {
            tasks.run("benchmark") { [weak self] in
                try await Task.sleep(for: .seconds(2))
                self?.screen?.runBenchmark(rows)
            }
        }
    }

    // MARK: The activity bubble

    private func follow() {
        searchProgress = session?.search?.progressChanges.observe { [weak self] in self?.updateActivity() }
        networksChanged = session?.networks?.changes.observe { [weak self] in self?.updateActivity() }
        updateActivity()
    }

    private func updateActivity() {
        guard let session else { return }
        let new = Self.describe(model, session)
        let toggles = (new == nil) != (activity == nil)
        guard new != activity else { return }
        activity = new
        screen?.showActivity(new, toggles: toggles)
    }

    private static func describe(_ model: ChatListModel, _ session: Session) -> ListActivity? {
        ListActivity.describe(model.loadState, search: session.search?.progress, networks: session.networks?.attention ?? [])
    }
}
