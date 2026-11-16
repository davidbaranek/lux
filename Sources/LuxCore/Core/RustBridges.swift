import Foundation
import LuxBindings

/// The server's bridges in the Rust core (`lux-ffi`'s `bridges.rs`), in the app's types: the
/// Rust core's adapter of `NetworksPort`.
extension RustAccount: NetworksPort {
    func networkOffers() async throws -> NetworkOffers {
        switch try await bridged({ try await account.bridgeOffers() }) {
        case .notSet: .notSet
        case .offered(let offers): .offered(offers.map(NetworkOffer.init))
        }
    }

    func networkAccount(_ offer: NetworkOffer) async throws -> NetworkAccount {
        NetworkAccount(try await bridged { try await account.bridgeAccount(offer: CoreBridgeOffer(offer)) })
    }

    func startNetworkLogin(_ offer: NetworkOffer, flow: String) async throws -> NetworkLoginStep {
        NetworkLoginStep(try await bridged { try await account.startNetworkLogin(offer: CoreBridgeOffer(offer), flow: flow) })
    }

    func answerNetworkLogin(_ offer: NetworkOffer, step: NetworkLoginStep.ID, values: [String: String]) async throws -> NetworkLoginStep {
        NetworkLoginStep(try await bridged {
            try await account.answerNetworkLogin(offer: CoreBridgeOffer(offer), step: CoreLoginStepId(step), values: values)
        })
    }

    func waitNetworkLogin(_ offer: NetworkOffer, step: NetworkLoginStep.ID) async throws -> NetworkLoginStep {
        NetworkLoginStep(try await bridged {
            try await account.waitNetworkLogin(offer: CoreBridgeOffer(offer), step: CoreLoginStepId(step))
        })
    }

    func cancelNetworkLogin(_ offer: NetworkOffer, step: NetworkLoginStep.ID) async {
        await account.cancelNetworkLogin(offer: CoreBridgeOffer(offer), step: CoreLoginStepId(step))
    }

    func logOut(of offer: NetworkOffer, login: String) async throws {
        try await bridged { try await account.logOutOfNetwork(offer: CoreBridgeOffer(offer), login: login) }
    }

    /// The networks whose history is arriving, now and as they change; the core stops telling
    /// when the stream ends.
    func catchingUp() -> AsyncStream<[CatchUp]> {
        let (stream, continuation) = AsyncStream<[CatchUp]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let handle = account.followCatchingUp(listener: CatchUpRelay(continuation))
        continuation.onTermination = { _ in handle.cancel() }
        return stream
    }
}

/// A bridge's failure in the user's words: a refusal of the server's setup says what the admin
/// has to do, one of what the user entered gives the bridge's reason.
private func bridged<T>(_ call: () async throws -> T) async throws -> T {
    do {
        return try await call()
    } catch let error as CoreAccountError {
        throw BridgeFailure(error)
    }
}

extension BridgeFailure {
    init(_ error: CoreAccountError) {
        switch error {
        case .Network(.other, _):
            self = .unreachable
        case .Server(let status, let errcode, let message):
            switch (status, errcode) {
            case (401, _), (_, "M_UNKNOWN_TOKEN"), (_, "M_MISSING_TOKEN"): self = .notAccepted
            case (403, "M_FORBIDDEN"): self = message.isEmpty ? .notPermitted : .refused(message)
            case (404, _), (405, _), (_, "M_UNRECOGNIZED"): self = .notFound
            case (.some(500...), _) where message.isEmpty: self = .unreachable
            default: self = message.isEmpty ? .account(AccountFailure(error)) : .refused(message)
            }
        default:
            self = .account(AccountFailure(error))
        }
    }
}

private final class CatchUpRelay: CoreCatchUpListener {
    let continuation: AsyncStream<[CatchUp]>.Continuation
    init(_ continuation: AsyncStream<[CatchUp]>.Continuation) { self.continuation = continuation }

    func onChange(networks: [CoreCatchUp]) {
        continuation.yield(networks.map { CatchUp(network: $0.network, chats: Int($0.chats), messages: Int($0.messages)) })
    }
}

extension NetworkOffer {
    init(_ offer: CoreBridgeOffer) { self.init(network: offer.network, provisioning: offer.provisioning) }
}

extension CoreBridgeOffer {
    init(_ offer: NetworkOffer) { self.init(network: offer.network, provisioning: offer.provisioning) }
}

extension CoreLoginStepId {
    init(_ id: NetworkLoginStep.ID) { self.init(process: id.process, step: id.step, kind: id.kind, instructions: id.instructions) }
}

extension NetworkLoginStep.ID {
    init(_ id: CoreLoginStepId) { self.init(process: id.process, step: id.step, kind: id.kind, instructions: id.instructions) }
}

extension NetworkAccount {
    init(_ account: CoreBridgeAccount) {
        self.init(
            logins: account.logins.map { Login(id: $0.id, name: $0.name, state: State($0.state)) },
            flows: account.flows.map { Flow(id: $0.id, name: $0.name, description: $0.description) },
            needsSignIn: account.needsSignIn)
    }
}

extension NetworkAccount.State {
    init(_ state: CoreLoginState) {
        self = switch state {
        case .connected: .connected
        case .connecting: .connecting
        case .backfilling: .backfilling
        case .badCredentials: .badCredentials
        case .loggedOut: .loggedOut
        case .error(let reason): .error(reason)
        }
    }
}

extension NetworkLoginStep {
    init(_ step: CoreLoginStep) {
        switch step {
        case .website(let id, let url, let userAgent, let fields, let extractJs, let donePattern, let hidden):
            guard let url = URL(string: url) else {
                self = .unsupported(kind: id.kind)
                return
            }
            self = .website(Website(
                id: ID(id), url: url, userAgent: userAgent,
                fields: fields.map { field in
                    Website.Field(id: field.id, required: field.required, sources: field.sources.map { source in
                        switch source {
                        case .cookie(let name, let domain): .cookie(name: name, domain: domain)
                        case .localStorage(let name): .localStorage(name: name)
                        case .script(let name): .script(name: name)
                        case .unreadable: .unreadable
                        }
                    })
                },
                extractJS: extractJs, doneURLPattern: donePattern, hidden: hidden))
        case .form(let id, let fields):
            self = .form(Form(id: ID(id), fields: fields.map { field in
                Form.Field(id: field.id, kind: Form.Field.Kind(field.kind), name: field.name, description: field.description,
                           defaultValue: field.default, optional: field.optional, pattern: field.pattern, choices: field.choices)
            }))
        case .show(let id, let shown):
            let what: Shown.What = switch shown {
            case .qrCode(let data): .qrCode(data)
            case .code(let code): .code(code)
            case .emoji(let text, let imageUrl): .emoji(text, imageURL: imageUrl.flatMap(URL.init(string:)))
            case .nothing: .nothing
            }
            self = .show(Shown(id: ID(id), what: what))
        case .done(let instructions):
            self = .done(message: instructions)
        case .unsupported(let kind):
            self = .unsupported(kind: kind)
        }
    }
}

extension NetworkLoginStep.Form.Field.Kind {
    init(_ kind: CoreFieldKind) {
        self = switch kind {
        case .username: .username
        case .password: .password
        case .phoneNumber: .phoneNumber
        case .email: .email
        case .code: .code
        case .text: .text
        case .choice: .choice
        }
    }
}
