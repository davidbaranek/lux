import LuxCore
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Lux

/// A chat's screen over a demo account of its own, seen through its collection view: where the
/// chat opens, and where each kind of update leaves it. No window (but where a test sees an
/// animation's frames): the test reads the scroll view's place, not what is drawn.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ThreadViewTests {
    /// The chat's screen, at `message` if given.
    private func open(_ row: ChatRow, in session: Session, at message: MessageLink? = nil, inWindow: Bool = false) throws -> ShownChat {
        try ShownChat(ThreadViewController(session: session, row: row, theme: .neutral, list: nil, focus: message), inWindow: inWindow)
    }

    @Test func aReadChatOpensAtItsNewestMessage() async throws {
        try await DemoAccount.with(rooms: 10, messagesPerRoom: 60) { session in
            let chat = try open(try await readChat(in: session), in: session)
            // the newest message all on screen: nothing below it.
            try await chat.changes.until { chat.isShown(chat.newest) }
        }
    }

    @Test func aChatOpensAtItsNewestAndStaysThereWhileItsOpeningRowsGoIn() async throws {
        // 1 000 messages a chat: the opening fill, then the page before it, asked for at once and
        // given from what the device holds, go in while the chat is on screen.
        try await DemoAccount.with(rooms: 3, messagesPerRoom: 1_000) { session in
            // in a window: an animated scroll moves the list frame by frame there (without one,
            // UIKit puts it at its end at once), and every frame of it is seen.
            let chat = try open(try await readChat(in: session), in: session, inWindow: true)
            defer { chat.window?.isHidden = true }
            let model = chat.controller.model
            // every state the screen shows once its first rows are in: the newest message all on
            // screen, never the list on its way there.
            var first = 0
            var leftTheNewest = false
            try await chat.changes.until {
                guard chat.newest >= 0 else { return false }
                if first == 0 { first = chat.newest + 1 }
                if !chat.isShown(chat.newest) { leftTheNewest = true }
                return chat.isCurrent && model.messages.count > first && !model.isLoading && model.canLoadOlder
            }
            #expect(!leftTheNewest)
            #expect(chat.isShown(chat.newest))
        }
    }

    @Test func aChatOpenedAtAMessageLandsOnIt() async throws {
        try await DemoAccount.with(rooms: 10, messagesPerRoom: 60) { session in
            let row = try await readChat(in: session)
            // the demo's events are its messages' ids: the chat's sixth message, screens above its newest.
            let target = "\(row.id)/5"
            let chat = try open(row, in: session, at: MessageLink(roomId: row.id, eventId: target))
            try await chat.changes.until { chat.row(ofEvent: target).map(chat.isCentred) == true }
        }
    }

    @Test func aJumpFarBackKeepsItsMessageInTheMiddleWhilePagesArrive() async throws {
        // 400 messages a chat: the device's live timeline holds the newest 200, the message is among a jump's rows.
        try await DemoAccount.with(rooms: 3, messagesPerRoom: 400) { session in
            let row = try await readChat(in: session)
            let target = "\(row.id)/150"
            let chat = try open(row, in: session, at: MessageLink(roomId: row.id, eventId: target))
            let model = chat.controller.model
            try await chat.changes.until { !model.isLive && model.messages.contains { $0.eventId == target } }
            // the reader's way down asks for the next page while the jump is under way.
            let jumped = model.messages.count
            model.loadNewer()
            try await chat.changes.until {
                model.messages.count > jumped && !model.isLoading && chat.isCurrent
                    && chat.row(ofEvent: target).map(chat.isCentred) == true
            }
        }
    }

    @Test func aMessageArrivingAtTheNewestIsFollowedAndAboveItKeepsTheReadersRow() async throws {
        try await DemoAccount.with(rooms: 10, messagesPerRoom: 60) { session in
            let row = try await readChat(in: session)
            let chat = try open(row, in: session)
            try await chat.changes.until { chat.isShown(chat.newest) && !chat.controller.model.isLoading }
            // the same chat open elsewhere (another window) sends: not a message sent from this screen.
            let other = try await elsewhere(row, in: session, changes: chat.changes)
            other.send("from elsewhere")
            try await chat.changes.until { chat.shows("from elsewhere") && chat.isShown(chat.newest) }
            // above the newest, the next one leaves the reader where they are.
            chat.scroll(by: -1_000)
            let (reading, top) = try #require(chat.readingRow)
            let id = try #require(chat.id(at: reading))
            other.send("from elsewhere, again")
            try await chat.changes.until { chat.shows("from elsewhere, again") }
            #expect(chat.readingRow?.row == chat.row(of: id))
            #expect(abs((chat.readingRow?.top ?? .infinity) - top) < 1)
        }
    }

    @Test func olderMessagesComingInAboveKeepTheReadersRow() async throws {
        // 400 messages a chat: the device's live timeline holds the newest 200, older ones come in pages.
        try await DemoAccount.with(rooms: 3, messagesPerRoom: 400) { session in
            let chat = try open(try await readChat(in: session), in: session)
            let model = chat.controller.model
            try await chat.changes.until { chat.isShown(chat.newest) && !model.isLoading }
            let shown = model.messages.count
            chat.scrollToTop()
            let (reading, top) = try #require(chat.readingRow)
            let id = try #require(chat.id(at: reading))
            model.loadOlder()
            try await chat.changes.until { model.messages.count > shown && !model.isLoading && chat.isCurrent }
            let now = try #require(chat.row(of: id))
            #expect(now > reading)
            #expect(chat.readingRow?.row == now)
            #expect(abs((chat.readingRow?.top ?? .infinity) - top) < 1)
        }
    }

    @Test func aMessageSentFromAboveTakesTheChatToItsNewest() async throws {
        try await DemoAccount.with(rooms: 10, messagesPerRoom: 60) { session in
            let chat = try open(try await readChat(in: session), in: session)
            try await chat.changes.until { chat.isShown(chat.newest) && !chat.controller.model.isLoading }
            chat.scrollToTop()
            #expect(!chat.isShown(chat.newest))
            chat.controller.model.send("on my way")
            try await chat.changes.until { chat.shows("on my way") && chat.isShown(chat.newest) }
        }
    }

    @Test func aPastedPictureWaitsInTheComposerAndPastedTextIsLeftToTheTextView() async throws {
        try await DemoAccount.with(rooms: 10, messagesPerRoom: 60) { session in
            let chat = try open(try await readChat(in: session), in: session)
            let model = chat.controller.model
            let shown = model.onPendingFiles
            model.onPendingFiles = { shown?($0); chat.changes.send() }
            let composer = try #require(chat.controller.view.descendant(where: { $0.accessibilityIdentifier == "composer" }) as? UITextView)
            let delegate = try #require(composer.pasteDelegate)
            // Paste is on with only a picture to paste.
            let accepted = composer.pasteConfiguration?.acceptableTypeIdentifiers ?? []
            #expect([UTType.png, .movie, .fileURL].allSatisfy { type in accepted.contains { type.conforms(to: UTType($0) ?? .item) } })

            // a screenshot: a PNG, with no name.
            let png = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).pngData { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            }
            let picture = PasteItem(NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier))
            delegate.textPasteConfigurationSupporting?(composer, transform: picture)
            #expect(picture.result == .none)
            try await chat.changes.until { model.pendingFiles.count == 1 }
            let pasted = try #require(model.pendingFiles.first)
            #expect(pasted.lastPathComponent == "Pasted Image.png")
            #expect(try Data(contentsOf: pasted) == png)

            let words = PasteItem(NSItemProvider(object: "see you there" as NSString))
            delegate.textPasteConfigurationSupporting?(composer, transform: words)
            #expect(words.result == .default)
            #expect(model.pendingFiles == [pasted])
        }
    }


    @Test func aSentPhotoDragsOutAsItsFileLoadedWhenDroppedAndTextStays() async throws {
        try await DemoAccount.with(rooms: 10, messagesPerRoom: 60) { session in
            let chat = try open(try await readChat(in: session), in: session)
            let model = chat.controller.model
            try await chat.changes.until { chat.isShown(chat.newest) && !model.isLoading }
            #expect(chat.collectionView.dragInteractionEnabled)
            let drag = try #require(chat.collectionView.dragDelegate)
            let photo = try #require(model.messages.first { $0.photo != nil && $0.album.isEmpty && $0.video == nil && $0.state == .sent })
            let items = drag.collectionView(chat.collectionView, itemsForBeginning: NoDragSession(),
                                            at: IndexPath(item: try #require(chat.row(of: photo.id)), section: 0))
            let provider = try #require(items.first?.itemProvider)
            #expect(items.count == 1)
            #expect(provider.suggestedName == SavedFiles.promisedName(for: photo))
            #expect(provider.registeredContentTypes == [SavedFiles.promisedType(for: photo)])
            // dropped: the original comes, downloaded then.
            let size = try await withCheckedThrowingContinuation { (loaded: CheckedContinuation<Int, any Error>) in
                _ = provider.loadFileRepresentation(for: SavedFiles.promisedType(for: photo), openInPlace: false) { file, _, error in
                    guard let file else { return loaded.resume(throwing: error ?? CocoaError(.fileNoSuchFile)) }
                    loaded.resume(with: Result { try Data(contentsOf: file).count })
                }
            }
            #expect(size > 0)
            let text = try #require(model.messages.first { !$0.hasMedia && $0.deletedRun == 0 })
            #expect(drag.collectionView(chat.collectionView, itemsForBeginning: NoDragSession(),
                                        at: IndexPath(item: try #require(chat.row(of: text.id)), section: 0)).isEmpty)
        }
    }
    /// A chat of the demo with no unread message: it opens at its newest.
    @Test func deletedMessagesOneAfterAnotherShowAsOneRowThatGrowsInPlaceAndUnfoldsWhenActivated() async throws {
        try await DemoAccount.with(rooms: 10, messagesPerRoom: 60) { session in
            let chat = try open(try await readChat(in: session), in: session)
            let model = chat.controller.model
            try await chat.changes.until { chat.isShown(chat.newest) && !model.isLoading }
            // three of the newest messages, one after another, that fold together once deleted.
            let messages = model.messages
            let start = try #require(messages.indices.dropLast(2).last { index in
                let three = messages[index...(index + 2)]
                return three.allSatisfy { $0.album.isEmpty && $0.thread == nil }
                    && three.dropFirst().allSatisfy { !$0.startsDay && !$0.startsTimeGap }
            })
            let three = messages[start...(start + 2)].map(\.id)
            model.delete(three[0])
            model.delete(three[1])
            try await chat.changes.until { chat.row(of: three[1]) == nil && chat.isCurrent }
            let row = try #require(chat.row(of: three[0]))
            chat.collectionView.layoutIfNeeded()
            let cell = try #require(chat.collectionView.cellForItem(at: IndexPath(item: row, section: 0)) as? MessageCell)
            #expect(cell.accessibilityLabel?.hasPrefix("2 deleted messages") == true)
            #expect(cell.accessibilityTraits.contains(.button))
            // a third joins the run: its row leaves, and the run's row shows the new count in place.
            model.delete(three[2])
            try await chat.changes.until { chat.row(of: three[2]) == nil && chat.isCurrent }
            chat.collectionView.layoutIfNeeded()
            let again = try #require(chat.row(of: three[0]))
            #expect(chat.collectionView.cellForItem(at: IndexPath(item: again, section: 0)) === cell)
            #expect(cell.accessibilityLabel?.hasPrefix("3 deleted messages") == true)
            // activated (VoiceOver's double tap, as a tap): each shows in its own row.
            #expect(cell.accessibilityActivate())
            try await chat.changes.until { three.allSatisfy { chat.row(of: $0) != nil } && chat.isCurrent }
            #expect(three.allSatisfy { id in model.messages.first { $0.id == id }?.deletedRun == 0 })
        }
    }

    @Test func thePlusOpensItsPanelInTheKeyboardsPlaceAndItsXGivesTheKeyboardBack() async throws {
        try await DemoAccount.with(rooms: 10, messagesPerRoom: 60) { session in
            // in a window: the text view becomes the first responder.
            let chat = try open(try await readChat(in: session), in: session, inWindow: true)
            let controller = chat.controller
            // the library's permission, as given: the newest photos' row.
            controller.attachments.libraryAccess = { .authorized }
            let plus = try #require(controller.view.descendant { $0.accessibilityLabel == String(localized: "Attach") } as? UIButton)
            let text = try #require(controller.view.descendant(where: { $0.accessibilityIdentifier == "composer" }) as? UITextView)
            #expect(text.inputView == nil)

            let began = NotificationCenter.default.notifications(named: UITextView.textDidBeginEditingNotification, object: text)
            plus.sendActions(for: .primaryActionTriggered)
            for await _ in began { break }
            let panel = try #require(text.inputView as? AttachPanel)
            #expect(panel.frame.height == ComposerView.keyboardHeight)
            #expect(panel.descendant { $0.accessibilityIdentifier == "recent photos" } != nil)
            #expect(plus.accessibilityLabel == String(localized: "Close"))

            // the ×: the keyboard takes the panel's place, and the + is a + again.
            plus.sendActions(for: .primaryActionTriggered)
            #expect(text.inputView == nil)
            #expect(text.isFirstResponder)
            #expect(plus.accessibilityLabel == String(localized: "Attach"))
        }
    }

    private func readChat(in session: Session) async throws -> ChatRow {
        let list = ChatListModel(session: session)
        let changes = list.changes()
        list.reload()
        try await changes.until { list.rows.contains { !$0.isUnread && !$0.isMerged && !$0.isGroup } }
        return try #require(list.rows.first { !$0.isUnread && !$0.isMerged && !$0.isGroup })
    }

    /// The chat open in a second model, as in another window.
    private func elsewhere(_ row: ChatRow, in session: Session, changes: Changes) async throws -> ThreadModel {
        let other = ThreadModel(session: session, row: row)
        other.onUpdate = { _, _ in changes.send() }
        await other.start()
        try await changes.until { !other.messages.isEmpty }
        return other
    }
}

