import Foundation
import Testing
@testable import LuxCore

/// Every character is 10 x 20 points, wrapped at the width.
private struct FixedMeasure: TextMeasuring {
    /// Ten points a character, twenty a line; each paragraph wraps on its own.
    func size(of text: String, role: TextRole, width: CGFloat) -> CGSize {
        let perLine = max(Int(width / 10), 1)
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false)
        let lines = paragraphs.map { max(($0.count + perLine - 1) / perLine, 1) }.reduce(0, +)
        let widest = paragraphs.map { min($0.count, perLine) }.max() ?? 0
        return CGSize(width: CGFloat(widest * 10), height: CGFloat(lines * 20))
    }
}

struct MessageLayoutTests {
    private func message(own: Bool, body: String) -> MessageItem {
        MessageItem(id: "m", senderId: own ? "me" : "x", senderName: "Anna", body: body, date: .now, isOwn: own)
    }

    @Test func ownBubbleSitsAtTheTrailingMargin() {
        let layout = MessageLayout.make(message(own: true, body: "hello"), showsSender: true, width: 400,
                                        metrics: BubbleMetrics(), measure: FixedMeasure())
        #expect(layout.bubble.maxX == CGFloat(384))
        #expect(layout.sender == nil)
    }

    /// Each reaction is a chip of its own (a bridge's "join thread" too), so each can be tapped;
    /// chips that do not fit go on the next line, one's own message's at the trailing side.
    @Test func eachReactionIsItsOwnChipAndTheyWrap() {
        var item = message(own: true, body: "hello")
        item.reactions = [.init(key: "👍", count: 3, isMine: true), .init(key: "join thread", count: 1, isMine: false),
                          .init(key: String(repeating: "x", count: 20), count: 1, isMine: false)]
        let layout = MessageLayout.make(item, showsSender: false, width: 400, metrics: BubbleMetrics(), measure: FixedMeasure())
        #expect(layout.reactions.count == 3)
        #expect(layout.reactions[0].maxX < layout.reactions[1].minX)
        #expect(layout.reactions[0].minY == layout.reactions[1].minY)
        #expect(layout.reactions[2].minY > layout.reactions[1].maxY)
        #expect(layout.reactions[2].maxX == layout.bubble.maxX)
        #expect(MessageItem.chipText(item.reactions[0]) == "👍 3")
    }

    @Test func longTextWrapsInsideTheWidestBubble() {
        let layout = MessageLayout.make(message(own: false, body: String(repeating: "a", count: 100)), showsSender: true, width: 400,
                                        metrics: BubbleMetrics(), measure: FixedMeasure())
        // indented by the picture column (28 + 8), the picture level with the bubble's bottom.
        #expect(layout.bubble.minX == CGFloat(16 + 36))
        #expect(layout.bubble.width <= floor(400 * 0.78))
        #expect(layout.sender?.minX == layout.body!.minX + layout.bubble.minX)
        #expect(layout.avatar == CGRect(x: 16, y: layout.bubble.maxY - 28, width: 28, height: 28))
        // a sent message shows no time of its own: the time shows above a pause.
        #expect(layout.footer == nil)
        #expect(layout.height == layout.bubble.maxY)
    }

    /// What shows under a message is the core's (`message::Footer`); the app words it.
    @Test func whatIsNotPlainIsWordedUnderTheText() {
        var item = message(own: true, body: "hi")
        #expect(item.footerText == nil)
        item.footer = .init(isEdited: true, status: .sending)
        #expect(item.footerText == "Edited · Sending…")
        item.footer = .init(isEdited: false, status: .uploading(0.4))
        #expect(item.footerText == "Uploading 40 %")
    }

    private func sharedReel(caption: String) -> MessageItem {
        var item = message(own: false, body: "")
        item.photo = .init(ref: .person(url: "mxc://a/poster"), width: 400, height: 700)
        item.video = .init(duration: 12)
        item.shared = .init(url: "https://example.org/reel/1", title: "galaxies", description: caption)
        return item
    }

    @Test func aSharedPostIsACardWithItsMediaEdgeToEdge() {
        let layout = MessageLayout.make(sharedReel(caption: "short"), showsSender: false, width: 400,
                                        metrics: BubbleMetrics(), measure: FixedMeasure())
        #expect(layout.photo?.origin == .zero)
        #expect(layout.photo?.width == layout.bubble.width)
        #expect(layout.bubble.width == BubbleMetrics().photoWidth)
        #expect(layout.postTitle!.minY > layout.photo!.maxY)
        #expect(layout.post == CGRect(x: 0, y: 0, width: layout.bubble.width, height: layout.bubble.height))
        #expect(layout.postMore == nil)
    }

