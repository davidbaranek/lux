import Foundation

/// The account's encryption as the apps offer it: what this device still needs after signing in
/// (decided in the core), the verifications the account's other devices ask for, the account's
/// devices, and setting recovery up. One per account, made with it.
@MainActor
public final class SecurityModel {
    /// What this device needs; `.unknown` until the core knows.
    public private(set) var setup: EncryptionSetup = .unknown
    /// The account's devices, this one first; empty until loaded.
    public private(set) var devices: [OwnDevice] = []
    public let changes = Broadcast()
    /// Another device asks to verify: the app shows the request (set by whoever presents it).
    public var onRequest: ((VerificationModel) -> Void)?

    private let account: Task<RustAccount, any Error>
    private var following: [Task<Void, Never>] = []
    private var handles: [AnyObject] = []
    private var waiting: [CheckedContinuation<EncryptionSetup, Never>] = []

    init(account: Task<RustAccount, any Error>) {
        self.account = account
        following = [
            Task { [weak self, account] in
                guard let account = try? await account.value else { return }
                let (setups, handle) = account.encryptionSetups()
                self?.handles.append(handle)
                for await setup in setups {
                    self?.receive(setup)
                }
            },
            Task { [weak self, account] in
                guard let account = try? await account.value else { return }
                let (requests, handle) = account.verificationRequests()
                self?.handles.append(handle)
                for await request in requests {
                    guard let self else { return }
                    let model = VerificationModel(account: self.account, request: request)
                    // nothing to show it yet: the request waits on the other device until it times out.
                    onRequest?(model)
                }
            },
        ]
    }

    private func receive(_ setup: EncryptionSetup) {
        self.setup = setup
        changes.send()
        guard setup != .unknown else { return }
        let waiting = waiting
        self.waiting = []
        for continuation in waiting { continuation.resume(returning: setup) }
    }

    /// What this device needs, once the core knows.
    public func knownSetup() async -> EncryptionSetup {
        if setup != .unknown { return setup }
        return await withCheckedContinuation { waiting.append($0) }
    }

    /// Reads the account's devices again.
    public func loadDevices() async {
        guard let account = try? await account.value, let devices = try? await account.ownDevices() else { return }
        self.devices = devices
        changes.send()
    }

    /// How `device` is signed out: on the server's account page, or here with the password.
    public func signOutMethod(for device: OwnDevice) async throws -> DeviceSignOut {
        try await account.value.deviceSignOut(device: device.id)
    }

    /// Signs `device` out with the account's password; the list no longer shows it.
    /// Throws `AccountFailure.wrongCredentials` for a wrong password.
    public func signOut(_ device: OwnDevice, password: String) async throws {
        try await account.value.signOut(device: device.id, password: password)
        devices.removeAll { $0.id == device.id }
        changes.send()
        await loadDevices()
    }

    /// Sets up recovery for an account that has none: the recovery key, for the user to save.
    public func setUpRecovery() async throws -> String {
        let key = try await account.value.setUpRecovery()
        changes.send()
        return key
    }

    isolated deinit {
        for task in following { task.cancel() }
        for continuation in waiting { continuation.resume(returning: .unknown) }
    }
}
