import Foundation
import Testing
@testable import LuxCore

/// The server's networks over the Rust core's demo account: what it offers, signing in, and
/// what the chat list's bubble says of them.
@MainActor
@Suite(.closesDemoSessions)
struct NetworksModelTests {
    private let session = DemoSessions.open(rooms: 10, messagesPerRoom: 2)

    @Test func theDemoServerOffersItsNetworksWithMessengerConnected() async throws {
        let networks = try #require(session.networks)
        await networks.load()
        #expect(networks.offered.map(\.network) == ["whatsapp", "signal", "messenger", "instagram"])
        let messenger = try #require(networks.offered.first { $0.network == "messenger" })
        guard case .account(let account)? = networks.statuses[messenger] else { Issue.record("no account"); return }
        #expect(account.logins.map(\.name) == ["Anna Nováková"])
        #expect(!networks.hasNoLogins)
    }

    @Test func signingInWithAQRCodeConnectsTheNetwork() async throws {
        let networks = try #require(session.networks)
        await networks.load()
        let whatsapp = try #require(networks.offered.first { $0.network == "whatsapp" })
        let signIn = networks.signIn(to: whatsapp)
        guard case .show(let shown) = try await signIn.start() else { Issue.record("no code shown"); return }
        guard case .done = try await signIn.wait(shown.id) else { Issue.record("not signed in"); return }
        guard case .account(let account)? = networks.statuses[whatsapp] else { Issue.record("no account"); return }
        #expect(!account.logins.isEmpty)
    }

    @Test func theBubbleTellsOfHistoryArrivingAndOpensItsNetwork() {
        let catchUp = CatchUp(network: "messenger", chats: 12, messages: 840)
        let activity = ListActivity.describe(.done, search: nil, networks: [.catchingUp(catchUp)])
        #expect(activity?.title == "Messenger: loading history")
        #expect(activity?.detail == "840 messages in 12 chats so far")
        #expect(activity?.action == .show(.network("messenger")))
        // the first sync goes first.
        #expect(ListActivity.describe(.loading, search: nil, networks: [.catchingUp(catchUp)])?.title == "Connecting…")
    }

    @Test func aNetworkSignedOutComesBeforeHistoryAndAsksToSignIn() {
        let offer = NetworkOffer(network: "instagram", provisioning: "https://example.org/ig")
        let activity = ListActivity.describe(.done, search: nil, networks: [
            .catchingUp(CatchUp(network: "messenger", chats: 1, messages: 2)),
            .signedOut(offer, name: "anna"),
        ])
        #expect(activity?.isWarning == true)
        #expect(activity?.action == .signIn(offer))
    }
}

@Test func aFormFieldTakesWhatItsPatternAllows() {
    let pin = NetworkLoginStep.Form.Field(id: "pin", kind: .password, name: "PIN", description: "", defaultValue: "",
                                          optional: true, pattern: "^[0-9]{6}$", choices: [])
    #expect(pin.accepts(""))
    #expect(pin.accepts("123456"))
    #expect(!pin.accepts("12345"))
}

@Test func aCookiesDomainCountsForItsSubdomains() {
    #expect(WebsiteLoginReader.domain(".facebook.com", isIn: "facebook.com"))
    #expect(WebsiteLoginReader.domain("www.facebook.com", isIn: "facebook.com"))
    #expect(!WebsiteLoginReader.domain("notfacebook.com", isIn: "facebook.com"))
}

/// The networks model over its port alone, with no account behind it: a bridge that cannot be
/// found shows as such, and the others still load.
@MainActor
struct NetworksPortTests {
    private struct Bridges: NetworksPort {
        let offers: [NetworkOffer]
        let missing: String

        func networkOffers() async throws -> NetworkOffers { .offered(offers) }
        func networkAccount(_ offer: NetworkOffer) async throws -> NetworkAccount {
            if offer.network == missing { throw BridgeFailure.notFound }
            return NetworkAccount(logins: [], flows: [], needsSignIn: true)
        }
        func startNetworkLogin(_ offer: NetworkOffer, flow: String) async throws -> NetworkLoginStep { throw BridgeFailure.notFound }
        func answerNetworkLogin(_ offer: NetworkOffer, step: NetworkLoginStep.ID, values: [String: String]) async throws -> NetworkLoginStep {
            throw BridgeFailure.notFound
        }
        func waitNetworkLogin(_ offer: NetworkOffer, step: NetworkLoginStep.ID) async throws -> NetworkLoginStep { throw BridgeFailure.notFound }
        func cancelNetworkLogin(_ offer: NetworkOffer, step: NetworkLoginStep.ID) async {}
        func logOut(of offer: NetworkOffer, login: String) async throws {}
        func catchingUp() -> AsyncStream<[CatchUp]> { AsyncStream { $0.finish() } }
    }

    @Test func aBridgeThatIsNotFoundShowsSoAndTheOthersLoad() async {
        let offers = [NetworkOffer(network: "signal", provisioning: "https://signal.example"),
                      NetworkOffer(network: "whatsapp", provisioning: "https://whatsapp.example")]
        let networks = NetworksModel(account: Task { Bridges(offers: offers, missing: "whatsapp") }, server: "example.org")
        await networks.load()
        #expect(networks.offered == offers)
        guard case .failed(.notFound)? = networks.statuses[offers[1]] else { Issue.record("not shown as missing"); return }
        guard case .account(let account)? = networks.statuses[offers[0]] else { Issue.record("not loaded"); return }
        #expect(account.logins.isEmpty)
        #expect(networks.hasNoLogins)
    }
}