/// A chat's controller, its view loaded and laid out at a phone's size, and the announcements of
/// its list: each new content size or place wakes the test. `inWindow`: the controller is the root
/// of a window of the host app's scene, so animations run as they do on screen.
@MainActor
private struct ShownChat {
    let controller: ThreadViewController
    let collectionView: UICollectionView
    let window: UIWindow?
    let changes = Changes()
    private let observations: [NSKeyValueObservation]

    init(_ controller: ThreadViewController, inWindow: Bool = false) throws {
        self.controller = controller
        let frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        if inWindow {
            let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = frame
            window.rootViewController = controller
            window.isHidden = false
            self.window = window
        } else {
            window = nil
        }
        controller.loadViewIfNeeded()
        controller.view.frame = frame
        let collectionView = try #require(controller.view.subviews.lazy.compactMap { $0 as? UICollectionView }.first)
        self.collectionView = collectionView
        let changes = changes
        observations = [
            collectionView.observe(\.contentSize) { _, _ in MainActor.assumeIsolated { changes.send() } },
            collectionView.observe(\.contentOffset) { _, _ in MainActor.assumeIsolated { changes.send() } },
        ]
        // the width is known: the messages are measured for it, then shown.
        controller.view.layoutIfNeeded()
    }

    /// The last row's index; -1 before any.
    var newest: Int { collectionView.numberOfSections == 0 ? -1 : collectionView.numberOfItems(inSection: 0) - 1 }

