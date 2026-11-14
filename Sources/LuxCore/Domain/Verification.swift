import Foundation

/// One step of verifying this device from another one.
public enum VerificationStep: Sendable, Equatable {
    /// Waiting for the other device to accept the request.
    case waiting
    /// The other device accepted; the emojis are on their way.
    case accepted
    /// Compare these with the other device: (symbol, name).
    case compare([VerificationEmoji])
    case done, cancelled, failed
}

public struct VerificationEmoji: Sendable, Equatable, Hashable {
    public var symbol: String
    public var name: String
    public init(symbol: String, name: String) { self.symbol = symbol; self.name = name }
}
