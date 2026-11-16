import Foundation

/// One verification between this device and another of the account's: start it (or answer
/// another device's request), follow the steps, answer the comparison.
@MainActor
public final class VerificationModel {
    /// What is verified.
    public enum Kind: Equatable {
        /// This device, by whichever of the account's devices answers.
        case thisDevice
        /// The account's device `id`, from this one.
        case device(OwnDevice)
        /// Another device asked: this one answers.
        case request(from: OwnDevice?)
    }

    public let kind: Kind
    public private(set) var step: VerificationStep?
    public var onStep: ((VerificationStep) -> Void)?
    public var onError: ((Error) -> Void)?

    private let account: Task<any SecurityPort, any Error>
    private var flow: (any Verification)?
    private var following: Task<Void, Never>?

    public init(session: Session, kind: Kind = .thisDevice) {
        account = Task { [account = session.account] in try await account.value }
        self.kind = kind
    }

    /// Another device's request, as it arrived.
    init(account: Task<any SecurityPort, any Error>, request: any Verification) {
        self.account = account
        kind = .request(from: request.otherDevice)
        flow = request
    }

    /// Starts the verification, or (for a request) follows it.
    public func start() {
        guard following == nil else { return }
        following = Task {
            do {
                let flow: any Verification
                if let request = self.flow { flow = request } else { flow = try await begin() }
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

    private func begin() async throws -> any Verification {
        let account = try await account.value
        return switch kind {
        case .thisDevice, .request: try await account.verifyThisDevice()
        case .device(let device): try await account.verify(device: device.id)
        }
    }

    /// Accepts another device's request.
    public func accept() { answer { try await $0.accept() } }
    /// The emojis are the same on both devices.
    public func confirm() { answer { try await $0.confirm() } }
    /// They differ: someone may be in the middle; the verification stops.
    public func deny() { answer { try await $0.deny() } }

    /// Gives up, or declines a request.
    public func cancel() {
        let flow = flow
        Task { await flow?.cancel() }
    }

    private func answer(_ action: @escaping (any Verification) async throws -> Void) {
        guard let flow else { return }
        Task { do { try await action(flow) } catch { onError?(error) } }
    }

    isolated deinit {
        following?.cancel()
    }
}