    /// The message a row shows, and the row showing a message, as the list's data source has them.
    func id(at row: Int) -> String? { controller.dataSource.itemIdentifier(for: IndexPath(item: row, section: 0)) }
    func row(of id: String) -> Int? { controller.dataSource.indexPath(for: id)?.item }
    func row(ofEvent event: String) -> Int? { controller.model.messages.first { $0.eventId == event }.flatMap { row(of: $0.id) } }

    /// The list shows the model's messages, its newest last.
    var isCurrent: Bool { newest == controller.model.messages.count - 1 && id(at: newest) == controller.model.messages.last?.id }

    /// The list's newest row is the model's newest message, `body`.
    func shows(_ body: String) -> Bool { isCurrent && controller.model.messages.last?.body == body }

    /// What the list shows, between the bars over and under it.
    private var seen: ClosedRange<CGFloat> {
        let inset = collectionView.adjustedContentInset, offset = collectionView.contentOffset.y
        return offset + inset.top ... offset + collectionView.bounds.height - inset.bottom
    }

    private func frame(of item: Int) -> CGRect? {
        guard item >= 0, item <= newest else { return nil }
        return collectionView.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame
    }

    /// The row is all on screen.
    func isShown(_ item: Int) -> Bool {
        frame(of: item).map { seen.contains($0.minY) && seen.contains($0.maxY) } ?? false
    }

