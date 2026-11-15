import Foundation

/// Search as you type, as Messages does: chats by name, then messages by their words, from the
/// index on this device. Each keystroke waits 120 ms for the next, and a newer query drops an
/// older answer.
@MainActor
public final class SearchModel {
    public private(set) var query = ""
    public private(set) var hits = SearchHits()
    public var onUpdate: ((_ hits: SearchHits) -> Void)?

    private let session: Session
    private var running: Task<Void, Never>?

    public init(session: Session) {
        self.session = session
    }

    /// How far the index is; nil before it opens.
    public var progress: SearchIndexer.Progress? { session.search?.progress }

    /// The user started searching (the field took the focus): photo search gets ready to find
    /// photos by their look.
    public func prepare() {
        session.search?.photos.prepareForSearch()
    }

    public func search(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != query else { return }
        if query.isEmpty { prepare() }
        query = text
        running?.cancel()
        guard !text.isEmpty else {
            hits = SearchHits()
            onUpdate?(hits)
            return
        }
        running = Task { [session] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let search = session.search else { return }
            let state = Signposts.list.beginInterval("search")
            var found = await search.search(text)
            Signposts.list.endInterval("search", state, "\(found.chats.count) chats, \(found.messages.count) messages")
            guard !Task.isCancelled, text == query else { return }
            found.photoNote = search.photos.searchNote(lookPending: await search.photos.isLookPending)
            hits = found
            onUpdate?(found)
            // the words' hits show at once; the photos found by their look follow once the text
            // encoder has loaded (a second, or some 20 s the first time on a device).
            guard await search.photos.waitForLook(), !Task.isCancelled, text == query else { return }
            var again = await search.search(text)
            guard !Task.isCancelled, text == query else { return }
            again.photoNote = search.photos.searchNote(lookPending: false)
            hits = again
            onUpdate?(again)
        }
    }
}
