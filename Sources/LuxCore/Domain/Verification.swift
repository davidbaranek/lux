import Foundation

/// One step of a verification between this device and another of the account's.
public enum VerificationStep: Sendable, Equatable {
    /// Another device asks to verify: the user accepts or declines here.
    case requested
    /// Waiting for the other device to accept the request.
    case waiting
    /// Both accepted; the emojis are on their way.
    case accepted
    /// Compare these with the other device: (symbol, name).
    case compare([VerificationEmoji])
    case done, cancelled, failed

    /// The verification is over.
    public var isFinal: Bool {
        switch self {
        case .done, .cancelled, .failed: true
        case .requested, .waiting, .accepted, .compare: false
        }
    }
}

public struct VerificationEmoji: Sendable, Equatable, Hashable {
    public var symbol: String
    public var name: String
    public init(symbol: String, name: String) { self.symbol = symbol; self.name = name }
}

/// One of the account's devices.
public struct OwnDevice: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    /// The name it gave itself, if any.
    public var name: String?
    /// The account's identity signed it: the account's other devices trust it.
    public var isVerified: Bool
    public var isThisDevice: Bool

    public init(id: String, name: String?, isVerified: Bool, isThisDevice: Bool) {
        self.id = id
        self.name = name
        self.isVerified = isVerified
        self.isThisDevice = isThisDevice
    }

    /// Its name, else its id.
    public var title: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? id }
}

/// What this device still needs to read the account's encrypted messages (`lux_core`'s
/// `EncryptionSetup`, decided in the core).
public enum EncryptionSetup: Sendable, Equatable {
    /// Not known yet: offer nothing.
    case unknown
    /// Verify this device: with another of the account's, or with the recovery key when the
    /// account keeps one.
    case verifyThisDevice(withRecoveryKey: Bool)
    /// The account keeps no recovery: set it up, so a new device can read the history.
    case setUpRecovery
    case ready
}
