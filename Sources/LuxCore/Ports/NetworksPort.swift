import Foundation

/// What an account offers of the networks its server bridges (WhatsApp, Signal, …): which it
/// offers, the account's logins on each, signing in step by step, and the history arriving.
///
/// A port: `NetworksModel` and `NetworkSignIn` need this and nothing else of the account. The Rust
/// core's account is its adapter (`RustBridges.swift`); tests bring their own.
protocol NetworksPort: Sendable {
    /// The networks the server bridges, as its well-known names them.
    func networkOffers() async throws -> NetworkOffers
    /// The account's logins on `offer`'s network and the ways to sign in there.
    func networkAccount(_ offer: NetworkOffer) async throws -> NetworkAccount
    /// Starts a sign-in to `offer`'s network the way `flow` names.
    func startNetworkLogin(_ offer: NetworkOffer, flow: String) async throws -> NetworkLoginStep
    /// Answers a form's or a website's step.
    func answerNetworkLogin(_ offer: NetworkOffer, step: NetworkLoginStep.ID, values: [String: String]) async throws -> NetworkLoginStep
    /// Waits until the bridge moves on from a shown step.
    func waitNetworkLogin(_ offer: NetworkOffer, step: NetworkLoginStep.ID) async throws -> NetworkLoginStep
    /// The bridge forgets a sign-in under way.
    func cancelNetworkLogin(_ offer: NetworkOffer, step: NetworkLoginStep.ID) async
    /// Signs `login` out of `offer`'s network.
    func logOut(of offer: NetworkOffer, login: String) async throws
    /// The networks whose history is arriving, now and as they change, until the stream ends.
    func catchingUp() -> AsyncStream<[CatchUp]>
}

/// The networks a server bridges.
enum NetworkOffers: Sendable, Equatable {
    /// Its well-known names no bridges.
    case notSet
    case offered([NetworkOffer])
}
