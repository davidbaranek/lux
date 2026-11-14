import Foundation
import LuxBindings

// The mappings between the Rust core's records (`lux-ffi`) and the app's own types, shared by
// `Core/`: the rest of LuxCore keeps its own types, and the generated ones never leak past `Core/`.

/// Runs a call into the core, its typed error in the user's words (`AccountFailure`).
func worded<T>(_ call: () async throws -> T) async throws -> T {
    do {
        return try await call()
    } catch let error as CoreAccountError {
        throw AccountFailure(error)
    }
}

extension AccountFailure {
    init(_ error: CoreAccountError) {
        self = switch error {
        case .SignedOut: .signedOut
        case .SessionEnded: .sessionEnded
        case .StoreUnusable, .StoreMismatch, .Secrets, .Store: .storage
        case .ServerNotFound: .serverNotFound
        case .UnsupportedLogin: .unsupportedLogin
        case .WrongCredentials: .wrongCredentials
        case .InvalidCallback: .invalidCallback
        case .Network(let kind, _):
            switch kind {
            case .offline: .offline
            case .timeout: .timedOut
            case .other: .connectionFailed
            }
        case .Server(let status, let errcode, _):
            switch (status, errcode) {
            case (_, "M_FORBIDDEN"), (403, _): .forbidden
            case (_, "M_LIMIT_EXCEEDED"), (429, _): .rateLimited
            case (.some(500...), _): .serverUnavailable
            default: .serverRefused
            }
        case .NoSuchChat: .unknownChat
        case .UnknownContact: .unknownContact
        case .UnknownMessage: .unknownMessage
        case .NotAllowed: .notAllowed
        case .File: .file
        case .LabelNameEmpty: .labelNameEmpty
        case .LabelNameTaken: .labelNameTaken
        case .LabelGone: .labelGone
        case .NotSavable: .notSavable
        case .EncryptedChat: .encryptedChat
        case .TimePassed: .timePassed
        case .NotWaiting: .notWaiting
        case .WrongRecoveryKey: .wrongRecoveryKey
        }
    }
}

/// The core's runtime: its worker threads are set before the first call into the core (the
/// listeners' calls into Swift come on them).
enum CoreRuntime {
    static func start() { startCore(process: .app) }
    static func startInExtension() { startCore(process: .notificationExtension) }
}

// MARK: The timeline's footers

extension MessageItem.Footer {
    init(_ footer: CoreFooter) {
        let status: Status? = switch footer.status {
        case .sending: .sending
        case .uploading(let progress): .uploading(progress)
        case .failed: .failed
        case nil: nil
        }
        self.init(isEdited: footer.isEdited, status: status)
    }
}

extension CoreFolder {
    init(_ folder: ChatFolder) {
        self = switch folder {
        case .inbox: .inbox
        case .lowPriority: .lowPriority
        case .archive: .archive
        }
    }
}

extension ChatFolder {
    init(_ folder: CoreFolder) {
        self = switch folder {
        case .inbox: .inbox
        case .lowPriority: .lowPriority
        case .archive: .archive
        }
    }
}

// MARK: The chat list's places

extension CorePlace {
    init(_ place: Place) {
        self = switch place {
        case .folder(let folder): .folder(folder: CoreFolder(folder))
        case .requests: .requests
        case .saved: .saved
        case .reminders: .reminders
        case .scheduled: .scheduled
        case .network(let network): .network(network: network)
        case .space(let id): .space(id: id)
        case .label(let id): .label(id: id)
        }
    }
}

extension Place {
    init(_ place: CorePlace) {
        self = switch place {
        case .folder(let folder): .folder(ChatFolder(folder))
        case .requests: .requests
        case .saved: .saved
        case .reminders: .reminders
        case .scheduled: .scheduled
        case .network(let network): .network(network)
        case .space(let id): .space(id)
        case .label(let id): .label(id)
        }
    }
}

extension CoreChatFilter {
    init(_ filter: ChatFilter) {
        self = switch filter {
        case .unread: .unread
        case .read: .read
        case .drafts: .drafts
        case .groups: .groups
        case .directs: .directs
        }
    }
}

extension CoreSectionId {
    /// The section's id in the list.
    var key: String {
        switch self {
        case .pinned: ChatSection.pinnedId
        case .all: "all"
        case .space(let id): id
        }
    }
}

// MARK: The composer's Markdown

extension Markdown {
    /// The formatting runs of `text`, and the ranges of their marks, as sending reads them.
    /// Nothing is formatted inside code.
    public static func runs(in text: String) -> [Run] {
        composerMarkdown(text: text).map { run in
            let kind: Kind = switch run.style {
            case .bold: .bold
            case .italic: .italic
            case .strikethrough: .strikethrough
            case .code: .code
            case .codeBlock: .codeBlock
            case .quote: .quote
            case .mark: .mark
            }
            return Run(kind: kind, range: NSRange(location: Int(run.start), length: Int(run.length)))
        }
    }
}
