import Foundation

/// The signed-in account.
public struct Profile: Sendable, Equatable {
    public var userId: String
    /// The name to show: the display name, else the user id's local part.
    public var name: String
    /// The display name, when the account has one: what the name field starts with.
    public var displayName: String?
    public var avatar: ImageRef?
    /// The server lets the user change the name, the picture.
    public var canChangeName: Bool
    public var canChangeAvatar: Bool

    public init(userId: String, name: String, displayName: String?, avatar: ImageRef?,
                canChangeName: Bool, canChangeAvatar: Bool) {
        self.userId = userId
        self.name = name
        self.displayName = displayName
        self.avatar = avatar
        self.canChangeName = canChangeName
        self.canChangeAvatar = canChangeAvatar
    }
}

/// Whether this device can read the account's encrypted history from its key backup.
public enum RecoveryState: Sendable, Equatable {
    /// The backup is open on this device.
    case enabled
    /// The account has a backup this device has not opened: it needs the recovery key.
    case incomplete
    /// The account keeps no backup.
    case disabled
    case unknown
}

/// How a server lets the app sign in.
public struct LoginMethods: Equatable, Sendable {
    /// With a user name and password, in the app.
    public var password: Bool
    /// On the server's own page, in a browser sheet (passkeys, two-factor, sign-up).
    public var browser: Bool
    public init(password: Bool, browser: Bool) { self.password = password; self.browser = browser }
}
