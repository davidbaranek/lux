import Foundation

/// The account's security: what this device needs for encryption, verifying with the account's
/// other devices, its devices and recovery. What the security, verification and settings models
/// need of an account; the Rust core's account adapts it (`RustSecurity.swift`).
protocol SecurityPort: Sendable {
    func isDeviceVerified() async -> Bool
    /// What this device needs, now and as it changes, until the stream ends.
    func encryptionSetups() -> AsyncStream<EncryptionSetup>
    /// The verifications the account's other devices ask for, as they arrive, until the stream ends.
    func verificationRequests() -> AsyncStream<any Verification>
    /// Verifies this device with whichever of the account's devices answers.
    func verifyThisDevice() async throws -> any Verification
    /// Verifies the account's device `device` from this one.
    func verify(device: String) async throws -> any Verification
    func ownDevices() async throws -> [OwnDevice]
    /// How `device` is signed out: on the server's account page, or here with the password.
    func deviceSignOut(device: String) async throws -> DeviceSignOut
    /// Throws `AccountFailure.wrongCredentials` for a wrong password.
    func signOut(device: String, password: String) async throws
    func recoveryState() -> RecoveryState
    /// Throws `AccountFailure.wrongRecoveryKey` for a key that does not open the backup.
    func recover(key: String) async throws
    /// Sets up recovery; the new recovery key.
    func setUpRecovery() async throws -> String
}

/// One verification with another device: its steps, and the answers to them.
protocol Verification: Sendable {
    /// The steps as they come; the stream ends after the last.
    var steps: AsyncStream<VerificationStep> { get }
    /// The device on the other side, once known.
    var otherDevice: OwnDevice? { get }
    func accept() async throws
    func confirm() async throws
    func deny() async throws
    func cancel() async
}
