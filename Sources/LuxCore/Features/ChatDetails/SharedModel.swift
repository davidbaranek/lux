import Foundation

/// What a chat shared, of one kind, read back the newest first as the user scrolls. A search keeps
/// what holds its words (a file's name, a link's address or the text around it, the words sent
/// with a photo or a video), read back the same way; photos are found by photo search's index on
/// this device too, by the words in them, the messages sent near them and, when it is on, how
/// they look.
@MainActor
public final class SharedModel {
    public let kind: SharedKind
    /// The newest first.
    public private(set) var items: [SharedItem] = []
    /// The searched words; empty shows everything.
    public private(set) var query = ""
    public private(set) var isLoading = false
    /// Everything was read, back to the chat's start.
    public private(set) var isComplete = false
    public private(set) var failure: AccountFailure?
    public let changes = Broadcast()

    /// How many a page asks for.
    private static let page = 60
    /// How long typing pauses before the search reads the history again.
    private static let typing: Duration = .milliseconds(250)

    private let account: Task<RustAccount, any Error>
    private let chatId: String
    private let originals: URL
    private let photos: @MainActor () -> PhotoSearch?
    private var history: SharedHistory?
    /// What the history gave, and the photos only the index found.
    private var read: [SharedItem] = []
    private var indexed: [SharedItem] = []
    /// The chat's rooms, for the index, once asked.
    private var rooms: [String]?
    /// A new search makes what the last one still brings stale.
    private var generation = 0

    init(account: Task<RustAccount, any Error>, chatId: String, kind: SharedKind, originals: URL,
         photos: @escaping @MainActor () -> PhotoSearch? = { nil }) {
        self.account = account
        self.chatId = chatId
        self.kind = kind
        self.originals = originals
        self.photos = photos
    }

    /// Shows what holds every word of `text` (all, when it has none) once typing pauses, and
    /// returns when its first page is read (or a newer search took over).
    public func search(_ text: String) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != self.query else { return }
        self.query = query
        generation += 1
        let generation = generation
        history = nil
        read = []
        indexed = []
        items = []
        isComplete = false
        isLoading = false
        failure = nil
        changes.send()
        if !query.isEmpty { try? await Task.sleep(for: Self.typing) }
        guard generation == self.generation else { return }
        if !query.isEmpty, kind == .media { await findPhotos(query, generation) }
        await loadMore()
    }

    /// Reads the next page, unless one is on its way or all were read.
    public func loadMore() async {
        guard !isLoading, !isComplete else { return }
        let generation = generation
        isLoading = true
        failure = nil
        changes.send()
        defer {
            if generation == self.generation {
                isLoading = false
                changes.send()
            }
        }
        do {
            let history: SharedHistory
            if let opened = self.history {
                history = opened
            } else {
                history = try await account.value.sharedHistory(chatId: chatId, kind: kind, query: query.isEmpty ? nil : query)
                guard generation == self.generation else { return }
                self.history = history
            }
            let page = try await history.next(Self.page)
            let atStart = await history.isAtStart()
            guard generation == self.generation else { return }
            let known = Set(read.map(\.id))
            read += page.filter { !known.contains($0.id) }
            isComplete = atStart
            merge()
        } catch {
            guard generation == self.generation else { return }
            failure = error as? AccountFailure ?? .connectionFailed
        }
    }

    /// A photo's, video's or file's original on this device, to open.
    public func file(of item: SharedItem) async throws -> URL {
        try await account.value.sharedFile(item, directory: originals)
    }

    /// The chat's photos the index finds for `query`, among those the history gives.
    private func findPhotos(_ query: String, _ generation: Int) async {
        guard let photos = photos() else { return }
        let rooms: [String]
        if let known = self.rooms {
            rooms = known
        } else {
            guard let info = try? await account.value.chatInfo(chatId: chatId) else { return }
            rooms = info.rooms.map(\.id)
            self.rooms = rooms
        }
        let hits = await photos.search(query, in: rooms)
        guard generation == self.generation else { return }
        indexed = hits.map { hit in
            SharedItem(id: "index|\(hit.eventId)", eventId: hit.eventId, roomId: hit.roomId, senderName: hit.senderName, date: hit.date,
                       content: .photo(MessageItem.Photo(ref: .foundPhoto(roomId: hit.roomId, eventId: hit.eventId), width: 0, height: 0)))
        }
        merge()
        changes.send()
    }

    /// What the history gave and the photos only the index found, the newest first.
    private func merge() {
        let given = Set(read.map(\.eventId))
        var seen = Set<String>()
        let found = indexed.filter { !given.contains($0.eventId) && seen.insert($0.eventId).inserted }
        items = found.isEmpty ? read : (read + found).sorted { $0.date > $1.date }
    }
}
