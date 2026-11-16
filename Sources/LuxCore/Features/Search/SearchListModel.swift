import Foundation

/// One kind of what chats shared, on its own page ("Show All" from search): all of it, or what
/// has the words typed in its own field, which starts with the search's. A page at a time, the
/// next as the list nears its end.
@MainActor
public final class SearchListModel {
    public let kind: SearchKind
    public private(set) var query: String
    /// What is loaded: only `kind`'s list is filled.
    public private(set) var hits = SearchHits()
    /// No more is left to load.
    public private(set) var isAtEnd = false
    /// The first page came: an empty list is empty, not loading.
    public private(set) var hasLoaded = false
    public var onUpdate: ((_ hits: SearchHits) -> Void)?

    private let session: Session
    private var running: Task<Void, Never>?
    private var loading = false

    init(session: Session, kind: SearchKind, query: String) {
        self.session = session
        self.kind = kind
        self.query = query
        reload(after: .zero)
    }

    public func search(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != query else { return }
        query = text
        reload(after: .milliseconds(120))
    }

    /// The list nears its end: the next page.
    public func loadMore() {
        guard !loading, !isAtEnd, running == nil else { return }
        loading = true
        let (kind, query, offset) = (kind, query, hits.count(of: kind))
        Task { [session] in
            defer { loading = false }
            guard let search = session.search else { return }
            let page = await search.list(kind, query, offset: offset, limit: kind.page)
            guard query == self.query, running == nil else { return }
            isAtEnd = page.count(of: kind) < kind.page
            hits.append(page, of: kind)
            onUpdate?(hits)
        }
    }

    private func reload(after wait: Duration) {
        running?.cancel()
        let (kind, query) = (kind, query)
        running = Task { [session] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let search = session.search else { return }
            if kind == .photos, !query.isEmpty { search.photos.prepareForSearch() }
            var page = await search.list(kind, query, offset: 0, limit: kind.page)
            guard !Task.isCancelled else { return }
            page.isLookPending = kind == .photos && !query.isEmpty ? await search.photos.isLookPending : false
            show(page)
            // the photos found by their look follow once the text encoder has loaded.
            guard page.isLookPending, await search.photos.waitForLook(), !Task.isCancelled else { return running = nil }
            show(await search.list(kind, query, offset: 0, limit: kind.page))
            running = nil
        }
    }

    private func show(_ page: SearchHits) {
        guard !Task.isCancelled else { return }
        isAtEnd = page.count(of: kind) < kind.page
        hasLoaded = true
        hits = page
        running = page.isLookPending ? running : nil
        onUpdate?(page)
    }
}
