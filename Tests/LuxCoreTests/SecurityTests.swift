import Foundation
import Testing
@testable import LuxCore

/// Verification and recovery on the demo's made-up devices, which answer a few seconds later.
@MainActor
@Suite(.closesDemoSessions)
struct SecurityTests {
    /// The demo's recovery key (`lux_core::demo::DEMO_RECOVERY_KEY`).
    private let demoRecoveryKey = "EsTj 3yST y93F SLpB jJsz eAXc 2XzA ygD3 w69H fGaN TKBj jXEd"

    @Test func aNewDeviceIsAskedToVerifyAndAnotherDeviceVerifiesIt() async throws {
        let session = DemoSessions.open(rooms: 3, messagesPerRoom: 2, encryption: .unverified)
        let security = try #require(session.security)
        #expect(await security.knownSetup() == .verifyThisDevice(withRecoveryKey: true))
        let (announced, observation) = security.announcements()

        let verification = VerificationModel(session: session, kind: .thisDevice)
        let steps = verification.changes()
        verification.start()
        await steps.until({ verification.isComparing }, within: .seconds(15))
        verification.confirm()
        await steps.until { verification.step == .done }
        await announced.until { security.setup == .ready }
        _ = observation
    }

    @Test func theRecoveryKeyVerifiesThisDevice() async throws {
        let session = DemoSessions.open(rooms: 3, messagesPerRoom: 2, encryption: .unverified)
        let settings = SettingsModel(session: session)
        #expect(await failure { try await settings.recover(key: "EsTx not it") } == .wrongRecoveryKey)
        try await settings.recover(key: demoRecoveryKey)
        #expect(settings.isVerified == true)
        #expect(settings.recovery == .enabled)
    }

    @Test func anotherDeviceSignsOutWithThePassword() async throws {
        let session = DemoSessions.open(rooms: 3, messagesPerRoom: 2)
        let security = try #require(session.security)
        await security.loadDevices()
        let web = try #require(security.devices.first { $0.id == "WEBLAPTOP2" })
        #expect(try await security.signOutMethod(for: web) == .withPassword)
        let this = try #require(security.devices.first)
        #expect(this.isThisDevice)
        #expect(await failure { _ = try await security.signOutMethod(for: this) } == .notAllowed)
        #expect(await failure { try await security.signOut(web, password: "") } == .wrongCredentials)
        try await security.signOut(web, password: "secret")
        #expect(!security.devices.contains(web))
        #expect(security.devices.first?.isThisDevice == true)
    }

    @Test func anotherDevicesRequestIsShownAndAnswered() async throws {
        let session = DemoSessions.open(rooms: 3, messagesPerRoom: 2, verificationRequestAfter: 1)
        let security = try #require(session.security)
        let arrived = Changes()
        var request: VerificationModel?
        security.onRequest = { request = $0; arrived.send() }
        await arrived.until { request != nil }
        let verification = try #require(request)
        guard case .request(let device) = verification.kind else { Issue.record("not a request"); return }
        #expect(device?.title == "Element X on iPhone")

        let steps = verification.changes()
        verification.start()
        await steps.until { verification.step == .requested }
        verification.accept()
        await steps.until({ verification.isComparing }, within: .seconds(15))
        verification.confirm()
        await steps.until { verification.step == .done }
    }

    @Test func aDeclinedRequestIsCancelled() async throws {
        let session = DemoSessions.open(rooms: 3, messagesPerRoom: 2, verificationRequestAfter: 1)
        let security = try #require(session.security)
        let arrived = Changes()
        var request: VerificationModel?
        security.onRequest = { request = $0; arrived.send() }
        await arrived.until { request != nil }
        let verification = try #require(request)
        let steps = verification.changes()
        verification.start()
        await steps.until { verification.step == .requested }
        verification.cancel()
        await steps.until { verification.step == .cancelled }
    }

    @Test func anAccountWithoutRecoverySetsItUpOnce() async throws {
        let session = DemoSessions.open(rooms: 3, messagesPerRoom: 2, encryption: .noRecovery)
        let security = try #require(session.security)
        #expect(await security.knownSetup() == .setUpRecovery)
        let (announced, observation) = security.announcements()
        let key = try await security.setUpRecovery()
        #expect(key.hasPrefix("EsT"))
        await announced.until { security.setup == .ready }
        #expect(await failure { _ = try await security.setUpRecovery() } == .notAllowed)
        _ = observation
    }

    @Test func aDeviceOfTheAccountIsVerifiedFromThisOne() async throws {
        let session = DemoSessions.open(rooms: 3, messagesPerRoom: 2)
        let security = try #require(session.security)
        await security.loadDevices()
        #expect(security.devices.first?.isThisDevice == true)
        let unverified = try #require(security.devices.first { !$0.isVerified })

        let verification = VerificationModel(session: session, kind: .device(unverified))
        let steps = verification.changes()
        verification.start()
        await steps.until({ verification.isComparing }, within: .seconds(15))
        verification.confirm()
        await steps.until { verification.step == .done }
        await security.loadDevices()
        #expect(security.devices.first { $0.id == unverified.id }?.isVerified == true)
    }

    /// How `action` failed; nil when it did not.
    private func failure(_ action: () async throws -> Void) async -> AccountFailure? {
        do {
            try await action()
            return nil
        } catch {
            return error as? AccountFailure
        }
    }
}
