import AppKit
import LuxCore
import UniformTypeIdentifiers

/// A message's photos, videos, files and sounds kept outside the chat: copied, saved to Downloads
/// or where the save panel says, or dragged out to Finder as a promise kept once downloaded. Each
/// is the original the session holds (`ThreadModel.mediaFiles`, downloaded once); a copy goes only
/// where the user says (`SavedFiles`).
extension ThreadController {
    /// The message's attachment items for its menu, before its other actions.
    func attachmentItems(for message: MessageItem) -> [NSMenuItem] {
        AttachmentAction.available(for: message, on: .mac).map { action in
            let item = NSMenuItem(title: action.title(for: message), action: #selector(performAttachmentAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = AttachmentMenuAction(action: action, message: message)
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            return item
        }
    }

    /// An attachment action from the menu, with the message it was asked for.
    final class AttachmentMenuAction {
        let action: AttachmentAction
        let message: MessageItem
        init(action: AttachmentAction, message: MessageItem) { self.action = action; self.message = message }
    }

    @objc func performAttachmentAction(_ item: NSMenuItem) {
        guard let chosen = item.representedObject as? AttachmentMenuAction else { return }
        let message = chosen.message
        switch chosen.action {
        case .copy:
            keepingMedia(of: message, "copy") { [weak self] _ in try await self?.copyMedia(of: message, to: .general) }
        case .saveToDownloads:
            keepingMedia(of: message, "save") { files in
                let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                _ = try await SavedFiles.save(files, into: downloads)
            }
        case .saveAs:
            guard let window = view.window else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = SavedFiles.promisedName(for: message)
            panel.beginSheetModal(for: window) { [weak self, panel] response in
                MainActor.assumeIsolated {
                    guard response == .OK, let destination = panel.url else { return }
                    self?.keepingMedia(of: message, "save") { files in
                        guard let file = files.first else { return }
                        try await SavedFiles.save(file, as: destination)
                    }
                }
            }
        case .saveToFiles, .saveToPhotos, .share:
            // the iPhone's.
            break
        }
    }

    /// Downloads the message's media (once; the chat's end ends it), then `keep` does what was
    /// asked with the files; a failure says so.
    private func keepingMedia(of message: MessageItem, _ what: String, _ keep: @escaping @MainActor ([URL]) async throws -> Void) {
        tasks.run { [weak self] in
            guard let self else { return }
            do {
                try await keep(try await model.mediaFiles(of: message))
            } catch is CancellationError {
            } catch {
                report(error, of: what)
                // the user asked for the copy: they hear why there is none.
                if let window = view.window, window.attachedSheet == nil {
                    presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
                }
            }
        }
    }

    /// Puts the message's files on `pasteboard`: each as a file (Finder, Mail and Messages paste
    /// it), a picture also as its image (for apps that take pictures, not files).
    func copyMedia(of message: MessageItem, to pasteboard: NSPasteboard) async throws {
        var writers: [AttachmentPasteboardWriter] = []
        for file in try await model.mediaFiles(of: message) {
            writers.append(AttachmentPasteboardWriter(file: file, image: try await SavedFiles.image(in: file)))
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(writers)
    }

    /// The message a row shows, dragged out of the chat: a promise of its file, kept once it is
    /// downloaded; one file a row (an album's photos are saved from the menu).
    func filePromise(for message: MessageItem) -> NSFilePromiseProvider? {
        guard AttachmentAction.available(for: message, on: .mac).contains(.saveAs) else { return nil }
        let name = SavedFiles.promisedName(for: message)
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = message
        return provider
    }
}

extension ThreadController: NSFilePromiseProviderDelegate {
    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider.userInfo as? MessageItem).map(SavedFiles.promisedName) ?? String(localized: "File")
    }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping ((any Error)?) -> Void) {
        guard let message = provider.userInfo as? MessageItem else { return completionHandler(CocoaError(.fileNoSuchFile)) }
        // AppKit's handler is not marked `Sendable`, but the promise may be kept from any thread
        // (it only reports the end of the write); it is called once, when the copy is done.
        nonisolated(unsafe) let completionHandler = completionHandler
        // on the main queue (`operationQueue(for:)`).
        MainActor.assumeIsolated {
            tasks.run { [model] in
                do {
                    guard let file = try await model.mediaFiles(of: message).first else { throw CocoaError(.fileNoSuchFile) }
                    try await SavedFiles.save(file, as: url)
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }
    }

    /// The main queue: the promise reads the chat's model, and the copy itself is off it.
    nonisolated func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { .main }
}

/// A file on the pasteboard as `NSURL` writes it, and, for a picture, its image beside it.
final class AttachmentPasteboardWriter: NSObject, NSPasteboardWriting {
    private let file: NSURL
    private let image: (type: UTType, data: Data)?

    init(file: URL, image: (type: UTType, data: Data)?) {
        self.file = file as NSURL
        self.image = image
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        file.writableTypes(for: pasteboard) + (image.map { [NSPasteboard.PasteboardType($0.type.identifier)] } ?? [])
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if let image, type.rawValue == image.type.identifier { return image.data }
        return file.pasteboardPropertyList(forType: type)
    }
}