    /// The row's middle is in the middle third of what the list shows, where a jump brings it.
    func isCentred(_ item: Int) -> Bool {
        guard let frame = frame(of: item) else { return false }
        let seen = seen, third = (seen.upperBound - seen.lowerBound) / 3
        return (seen.lowerBound + third ... seen.upperBound - third).contains(frame.midY)
    }

    /// The row the reader looks at (the first whose middle is on screen), and how far below the
    /// top of what the list shows it starts.
    var readingRow: (row: Int, top: CGFloat)? {
        let top = seen.lowerBound
        guard newest >= 0, let item = (0...newest).first(where: { frame(of: $0).map { $0.midY >= top } ?? false }),
              let frame = frame(of: item) else { return nil }
        return (item, frame.minY - top)
    }

    /// The reader moves the list by `distance`, within its content, at once.
    func scroll(by distance: CGFloat) {
        let lowest = -collectionView.adjustedContentInset.top
        let highest = max(lowest, collectionView.contentSize.height + collectionView.adjustedContentInset.bottom - collectionView.bounds.height)
        let offset = min(max(collectionView.contentOffset.y + distance, lowest), highest)
        collectionView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        collectionView.layoutIfNeeded()
    }

    /// The reader moves the list to its oldest message.
    func scrollToTop() { scroll(by: -.greatestFiniteMagnitude) }
}