    /// A post the bridge tells nothing of still shows a card, named by its address, so it can be
    /// opened.
    @Test func aSharedPostWithoutATitleIsNamedByItsAddress() {
        var item = sharedReel(caption: "")
        item.shared = .init(url: "https://www.instagram.com/p/Db58C19iErS/?igsh=abc")
        #expect(item.postCard?.title == "instagram.com/p/Db58C19iErS")
        #expect(item.postCard?.description == nil)
        #expect(item.shared?.link?.host == "www.instagram.com")
        #expect(!item.isMediaOnly)
    }

    @Test func aLongCaptionFoldsToItsFirstLinesUntilUnfolded() {
        var reel = sharedReel(caption: String(repeating: "a", count: 200))
        let folded = MessageLayout.make(reel, showsSender: false, width: 400, metrics: BubbleMetrics(), measure: FixedMeasure())
        #expect(folded.postText?.height == CGFloat(80))
        #expect(folded.postFolded)
        #expect(folded.postMore != nil)
        reel.showsWholePost = true
        let whole = MessageLayout.make(reel, showsSender: false, width: 400, metrics: BubbleMetrics(), measure: FixedMeasure())
        #expect(whole.postText!.height > CGFloat(80))
        #expect(!whole.postFolded)
        #expect(whole.postMore != nil)
    }

    @Test func theSendersOwnTextShowsBelowTheCard() {
        var reel = sharedReel(caption: "short")
        reel.body = "look"
        let layout = MessageLayout.make(reel, showsSender: false, width: 400, metrics: BubbleMetrics(), measure: FixedMeasure())
        #expect(layout.body!.minY > layout.post!.maxY)
        #expect(layout.post!.maxY < layout.bubble.height)
    }

    @Test func plainRowsPutEveryoneUnderTheirPictureAndName() {
        let m = BubbleMetrics()
        let column = m.sideMargin + m.plainAvatarSide + m.plainAvatarGap
        for own in [false, true] {
            let layout = MessageLayout.make(message(own: own, body: "hello"), showsSender: false, style: .plain, width: 400,
                                            metrics: m, measure: FixedMeasure())
            #expect(layout.avatar?.minX == m.sideMargin)
            #expect(layout.sender?.minX == column)
            #expect(layout.time!.minX > layout.sender!.maxX)
            #expect(layout.bubble.minX == column)
            #expect(layout.body?.origin == .zero)
            #expect(layout.bubble.minY >= layout.sender!.maxY)
            // the band reaches round the parts, to the row's bottom.
            #expect(layout.band!.minY < layout.sender!.minY && layout.band!.maxY == layout.height)
            #expect(layout.band!.minX == m.plainBandInset && layout.band!.maxX == 400 - m.plainBandInset)
        }
    }

    @Test func aPlainRunShowsItsNameOnceAndUsesTheWholeWidth() {
        var item = message(own: false, body: String(repeating: "a", count: 100))
        item.startsGroup = false
        let layout = MessageLayout.make(item, showsSender: true, style: .plain, width: 400, metrics: BubbleMetrics(), measure: FixedMeasure())
        #expect(layout.sender == nil && layout.avatar == nil && layout.time == nil)
        // past the bubbles' widest (78 % of the row).
        #expect(layout.bubble.width > floor(400 * 0.78))
        #expect(layout.bubble.maxX <= 400 - BubbleMetrics().sideMargin)
    }

    @Test func aPlainReplyQuotesItsMessageOnALineOverItsHeader() {
        let m = BubbleMetrics()
        var item = message(own: false, body: "yes")
        item.startsGroup = false
        item.quote = .init(senderName: "Petr", text: "coming?")
        let layout = MessageLayout.make(item, showsSender: true, style: .plain, width: 400, metrics: m, measure: FixedMeasure())
        #expect(layout.quote == nil)
        #expect(layout.replyAvatar!.minX == m.sideMargin + m.plainAvatarSide + m.plainAvatarGap)
        #expect(layout.reply!.minX > layout.replyAvatar!.maxX)
        // a reply shows who sent it, under its quote, even inside a run.
        #expect(layout.sender!.minY >= layout.reply!.maxY)
        #expect(layout.avatar != nil)
        // the link runs from above the sender's picture to before the quoted one's.
        #expect(layout.replyLink!.minX == layout.avatar!.midX)
        #expect(layout.replyLink!.maxX < layout.replyAvatar!.minX)
        #expect(layout.replyLink!.maxY < layout.avatar!.minY)
    }

