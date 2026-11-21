#if os(macOS)
import Testing
@testable import LuxCore

/// Whom Lux lets in without asking: a client's name is its own word, so never more than reading.
struct AgentsTests {
    @Test func aClientApprovedBeforeIsLetInToReadOnly() {
        #expect(Agents.silentGrant(before: .autoSend, wanted: nil, asksMore: false) == .read)
        #expect(Agents.silentGrant(before: .read, wanted: .read, asksMore: false) == .read)
    }

    @Test func moreThanReadingOrANewClientIsAlwaysAsked() {
        #expect(Agents.silentGrant(before: .autoSend, wanted: .drafts, asksMore: false) == nil)
        #expect(Agents.silentGrant(before: .send, wanted: .send, asksMore: false) == nil)
        #expect(Agents.silentGrant(before: .autoSend, wanted: .read, asksMore: true) == nil)
        #expect(Agents.silentGrant(before: nil, wanted: nil, asksMore: false) == nil)
    }
}
#endif
