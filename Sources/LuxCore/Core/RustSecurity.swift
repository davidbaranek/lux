import Foundation
import LuxBindings

/// The Rust core's security in the app's types: what this device needs, verifications with the
/// account's other devices, its devices, the recovery key and setting recovery up.
extension RustAccount: SecurityPort {
    func isDeviceVerified() async -> Bool { await account.isDeviceVerified() }

    /// What this device needs, now and as it changes.
    func encryptionSetups() -> AsyncStream<EncryptionSetup> {
        let (stream, continuation) = AsyncStream<EncryptionSetup>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let handle = account.followEncryptionSetup(listener: SetupRelay(continuation))
        continuation.onTermination = { _ in handle.cancel() }
        return stream
    }

    /// The verifications the account's other devices ask for, as they arrive.
    func verificationRequests() -> AsyncStream<any Verification> {
        let (stream, continuation) = AsyncStream<any Verification>.makeStream()
        let handle = account.followVerificationRequests(listener: RequestRelay(continuation))
        continuation.onTermination = { _ in handle.cancel() }
        return stream
    }

    func verifyThisDevice() async throws -> any Verification {
        RustVerification(try await worded { try await account.verifyThisDevice() })
    }

    func verify(device: String) async throws -> any Verification {
        RustVerification(try await worded { try await account.verifyDevice(deviceId: device) })
    }

    func ownDevices() async throws -> [OwnDevice] {
        try await worded { try await account.ownDevices() }.map(OwnDevice.init)
    }

    func deviceSignOut(device: String) async throws -> DeviceSignOut {
        switch try await worded({ try await account.deviceSignOut(deviceId: device) }) {
        case .inBrowser(let url):
            // the server's own address; one that does not parse cannot be opened either.
            guard let url = URL(string: url) else { throw AccountFailure.notAllowed }
            return .inBrowser(url)
        case .withPassword:
            return .withPassword
        }
    }

    /// Throws `AccountFailure.wrongCredentials` for a wrong password.
    func signOut(device: String, password: String) async throws {
        try await worded { try await account.signOutDevice(deviceId: device, password: password) }
    }

    func recoveryState() -> RecoveryState {
        switch account.recoveryState() {
        case .enabled: .enabled
        case .incomplete: .incomplete
        case .disabled: .disabled
        case .unknown: .unknown
        }
    }

    /// Throws `AccountFailure.wrongRecoveryKey` for a key that does not open the backup.
    func recover(key: String) async throws { try await worded { try await account.recover(key: key) } }

    /// The new recovery key.
    func setUpRecovery() async throws -> String { try await worded { try await account.setUpRecovery() } }
}

/// A verification in the Rust core: its steps, and the answers to them.
final class RustVerification: Verification {
    let steps: AsyncStream<VerificationStep>
    let otherDevice: OwnDevice?
    private let verification: CoreVerification
    /// Keeps the core sending the steps.
    private let listening: CoreListenerHandle

    init(_ verification: CoreVerification) {
        self.verification = verification
        otherDevice = verification.otherDevice().map(OwnDevice.init)
        let (steps, continuation) = AsyncStream<VerificationStep>.makeStream()
        self.steps = steps
        listening = verification.listen(listener: StepRelay(continuation))
    }

    deinit { listening.cancel() }

    func accept() async throws { try await worded { try await verification.accept() } }
    func confirm() async throws { try await worded { try await verification.confirm() } }
    func deny() async throws { try await worded { try await verification.deny() } }
    func cancel() async { await verification.cancel() }
}

/// Passes the core's steps on; the stream ends after the last.
private final class StepRelay: CoreVerificationListener {
    private let continuation: AsyncStream<VerificationStep>.Continuation

    init(_ continuation: AsyncStream<VerificationStep>.Continuation) { self.continuation = continuation }

    func onStep(step: CoreVerificationStep) {
        let step: VerificationStep = switch step {
        case .requested: .requested
        case .waiting: .waiting
        case .accepted: .accepted
        case .compare(let emojis): .compare(emojis.map { VerificationEmoji(symbol: $0.symbol, name: $0.name) })
        case .done: .done
        case .cancelled: .cancelled
        case .failed: .failed
        }
        continuation.yield(step)
        if step.isFinal { continuation.finish() }
    }
}

private final class SetupRelay: CoreEncryptionSetupListener {
    private let continuation: AsyncStream<EncryptionSetup>.Continuation

    init(_ continuation: AsyncStream<EncryptionSetup>.Continuation) { self.continuation = continuation }

    func onSetup(setup: CoreEncryptionSetup) {
        let setup: EncryptionSetup = switch setup {
        case .unknown: .unknown
        case .verifyThisDevice(let withRecoveryKey): .verifyThisDevice(withRecoveryKey: withRecoveryKey)
        case .setUpRecovery: .setUpRecovery
        case .ready: .ready
        }
        continuation.yield(setup)
    }
}

private final class RequestRelay: CoreVerificationRequestListener {
    private let continuation: AsyncStream<any Verification>.Continuation

    init(_ continuation: AsyncStream<any Verification>.Continuation) { self.continuation = continuation }

    func onRequest(verification: CoreVerification) { continuation.yield(RustVerification(verification)) }
}

private extension OwnDevice {
    init(_ device: CoreOwnDevice) {
        self.init(id: device.id, name: device.name, isVerified: device.isVerified, isThisDevice: device.isThisDevice)
    }
}
