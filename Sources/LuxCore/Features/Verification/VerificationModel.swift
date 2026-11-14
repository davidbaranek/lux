import Foundation

/// Verifying this device: start, follow the steps, answer the comparison.
@MainActor
public final class VerificationModel {
    public private(set) var step: VerificationStep?
    public var onStep: ((VerificationStep) -> Void)?
    public var onError: ((Error) -> Void)?

    private let account: Task<RustAccount, any Error>
    private var flow: RustVerification?
    private var following: Task<Void, Never>?

    public init(session: Session) {
        account = session.account
    }

    public func start() {
        guard flow == nil else { return }
        following = Task {
            do {
                let flow = try await account.value.verifyThisDevice()
                self.flow = flow
                for await step in flow.steps {
                    self.step = step
                    onStep?(step)
                }
            } catch {
                step = .failed
                onStep?(.failed)
                onError?(error)
            }
        }
    }

    /// The emojis are the same on both devices.
    public func confirm() { answer { try await $0.confirm() } }
    /// They differ: someone may be in the middle; the verification stops.
    public func deny() { answer { try await $0.deny() } }

    public func cancel() {
        following?.cancel()
        let flow = flow
        Task { await flow?.cancel() }
    }

    private func answer(_ action: @escaping (RustVerification) async throws -> Void) {
        guard let flow else { return }
        Task { do { try await action(flow) } catch { onError?(error) } }
    }
}