    @Test func aPlainRowsEditedMarkSitsAtItsLeadingEdge() {
        var item = message(own: true, body: "hello there")
        item.footer = .init(isEdited: true, status: nil)
        let layout = MessageLayout.make(item, showsSender: false, style: .plain, width: 400, metrics: BubbleMetrics(), measure: FixedMeasure())
        #expect(layout.footer?.minX == 0)
    }

    @Test func aNewStyleMeasuresEveryMessageAgain() {
        let cache = MessageLayoutCache()
        let items = [message(own: false, body: "one")]
        let bubbles = cache.update(items, showsSender: false, width: 300, measure: FixedMeasure()).layouts["m"]
        let plain = cache.update(items, showsSender: false, style: .plain, width: 300, measure: FixedMeasure()).layouts["m"]
        #expect(bubbles?.style == .bubbles)
        #expect(plain?.style == .plain)
    }

    @Test func cacheMeasuresOnlyWhatChanged() {
        let cache = MessageLayoutCache()
        var items = [message(own: false, body: "one")]
        _ = cache.update(items, showsSender: false, width: 300, measure: FixedMeasure())
        #expect(cache.update(items, showsSender: false, width: 300, measure: FixedMeasure()).changed.isEmpty)
        items[0].body = "two"
        #expect(cache.update(items, showsSender: false, width: 300, measure: FixedMeasure()).changed == ["m"])
    }
}

@MainActor
@Suite(.ownPreferences)
struct ChatStylePreferenceTests {
    @Test func aChatsOwnStyleWinsOverTheAppsUntilItIsCleared() throws {
        let preferences = try Preferences.ofTest
        let app = preferences.chatStyle
        preferences.setChatStyle(app == .plain ? .bubbles : .plain, in: "!test:style")
        #expect(preferences.chatStyle(in: "!test:style") != app)
        #expect(preferences.chatStyle(in: "!other:style") == app)
        preferences.setChatStyle(nil, in: "!test:style")
        #expect(preferences.chatStyle(in: "!test:style") == app)
    }
}

struct MessageActionTests {
    private func message(own: Bool, state: MessageItem.State = .sent) -> MessageItem {
        var item = MessageItem(id: "m", senderId: own ? "me" : "x", senderName: "A", body: "hi", date: .now, isOwn: own, state: state)
        item.isEditable = own
        return item
    }

    @Test func ownSentMessagesCanBeEditedAndDeleted() {
        #expect(MessageAction.available(for: message(own: true)) == [.reply, .edit, .copy, .forward, .delete])
        #expect(MessageAction.available(for: message(own: false)) == [.reply, .copy, .forward])
    }

    @Test func aMessageTheServerHasStartsAThreadOutsideThreads() {
        var sent = message(own: false)
        sent.eventId = "$e"
        #expect(MessageAction.available(for: sent) == [.reply, .replyInThread, .copy, .save, .forward])
        #expect(!MessageAction.available(for: sent, inThread: true).contains(.replyInThread))
    }

    @Test func aMessageIsPinnedOrUnpinnedOnlyWhereTheUserMayPin() {
        var sent = message(own: false)
        sent.eventId = "$e"
        #expect(MessageAction.available(for: sent, pinned: false).contains(.pin))
        #expect(MessageAction.available(for: sent, pinned: true).contains(.unpin))
        let neither = MessageAction.available(for: sent)
        #expect(!neither.contains(.pin) && !neither.contains(.unpin))
    }

    @Test func failedMessagesOfferRetryAndDiscard() {
        #expect(MessageAction.available(for: message(own: true, state: .failed)) == [.retry, .discard, .copy])
        #expect(!MessageAction.canReact(to: message(own: true, state: .failed)))
    }
}

struct ThreadSummaryTests {
    private func root(replies: Int, participants: Int, unread: Int) -> MessageItem {
        var item = MessageItem(id: "m", senderId: "x", senderName: "Anna", body: "trip?", date: .now, isOwn: false)
        item.thread = .init(replies: replies, latestSender: "Petr Svoboda", latestText: "see you", latestDate: .now,
                            participants: (0..<participants).map { .init(userId: "@\($0)", name: "P\($0)") }, unread: unread)
        return item
    }

