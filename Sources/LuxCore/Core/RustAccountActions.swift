import Foundation
import LuxBindings

/// The Rust core's account beyond its lists (the chat list's view model has its own actions, in
/// `RustChatList.swift`, the thread's in `RustThread.swift`): people and security, in the app's types.
/// The generated types stay in `Core/`.
extension RustAccount {
    // MARK: People

    func contacts(query: String) async throws -> ContactListing {
        let found = try await worded { try await account.contacts(query: query) }
        let problems = found.problems.map(\.words)
        return ContactListing(contacts: found.contacts.map(Contact.init),
                              problem: problems.isEmpty ? nil : problems.joined(separator: " "))
    }

    func startConversation(with contact: Contact) async throws -> String {
        try await worded { try await account.startConversation(contact: CoreContact(contact)) }
    }

    func createRoom(name: String) async throws -> String { try await worded { try await account.createRoom(name: name) } }

    func profile() async throws -> Profile {
        let own = try await worded { try await account.profile() }
        return Profile(userId: own.userId, name: own.name, avatar: own.avatar.map { .person(url: $0) })
    }

    // MARK: Security

    func isDeviceVerified() async -> Bool { await account.isDeviceVerified() }

    func verifyThisDevice() async throws -> RustVerification {
        RustVerification(try await worded { try await account.verifyThisDevice() })
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
}

/// A verification of this device in the Rust core: its steps, and the answer to the comparison.
final class RustVerification: Sendable {
    let steps: AsyncStream<VerificationStep>
    private let verification: CoreVerification
    /// Keeps the listener listening for as long as the flow is open.
    private let listening: CoreListenerHandle

    init(_ verification: CoreVerification) {
        self.verification = verification
        let (steps, continuation) = AsyncStream<VerificationStep>.makeStream()
        self.steps = steps
        listening = verification.listen(listener: StepRelay(continuation))
    }

    deinit { listening.cancel() }

    func confirm() async throws { try await worded { try await verification.confirm() } }
    func deny() async throws { try await worded { try await verification.deny() } }
    func cancel() async { await verification.cancel() }
}

/// Passes the core's steps on; the stream ends after the last.
private final class StepRelay: CoreVerificationListener {
    private let continuation: AsyncStream<VerificationStep>.Continuation

    init(_ continuation: AsyncStream<VerificationStep>.Continuation) { self.continuation = continuation }

    func onStep(step: CoreVerificationStep) {
        switch step {
        case .waiting: continuation.yield(.waiting)
        case .accepted: continuation.yield(.accepted)
        case .compare(let emojis): continuation.yield(.compare(emojis.map { VerificationEmoji(symbol: $0.symbol, name: $0.name) }))
        case .done:
            continuation.yield(.done)
            continuation.finish()
        case .cancelled:
            continuation.yield(.cancelled)
            continuation.finish()
        case .failed:
            continuation.yield(.failed)
            continuation.finish()
        }
    }
}

private extension Contact {
    init(_ contact: CoreContact) {
        self.init(id: contact.id, accountId: contact.accountId, name: contact.name, identifier: contact.identifier,
                  network: contact.network, avatar: contact.avatar.map { .person(url: $0) })
    }
}

private extension CoreContact {
    init(_ contact: Contact) {
        let avatar: String? = if case .person(let url) = contact.avatar { url } else { nil }
        self.init(id: contact.id, accountId: contact.accountId, name: contact.name, identifier: contact.identifier,
                  network: contact.network, avatar: avatar)
    }
}

private extension CoreContactProblem {
    var words: String {
        switch self {
        case .matrixSearch: String(localized: "Could not search Matrix. Other available contacts are shown. Try again.")
        case .discovery: String(localized: "Could not discover connected accounts. Matrix is still available. Try again.")
        case .someAccounts: String(localized: "Some connected accounts are unavailable. Available accounts are shown. Try again.")
        case .account(let name): String(localized: "Could not load \(name). Other available contacts are shown. Try again.")
        }
    }
}
