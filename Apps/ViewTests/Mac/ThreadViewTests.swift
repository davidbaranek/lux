import AppKit
import LuxCore
import QuickLookUI
import Testing
@testable import Lux

/// A chat's pane over a demo account of its own, seen through its table: where the chat opens, and
/// where each kind of update leaves it. No window: the test reads the clip view's place, not what
/// is drawn.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ThreadViewTests {
    /// The chat's pane, at `message` if given.
    private func open(_ row: ChatRow, in session: Session, at message: MessageLink? = nil) throws -> ShownChat {
        try ShownChat(ThreadController(session: session, row: row, theme: .neutral, focus: message))
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
            let chat = try open(try await readChat(in: session), in: session)
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

    @Test func deletedMessagesOneAfterAnotherShowAsOneRowThatGrowsInPlaceAndUnfoldsWhenPressed() async throws {
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
            let cell = try #require(chat.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView)
            #expect(cell.accessibilityLabel() == "2 deleted messages")
            #expect(cell.accessibilityRole() == .button)
            // a third joins the run: its row leaves, and the run's row shows the new count in place.
            model.delete(three[2])
            try await chat.changes.until { chat.row(of: three[2]) == nil && chat.isCurrent }
            let again = try #require(chat.row(of: three[0]))
            #expect(chat.table.view(atColumn: 0, row: again, makeIfNecessary: false) === cell)
            #expect(cell.accessibilityLabel() == "3 deleted messages")
            // pressed (VoiceOver's press, as a click): each shows in its own row.
            #expect(cell.accessibilityPerformPress())
            try await chat.changes.until { three.allSatisfy { chat.row(of: $0) != nil } && chat.isCurrent }
            #expect(three.allSatisfy { id in model.messages.first { $0.id == id }?.deletedRun == 0 })
        }
    }

    @Test func theComposerGrowsWithItsTextToEightLinesThenScrollsAndIsOneLineAgainOnceSent() async throws {
        try await DemoAccount.with(rooms: 10, messagesPerRoom: 60) { session in
            let chat = try open(try await readChat(in: session), in: session)
            try await chat.changes.until { chat.isShown(chat.newest) && !chat.controller.model.isLoading }
            let controller = chat.controller, composer = controller.composerField, text = controller.field
            let oneLine = composer.frame.height, inset = chat.scrollView.contentInsets.bottom
            /// The composer's height once the window has laid it out, the messages' bottom inset
            /// following it in the same pass.
            @MainActor func shown() -> CGFloat {
                chat.layOut()
                #expect(chat.scrollView.contentInsets.bottom == inset + composer.frame.height - oneLine)
                return composer.frame.height
            }

            text.insertText("Packing list:", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(shown() == oneLine)
            // a line at a time, as Option-Return adds them.
            var heights: [CGFloat] = []
            for item in 1...11 {
                text.insertNewlineIgnoringFieldEditor(nil)
                text.insertText("item \(item)", replacementRange: NSRange(location: NSNotFound, length: 0))
                heights.append(shown())
                // the newest message stays all on screen above it.
                #expect(chat.isShown(chat.newest))
            }
            // each of the first seven new lines makes it taller; from the eighth line on it holds.
            #expect(zip(heights.prefix(7), heights.prefix(7).dropFirst()).allSatisfy { $0 < $1 })
            #expect(heights.dropFirst(7).allSatisfy { $0 == heights[6] })
            #expect(abs(heights[6] - oneLine * CGFloat(ComposerField.maxLines)) <= CGFloat(ComposerField.maxLines))
            // past it the text scrolls inside.
            #expect(text.frame.height > composer.contentView.bounds.height)

            controller.send()
            #expect(shown() == oneLine)
        }
    }

    @Test func aFilePastedIntoTheComposerWaitsInItAsAPickedOneDoes() async throws {
        try await DemoAccount.with(rooms: 10, messagesPerRoom: 60) { session in
            let chat = try open(try await readChat(in: session), in: session)
            let model = chat.controller.model
            pendingFiles(of: model, wake: chat.changes)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Trip plan \(UUID().uuidString).txt")
            try Data("plan".utf8).write(to: file)
            defer { _ = bestEffort("the test's file") { try FileManager.default.removeItem(at: file) } }
            let pasteboard = pasteboard { $0.writeObjects([file as NSURL]) }
            defer { pasteboard.releaseGlobally() }

            #expect(chat.controller.field.readSelection(from: pasteboard))
            try await chat.changes.until { model.pendingFiles == [file] }
            // the file, not its name, as Finder also offers it.
            #expect(chat.controller.composerField.text.isEmpty)
        }
    }

    @Test func aPastedPictureWaitsAsAFileAndPastedTextStillGoesInAsText() async throws {
        try await DemoAccount.with(rooms: 10, messagesPerRoom: 60) { session in
            let chat = try open(try await readChat(in: session), in: session)
            let model = chat.controller.model
            pendingFiles(of: model, wake: chat.changes)
            // a screenshot copied on the Mac: a PNG, and the TIFF beside it.
            let picture = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
                NSColor.systemBlue.setFill()
                rect.fill()
                return true
            }
            let tiff = try #require(picture.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            let pictures = pasteboard { $0.setData(png, forType: .png); $0.setData(tiff, forType: .tiff) }
            defer { pictures.releaseGlobally() }

            #expect(chat.controller.field.readSelection(from: pictures))
            try await chat.changes.until { model.pendingFiles.count == 1 }
            let pasted = try #require(model.pendingFiles.first)
            #expect(pasted.lastPathComponent == "Pasted Image.png")
            #expect(try Data(contentsOf: pasted) == png)

            let words = pasteboard { $0.setString("see you there", forType: .string) }
            defer { words.releaseGlobally() }
            #expect(chat.controller.field.readSelection(from: words))
            #expect(chat.controller.composerField.text == "see you there")
            #expect(model.pendingFiles == [pasted])
        }
    }

    /// A pasteboard of the test's own (never the user's), as `write` fills it.
    private func pasteboard(_ write: (NSPasteboard) -> Void) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("lux-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        write(pasteboard)
        return pasteboard
    }

    /// The files waiting in the composer wake the test as they change, after the screen shows them.
    private func pendingFiles(of model: ThreadModel, wake changes: Changes) {
        let shown = model.onPendingFiles
        model.onPendingFiles = { shown?($0); changes.send() }
    }

    @Test func spaceShowsTheSelectedMessagesMediaInQuickLookTheArrowsStepThroughTheChatsMediaAndSpaceClosesIt() async throws {
        try await DemoAccount.with(rooms: 10, messagesPerRoom: 60) { session in
            let chat = try open(try await readChat(in: session), in: session)
            let model = chat.controller.model
            try await chat.changes.until { chat.isShown(chat.newest) && !model.isLoading }
            let media = model.messages.filter(\.hasMedia).compactMap { chat.row(of: $0.id) }
            try #require(media.count >= 2)
            let panel = try #require(QLPreviewPanel.shared())
            let visible = panel.observe(\.isVisible) { _, _ in MainActor.assumeIsolated { chat.changes.send() } }
            defer { visible.invalidate() }
            chat.table.selectRowIndexes([media[0]], byExtendingSelection: false)
            chat.table.keyDown(with: try key(" "))
            try await chat.changes.until { panel.isVisible && chat.controller.preview != nil }
            // down: the chat's next message with media, selected and shown.
            #expect(chat.controller.previewPanel(panel, handle: try key(String(utf16CodeUnits: [unichar(NSDownArrowFunctionKey)], count: 1))))
            #expect(chat.table.selectedRow == media[1])
            chat.table.keyDown(with: try key(" "))
            try await chat.changes.until { !panel.isVisible }
        }
    }

    /// A key pressed with no modifier, as the table gets it.
    private func key(_ characters: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
    }

    /// A chat of the demo with no unread message: it opens at its newest.
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
        other.onUpdate = { (_: [MessageItem]) in changes.send() }
        await other.start()
        try await changes.until { !other.messages.isEmpty }
        return other
    }
}

