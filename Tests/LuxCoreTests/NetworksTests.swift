import Foundation
import Testing
@testable import LuxCore

struct NetworksTests {
    /// Every network the core names (`lux_core::network::Network::as_str`).
    static let known = ["whatsapp", "signal", "messenger", "instagram", "telegram", "discord", "linkedin", "slack",
                        "gmessages", "imessage", "matrix"]

    @Test func everyNetworkHasItsOwnName() {
        let names = Self.known.map(Networks.name)
        #expect(Set(names).count == names.count)
        #expect(Networks.name("gmessages") == "Google Messages")
        #expect(Networks.name("imessage") == "iMessage")
        #expect(Networks.name("slack") == "Slack")
    }

    @Test func anotherBridgesNetworkIsNamedFromItsProtocol() {
        #expect(Networks.name("bluesky") == "Bluesky")
        #expect(Networks.name("google_chat") == "Google Chat")
        #expect(Networks.name("twitter-dm") == "Twitter Dm")
        #expect(Networks.name("") == "Other")
    }

    @Test func aNetworkWithoutLogoShowsNoOthers() {
        #expect(Networks.logo("whatsapp") == "network-whatsapp")
        for network in ["slack", "gmessages", "imessage", "bluesky"] {
            #expect(Networks.logo(network) == nil)
        }
        // each its own look, unknown networks one grey.
        let looks = ["slack", "gmessages", "imessage", "bluesky"].map { "\(Networks.symbol($0)) \(Networks.tint($0))" }
        #expect(Set(looks).count == looks.count)
        #expect(Networks.tint("bluesky") == Networks.tint("anything"))
    }

    /// The logos named are the asset catalogue's, no more and no fewer.
    @Test func theLogosAreTheAssetCatalogues() throws {
        let catalogue = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Apps/Shared/Networks.xcassets")
        let sets = try FileManager.default.contentsOfDirectory(atPath: catalogue.path(percentEncoded: false))
            .compactMap { $0.hasPrefix("network-") && $0.hasSuffix(".imageset") ? String($0.dropFirst(8).dropLast(9)) : nil }
        #expect(Set(sets) == Networks.logos)
    }
}