    @Test func aThreadsSummaryCountsItsRepliesAndShowsTheLastByItsSendersFirstName() {
        #expect(root(replies: 3, participants: 2, unread: 0).threadText == "3 replies · Petr: see you")
        #expect(root(replies: 1, participants: 1, unread: 0).thread?.countText == "1 reply")
        var none = root(replies: 0, participants: 0, unread: 0)
        none.thread?.latestSender = nil
        #expect(none.threadText == "Thread")
    }

    @Test func aThreadsSummaryGoesUnderItsRootWithAtMostThreePicturesAndADotWhileUnread() throws {
        let m = BubbleMetrics()
        let layout = MessageLayout.make(root(replies: 5, participants: 4, unread: 2), showsSender: true, width: 400, metrics: m,
                                        measure: FixedMeasure())
        let box = try #require(layout.thread)
        #expect(box.minY >= layout.bubble.maxY)
        #expect(layout.threadAvatars.count == m.threadAvatars)
        #expect(layout.threadDot != nil)
        #expect(layout.height >= box.maxY)
        let read = MessageLayout.make(root(replies: 5, participants: 1, unread: 0), showsSender: true, width: 400, metrics: m,
                                      measure: FixedMeasure())
        #expect(read.threadDot == nil && read.threadAvatars.count == 1)
        let plain = MessageLayout.make(MessageItem(id: "p", senderId: "x", senderName: "A", body: "hi", date: .now, isOwn: false),
                                       showsSender: true, width: 400, metrics: m, measure: FixedMeasure())
        #expect(plain.thread == nil)
    }
}

struct DayAndReadersTests {
    @Test func readersAreNamedInGroups() {
        var item = MessageItem(id: "m", senderId: "me", senderName: "Me", body: "hi", date: .now, isOwn: true)
        item.readers = [.init(userId: "@a", name: "Anna Nováková"), .init(userId: "@p", name: "Petr")]
        #expect(item.readersText(inGroup: true) == "Read by Anna, Petr")
        #expect(item.readersText(inGroup: false) == "Read")
    }
}

struct EmojiTests {
    @Test func emojisAreTold() {
        #expect("a👍🏽b".firstEmoji == "👍🏽")
        #expect("🇨🇿".firstEmoji == "🇨🇿")
        #expect("❤️".firstEmoji == "❤️")
        #expect("abc 1".firstEmoji == nil)
    }
}

@Test func typingNamesOneTwoOrSeveral() {
    #expect(TypingText.text([]) == nil)
    #expect(TypingText.text(["Anna"]) == "Anna is typing…")
    #expect(TypingText.text(["Anna", "Petr"]) == "Anna and Petr are typing…")
    #expect(TypingText.text(["Anna", "Petr", "Jana"]) == "Several people are typing…")
}

@Suite struct MarkdownTests {
    func runs(_ text: String) -> [String] {
        Markdown.runs(in: text).filter { $0.kind != .mark }.map { "\($0.kind):" + (text as NSString).substring(with: $0.range) }.sorted()
    }

    /// What the composer shows is what sending (CommonMark) makes of the text.
    @Test func findsTheFormattingAsItIsSent() {
        #expect(runs("**bold** and *italic* or _this_, ~~gone~~") == ["bold:bold", "italic:italic", "italic:this", "strikethrough:gone"])
        #expect(runs("> quoted line\n\nnot") == ["quote:quoted line"])
        // a line right under a quote goes on with it.
        #expect(runs("> quoted line\nmore") == ["quote:more", "quote:quoted line"])
        // nothing inside code is formatting.
        #expect(runs("run `a *b* c` now") == ["code:a *b* c"])
        #expect(runs("```\nlet **x** = 1\n```") == ["codeBlock:let **x** = 1\n"])
        // a lone star or a word_with_underscores is text.
        #expect(runs("2 * 3 and snake_case_name") == [])
    }

    @Test func togglingWrapsAndUnwrapsTheSelection() {
        let wrapped = Markdown.toggle("**", in: "say hi now", selection: NSRange(location: 4, length: 2))
        #expect(wrapped.text == "say **hi** now")
        #expect(wrapped.selection == NSRange(location: 6, length: 2))
        let unwrapped = Markdown.toggle("**", in: wrapped.text, selection: wrapped.selection)
        #expect(unwrapped.text == "say hi now")
        #expect(unwrapped.selection == NSRange(location: 4, length: 2))
        let empty = Markdown.toggle("`", in: "ab", selection: NSRange(location: 1, length: 0))
        #expect(empty.text == "a``b")
        #expect(empty.selection == NSRange(location: 2, length: 0))
    }
}
