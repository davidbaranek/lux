import Foundation

/// The networks the account's server bridges: which it offers, the account's logins on each, and
/// the history arriving from them. One per account, for the welcome after signing in, Settings and
/// the chat list's status line.
@MainActor
public final class NetworksModel {
    public enum Offers {
        case loading
        /// The server's well-known names no bridges: nothing to sign in to from the app.
        case notSet(server: String)
        case offered([NetworkOffer])
        /// The server could not be asked.
        case failed(AccountFailure)
    }

    /// What is known of one offered network.
    public enum Status {
        case loading
        case account(NetworkAccount)
        case failed(BridgeFailure)
    }

    /// Something the chat list's status line tells.
    public enum Attention: Hashable {
        /// History is arriving.
        case catchingUp(CatchUp)
        /// A login was let go: sign in again.
        case signedOut(NetworkOffer, name: String)

        public var network: String {
            switch self {
            case .catchingUp(let catchUp): catchUp.network
            case .signedOut(let offer, _): offer.network
            }
        }
    }

    public private(set) var offers: Offers = .loading
    public private(set) var statuses: [NetworkOffer: Status] = [:]
    public private(set) var catchingUp: [CatchUp] = []
    public let changes = Broadcast()

    private let account: Task<RustAccount, any Error>
    private let server: String
    private var following: Task<Void, Never>?
    private var handle: AnyObject?
    private var loading: Task<Void, Never>?

    init(account: Task<RustAccount, any Error>, server: String) {
        self.account = account
        self.server = server
    }

    /// The offered networks, empty until known.
    public var offered: [NetworkOffer] {
        if case .offered(let offers) = offers { offers } else { [] }
    }

    /// What the chat list's status line tells, the history arriving first.
    public var attention: [Attention] {
        let signedOut = offered.compactMap { offer -> Attention? in
            guard case .account(let account)? = statuses[offer],
                  let lost = account.logins.first(where: { $0.state.needsSignIn })
            else { return nil }
            return .signedOut(offer, name: lost.name)
        }
        return catchingUp.map(Attention.catchingUp) + signedOut
    }

    /// Whether the welcome after signing in should offer the networks: the server offers some, and
    /// none has a login yet.
    public var hasNoLogins: Bool {
        offered.allSatisfy { offer in
            if case .account(let account)? = statuses[offer] { account.logins.isEmpty } else { true }
        }
    }

    /// Asks the server again what it offers, and each bridge for the account there.
    public func load() async {
        if let loading { return await loading.value }
        let loading = Task { await loadOnce() }
        self.loading = loading
        await loading.value
        self.loading = nil
    }

    private func loadOnce() async {
        startFollowing()
        guard let account = try? await account.value else { return }
        do {
            switch try await account.networkOffers() {
            case .notSet:
                offers = .notSet(server: server)
            case .offered(let found):
                offers = .offered(found)
                for offer in found where statuses[offer] == nil { statuses[offer] = .loading }
            }
        } catch let failure as BridgeFailure {
            if case .account(let failure) = failure { offers = .failed(failure) } else { offers = .failed(.serverRefused) }
        } catch {
            offers = .failed(.connectionFailed)
        }
        changes.send()
        await withTaskGroup(of: Void.self) { group in
            for offer in offered {
                group.addTask { await self.refresh(offer) }
            }
        }
    }

    /// Asks `offer`'s bridge for the account there again.
    public func refresh(_ offer: NetworkOffer) async {
        guard let account = try? await account.value else { return }
        do {
            statuses[offer] = .account(try await account.networkAccount(offer))
        } catch let failure as BridgeFailure {
            statuses[offer] = .failed(failure)
        } catch {
            statuses[offer] = .failed(.unreachable)
        }
        changes.send()
    }

    /// Signs `login` out of `offer`'s network.
    public func logOut(of offer: NetworkOffer, login: String) async throws {
        try await account.value.logOut(of: offer, login: login)
        await refresh(offer)
    }

    /// A sign-in to `offer`'s network, the bridge's preferred way unless `flow` names another.
    public func signIn(to offer: NetworkOffer, flow: NetworkAccount.Flow? = nil) -> NetworkSignIn {
        var flow = flow
        if flow == nil, case .account(let account)? = statuses[offer] { flow = account.flows.first }
        return NetworkSignIn(account: account, offer: offer, flow: flow?.id ?? "") { [weak self] in
            await self?.refresh(offer)
        }
    }

    private func startFollowing() {
        guard following == nil else { return }
        following = Task { [weak self, account] in
            guard let account = try? await account.value else { return }
            let (changes, handle) = account.catchingUp()
            self?.handle = handle
            for await networks in changes {
                guard let self else { return }
                let wasCatchingUp = Set(catchingUp.map(\.network))
                catchingUp = networks
                self.changes.send()
                // a network done bringing its history: its logins' states may have changed too.
                for offer in offered where wasCatchingUp.contains(offer.network) && !networks.contains(where: { $0.network == offer.network }) {
                    await refresh(offer)
                }
            }
        }
    }

    isolated deinit {
        following?.cancel()
    }
}

/// One sign-in to a network: its steps, as the bridge asks for them.
@MainActor
public final class NetworkSignIn {
    public let offer: NetworkOffer
    private let account: Task<RustAccount, any Error>
    private let flow: String
    private let finished: () async -> Void
    /// The step under way, to cancel at the bridge if the user gives up.
    private var current: NetworkLoginStep.ID?

    init(account: Task<RustAccount, any Error>, offer: NetworkOffer, flow: String, finished: @escaping () async -> Void) {
        self.account = account
        self.offer = offer
        self.flow = flow
        self.finished = finished
    }

    public func start() async throws -> NetworkLoginStep {
        try await went(account.value.startNetworkLogin(offer, flow: flow))
    }

    /// Answers a form's or a website's step.
    public func answer(_ step: NetworkLoginStep.ID, values: [String: String]) async throws -> NetworkLoginStep {
        try await went(account.value.answerNetworkLogin(offer, step: step, values: values))
    }

    /// Waits until the bridge moves on from a shown step (the phone scanned the code).
    public func wait(_ step: NetworkLoginStep.ID) async throws -> NetworkLoginStep {
        try await went(account.value.waitNetworkLogin(offer, step: step))
    }

    /// The user gave up: the bridge forgets the sign-in.
    public func cancel() {
        guard let current else { return }
        self.current = nil
        let (account, offer) = (account, offer)
        Task { await (try? await account.value)?.cancelNetworkLogin(offer, step: current) }
    }

    private func went(_ step: NetworkLoginStep) async -> NetworkLoginStep {
        switch step {
        case .website(let website): current = website.id
        case .form(let form): current = form.id
        case .show(let shown): current = shown.id
        case .done:
            current = nil
            await finished()
        case .unsupported:
            current = nil
        }
        return step
    }
}
