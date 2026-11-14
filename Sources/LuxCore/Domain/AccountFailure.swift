import Foundation

/// Why something the account did failed, in the user's words. The core's errors are typed
/// (`CoreAccountError`); their own text is for the log, and `Core/` turns them into these.
public enum AccountFailure: LocalizedError, Equatable, Sendable {
    case signedOut, sessionEnded, storage
    case serverNotFound, unsupportedLogin, wrongCredentials, invalidCallback
    case offline, timedOut, connectionFailed
    case forbidden, rateLimited, serverUnavailable, serverRefused
    case unknownChat, unknownContact, unknownMessage, notAllowed, file
    case labelNameEmpty, labelNameTaken, labelGone
    case notSavable, encryptedChat, timePassed, notWaiting
    case wrongRecoveryKey

    public var errorDescription: String? {
        switch self {
        case .signedOut: String(localized: "No account is signed in.")
        case .sessionEnded: String(localized: "This session has ended. Sign in again.")
        case .storage: String(localized: "The account's data on this device could not be read or written.")
        case .serverNotFound: String(localized: "No Matrix server answers at this address.")
        case .unsupportedLogin: String(localized: "This server does not offer this way of signing in.")
        case .wrongCredentials: String(localized: "The user name or password is wrong.")
        case .invalidCallback: String(localized: "The sign-in did not finish. Try again.")
        case .offline: String(localized: "You are offline. Check the connection and try again.")
        case .timedOut: String(localized: "The server did not answer in time. Try again.")
        case .connectionFailed: String(localized: "The server cannot be reached. Try again.")
        case .forbidden: String(localized: "The server does not allow this.")
        case .rateLimited: String(localized: "Too many requests at once. Try again in a moment.")
        case .serverUnavailable: String(localized: "The server has a problem. Try again later.")
        case .serverRefused: String(localized: "The server refused. Try again later.")
        case .unknownChat: String(localized: "This chat is no longer in the account.")
        case .unknownContact: String(localized: "This person cannot be reached on that network.")
        case .unknownMessage: String(localized: "This message is no longer in the chat.")
        case .notAllowed: String(localized: "This cannot be done here.")
        case .file: String(localized: "The file could not be read or written.")
        case .labelNameEmpty: String(localized: "Enter a name for the label.")
        case .labelNameTaken: String(localized: "A label with that name already exists.")
        case .labelGone: String(localized: "That label was deleted on another device.")
        case .notSavable: String(localized: "This message cannot be saved.")
        case .encryptedChat: String(localized: "An encrypted chat cannot send messages later.")
        case .timePassed: String(localized: "That time has passed. Pick a later one.")
        case .notWaiting: String(localized: "That message is no longer waiting to be sent.")
        case .wrongRecoveryKey: String(localized: "That recovery key does not open this account's backup.")
        }
    }

    /// What the user asked for cannot be done as asked, and only they can change that (a label's
    /// name, a time that passed): worth telling them at once. Passing trouble (offline, a server
    /// error) is not; a failed message shows in its chat.
    public var isForTheUser: Bool {
        switch self {
        case .labelNameEmpty, .labelNameTaken, .labelGone, .notSavable, .encryptedChat, .timePassed, .notWaiting, .notAllowed,
             .forbidden, .unknownChat, .unknownContact, .unknownMessage:
            true
        default:
            false
        }
    }
}