/// One item of a paste, as the text view hands it to its paste delegate: what the delegate made of it.
@MainActor
private final class PasteItem: NSObject, UITextPasteItem {
    enum Result: Equatable { case pending, `default`, none, text }
    let itemProvider: NSItemProvider
    var localObject: Any? { nil }
    var defaultAttributes: [NSAttributedString.Key: Any] { [:] }
    private(set) var result = Result.pending

    init(_ provider: NSItemProvider) {
        itemProvider = provider
    }

    func setResult(string: String) { result = .text }
    func setResult(attributedString: NSAttributedString) { result = .text }
    func setResult(attachment: NSTextAttachment) { result = .text }
    func setNoResult() { result = .none }
    func setDefaultResult() { result = .default }
}

private extension UIView {
    /// The first view under this one, depth first, that `matches`.
    func descendant(where matches: (UIView) -> Bool) -> UIView? {
        for view in subviews {
            if matches(view) { return view }
            if let found = view.descendant(where: matches) { return found }
        }
        return nil
    }
}

/// A drag that has only begun: the list is asked for its items before any of this is read.
private final class NoDragSession: NSObject, UIDragSession {
    var localContext: Any?
    var items: [UIDragItem] { [] }
    func location(in view: UIView) -> CGPoint { .zero }
    var allowsMoveOperation: Bool { false }
    var isRestrictedToDraggingApplication: Bool { false }
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool { false }
}
