import Foundation
import Testing
import UniformTypeIdentifiers
@testable import LuxCore

/// A chat's media saved and copied outside it: what the menus offer, the names the copies take,
/// and that a copy leaves nothing but itself behind.
@Suite(.ownFolder) struct SavedFilesTests {
    private let folder: URL

    init() throws {
        folder = try TemporaryFolder.ofTest
    }

    private func message(body: String = "", photo: Bool = false, video: Bool = false, file: MessageItem.File? = nil,
                         state: MessageItem.State = .sent) -> MessageItem {
        var item = MessageItem(id: "m", senderId: "x", senderName: "Anna", body: body, date: .now, isOwn: false, state: state,
                               photo: photo || video ? MessageItem.Photo(ref: .photo(roomId: "!r", messageId: "m", name: "p"), width: 4, height: 3) : nil)
        item.video = video ? MessageItem.Video(duration: 3) : nil
        item.file = file
        return item
    }

    /// A file of `text` named `name` in a folder of its own, as the session keeps an original.
    private func original(_ name: String, _ text: String = "original") throws -> URL {
        let originals = folder.appendingPathComponent("originals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let file = originals.appendingPathComponent(name)
        try Data(text.utf8).write(to: file)
        return file
    }

    private func destination() throws -> URL {
        let downloads = folder.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        return downloads
    }

    private func contents(of folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @Test func eachPlatformOffersItsOwnPlacesForAPhotoAndOnlyFilesKeepTheirKind() {
        let photo = message(photo: true), document = message(file: .init(name: "Trip plan.pdf", size: 5, mimetype: "application/pdf"))
        #expect(AttachmentAction.available(for: photo, on: .mac) == [.copy, .saveToDownloads, .saveAs])
        #expect(AttachmentAction.available(for: photo, on: .phone) == [.copy, .saveToFiles, .saveToPhotos, .share])
        #expect(AttachmentAction.available(for: document, on: .phone) == [.copy, .saveToFiles, .share])
        let voice = message(file: .init(name: "Voice.m4a", size: 5, mimetype: "audio/mp4", kind: .voice))
        #expect(AttachmentAction.available(for: voice, on: .mac) == [.copy, .saveToDownloads, .saveAs])
        #expect(AttachmentAction.copy.title(for: photo) == "Copy Photo")
        #expect(AttachmentAction.copy.title(for: message(video: true)) == "Copy Video")
        #expect(AttachmentAction.copy.title(for: document) == "Copy File")
    }

    @Test func nothingIsOfferedForAMessageWithoutMediaOrNotOnTheServerYet() {
        #expect(AttachmentAction.available(for: message(body: "hi"), on: .mac).isEmpty)
        #expect(AttachmentAction.available(for: message(photo: true, state: .sending), on: .phone).isEmpty)
        var deleted = message(photo: true)
        deleted.isDeleted = true
        #expect(AttachmentAction.available(for: deleted, on: .mac).isEmpty)
    }

    @Test func savedFilesTakeTheirOwnNamesThenTheNextFreeOne() async throws {
        let downloads = try destination()
        let plan = try original("Trip plan.pdf", "one")
        let first = try await SavedFiles.save([plan], into: downloads)
        let again = try await SavedFiles.save([plan, try original("Trip plan.pdf", "two"), try original("README")], into: downloads)
        #expect(first.map(\.lastPathComponent) == ["Trip plan.pdf"])
        #expect(again.map(\.lastPathComponent) == ["Trip plan 2.pdf", "Trip plan 3.pdf", "README"])
        #expect(try String(contentsOf: again[1], encoding: .utf8) == "two")
        // nothing but the copies: no partial file stays.
        #expect(try contents(of: downloads) == ["README", "Trip plan 2.pdf", "Trip plan 3.pdf", "Trip plan.pdf"])
        // the originals stay where they were.
        #expect(FileManager.default.fileExists(atPath: plan.path))
    }

    @Test func saveAsReplacesTheChosenFileAndLeavesNothingElse() async throws {
        let downloads = try destination()
        let chosen = downloads.appendingPathComponent("Plan.pdf")
        try Data("old".utf8).write(to: chosen)
        try await SavedFiles.save(try original("Trip plan.pdf", "new"), as: chosen)
        #expect(try String(contentsOf: chosen, encoding: .utf8) == "new")
        #expect(try contents(of: downloads) == ["Plan.pdf"])
        // where a drag promised it: nothing there yet.
        let promised = downloads.appendingPathComponent("Trip plan.pdf")
        try await SavedFiles.save(try original("Trip plan.pdf", "dragged"), as: promised)
        #expect(try String(contentsOf: promised, encoding: .utf8) == "dragged")
        #expect(try contents(of: downloads) == ["Plan.pdf", "Trip plan.pdf"])
    }

    @Test func aCopyThatFailsLeavesNothingBehind() async throws {
        let downloads = try destination()
        let gone = folder.appendingPathComponent("gone.pdf")
        await #expect(throws: (any Error).self) { try await SavedFiles.save([gone], into: downloads) }
        await #expect(throws: (any Error).self) { try await SavedFiles.save(gone, as: downloads.appendingPathComponent("x.pdf")) }
        #expect(try contents(of: downloads).isEmpty)
    }

    @Test func aDraggedFileIsPromisedUnderTheNameItWillHave() {
        #expect(SavedFiles.promisedName(for: message(file: .init(name: "Trip plan.pdf", size: 5, mimetype: "application/pdf"))) == "Trip plan.pdf")
        #expect(SavedFiles.promisedName(for: message(body: "IMG_0042.HEIC", photo: true)) == "IMG_0042.HEIC")
        // a caption is no name.
        #expect(SavedFiles.promisedName(for: message(body: "the view from the hut", photo: true)) == "Photo.jpeg")
        #expect(SavedFiles.promisedName(for: message(video: true)) == "Video.mp4")
    }

    @Test func aPictureGoesToThePasteboardWithItsBytesAndAnythingElseAsAFileAlone() async throws {
        let picture = try original("shot.png", "png bytes")
        let image = try #require(try await SavedFiles.image(in: picture))
        #expect(image.type == .png && image.data == Data("png bytes".utf8))
        #expect(try await SavedFiles.image(in: try original("Trip plan.pdf")) == nil)
    }
}