/// A chat's controller, its view loaded and laid out at a pane's size, and the announcements of
/// its list: each new place of the clip view, or size of the table, wakes the test.
@MainActor
private final class ShownChat {
    let controller: ThreadController
    let table: NSTableView
    let scrollView: NSScrollView
    let clip: NSClipView
    let changes: Changes
    private let observations: [any NSObjectProtocol]

    init(_ controller: ThreadController) throws {
        self.controller = controller
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 700, height: 800)
        let scroll = try #require(controller.view.subviews.lazy.compactMap { $0 as? NSScrollView }.first)
        let table = try #require(scroll.documentView as? NSTableView), clip = scroll.contentView
        self.table = table
        scrollView = scroll
        self.clip = clip
        clip.postsBoundsChangedNotifications = true
        table.postsFrameChangedNotifications = true
        let changes = Changes()
        self.changes = changes
        observations = [
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { _ in
                MainActor.assumeIsolated { changes.send() }
            },
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: table, queue: .main) { _ in
                MainActor.assumeIsolated { changes.send() }
            },
        ]
        // the width is known: the messages are measured for it, then shown.
        controller.view.layoutSubtreeIfNeeded()
    }

    isolated deinit {
        for observation in observations { NotificationCenter.default.removeObserver(observation) }
    }

    /// The last row's index; -1 before any.
    var newest: Int { table.numberOfRows - 1 }

    private var rows: NSTableViewDiffableDataSource<Int, String>? { table.dataSource as? NSTableViewDiffableDataSource<Int, String> }

    /// The message a row shows, and the row showing a message, as the table's data source has them.
    func id(at row: Int) -> String? { rows?.itemIdentifier(forRow: row) }
    func row(of id: String) -> Int? { rows?.row(forItemIdentifier: id) }
    func row(ofEvent event: String) -> Int? { controller.model.messages.first { $0.eventId == event }.flatMap { row(of: $0.id) } }

    /// The table shows the model's messages, its newest last.
    var isCurrent: Bool { newest == controller.model.messages.count - 1 && id(at: newest) == controller.model.messages.last?.id }

    /// The table's newest row is the model's newest message, `body`.
    func shows(_ body: String) -> Bool { isCurrent && controller.model.messages.last?.body == body }

    /// What the table shows, between the insets over and under it.
    var seen: NSRect {
        let insets = clip.contentInsets
        return NSRect(x: 0, y: clip.bounds.minY + insets.top, width: clip.bounds.width,
                      height: clip.bounds.height - insets.top - insets.bottom)
    }

    /// The row is all on screen.
    func isShown(_ row: Int) -> Bool {
        guard row >= 0, row <= newest else { return false }
        let rect = table.rect(ofRow: row)
        return rect.minY >= seen.minY && rect.maxY <= seen.maxY
    }

    /// The row's middle is in the middle third of what the table shows, where a jump brings it.
    func isCentred(_ row: Int) -> Bool {
        guard row >= 0, row <= newest else { return false }
        let seen = seen, third = seen.height / 3
        return (seen.minY + third ... seen.maxY - third).contains(table.rect(ofRow: row).midY)
    }

    /// The row the reader looks at (the one at the top of what the table shows), and how far below
    /// that top it starts.
    var readingRow: (row: Int, top: CGFloat)? {
        let row = table.row(at: NSPoint(x: 0, y: max(seen.minY, 0)))
        guard row >= 0 else { return nil }
        return (row, table.rect(ofRow: row).minY - seen.minY)
    }

    /// The reader moves the table by `distance`, within its content, at once.
    func scroll(by distance: CGFloat) {
        let lowest = -clip.contentInsets.top
        let highest = max(lowest, table.bounds.height + clip.contentInsets.bottom - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(clip.bounds.minY + distance, lowest), highest)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The reader moves the table to its oldest message.
    func scrollToTop() { scroll(by: -.greatestFiniteMagnitude) }

    /// What the window does before it draws: the constraints that changed (a view's intrinsic
    /// size), then the layout.
    func layOut() {
        controller.view.updateConstraintsForSubtreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
    }
}
