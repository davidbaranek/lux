import AppKit
import AuthenticationServices
import Foundation
import Testing
@testable import LuxCore

/// The sign-in form over its port alone: made-up servers that answer when the test says, so an
/// older server's answer can come after a newer one's.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SignInModelTests {
    private final class Server: SignInPort {
        var homeserver = "matrix.org"
        /// How each server lets the app in; nil: no Matrix server answers there.
        let methods = Held<String, LoginMethods?>()
        /// Each sign-in, as "user@server" (or "browser@server"); nil: it went through.
        let signIns = Held<String, (any Error)?>()

        nonisolated func loginMethods(for homeserver: String) async throws -> LoginMethods {
            guard let methods = await methods.answer(for: homeserver) else { throw AccountFailure.serverNotFound }
            return methods
        }

        func signIn(user: String, password: String) async throws {
            if let failure = await signIns.answer(for: "\(user)@\(homeserver)") { throw failure }
        }

        func signIn(presentingFrom anchor: ASPresentationAnchor) async throws {
            if let failure = await signIns.answer(for: "browser@\(homeserver)") { throw failure }
        }
    }

    private static let passwordOnly = LoginMethods(password: true, browser: false)
    private static let browserOnly = LoginMethods(password: false, browser: true)

    private let server = Server()
    private let model: SignInModel
    private let changes = Changes()
    /// Each state the form showed, in order.
    private let shown: Shown

    @MainActor private final class Shown { var states: [SignInModel.State] = [] }

    init() {
        model = SignInModel(port: server)
        let (model, changes, shown) = (model, changes, Shown())
        self.shown = shown
        model.onChange = {
            shown.states.append(model.state)
            changes.send()
        }
    }

    @Test func theFormAsksTheServerAndOffersWhatItAllows() async throws {
        model.start()
        #expect(model.state == .checking)
        // both ways show while the server is asked.
        #expect(model.methods == LoginMethods(password: true, browser: true))
        #expect(try await server.methods.asks.first() == "matrix.org")
        await server.methods.answer("matrix.org", with: Self.passwordOnly)
        try await changes.until { model.state == .ready(Self.passwordOnly) }
        #expect(model.methods == Self.passwordOnly)

        // another server is asked; meanwhile the form keeps the last answer's fields.
        model.setHomeserver(" Example.ORG ")
        #expect(model.homeserver == "example.org")
        #expect(model.state == .checking)
        #expect(model.methods == Self.passwordOnly)
        #expect(try await server.methods.asks.first() == "example.org")
        await server.methods.answer("example.org", with: nil)
        try await changes.until { model.state == .unreachable }
    }

    @Test func anEmptyServerIsUnreachableWithoutAsking() {
        model.setHomeserver("  ")
        #expect(model.state == .unreachable)
    }

    @Test func theNewestServersAnswerShowsAndAnOlderOneComingLateIsDropped() async throws {
        model.start()
        #expect(try await server.methods.asks.first() == "matrix.org")
        model.setHomeserver("example.org")
        #expect(try await server.methods.asks.first() == "example.org")
        await server.methods.answer("example.org", with: Self.browserOnly)
        try await changes.until { model.state == .ready(Self.browserOnly) }
        // matrix.org answers after it.
        await server.methods.answer("matrix.org", with: Self.passwordOnly)
        // one more server, asked after the pause: by its answer, matrix.org's had long come.
        model.setHomeserver("example.com")
        #expect(try await server.methods.asks.first() == "example.com")
        await server.methods.answer("example.com", with: Self.browserOnly)
        try await changes.until { model.homeserver == "example.com" && model.state == .ready(Self.browserOnly) }
        #expect(!shown.states.contains(.ready(Self.passwordOnly)))
    }

    @Test func aWrongPasswordFailsAndTheFormIsReadyAgain() async throws {
        model.setHomeserver("example.org")
        #expect(try await server.methods.asks.first() == "example.org")
        await server.methods.answer("example.org", with: Self.passwordOnly)
        let signingIn = Task { try await model.signIn(user: " anna ", password: "wrong") }
        // the user's name without spaces, at the server typed.
        #expect(try await server.signIns.asks.first() == "anna@example.org")
        #expect(model.isSigningIn)
        await server.signIns.answer("anna@example.org", with: AccountFailure.wrongCredentials)
        await #expect(throws: AccountFailure.wrongCredentials) { try await signingIn.value }
        #expect(!model.isSigningIn)
        #expect(server.homeserver == "example.org")
    }

    @Test func closingTheServersPageLeavesTheFormReady() async throws {
        let window = NSWindow()
        let signingIn = Task { try await model.signInInBrowser(presentingFrom: window) }
        #expect(try await server.signIns.asks.first() == "browser@matrix.org")
        #expect(model.isSigningIn)
        await server.signIns.answer("browser@matrix.org", with: CancellationError())
        await #expect(throws: CancellationError.self) { try await signingIn.value }
        #expect(!model.isSigningIn)
    }
}

/// Restoring the kept account at launch, which the scene and a notification's action may both ask
/// for: a kept session whose store is gone, in a Keychain service of the test's own.
@MainActor
@Suite(.ownPreferences, .ownFolder, .timeLimit(.minutes(1)))
struct SessionRestoreTests {
    @Test func aRestoreAskedTwiceAtOnceOpensTheAccountOnce() async throws {
        let service = "lux-tests-\(UUID().uuidString)"
        let session = Session(configuration: .init(homeserver: "example.invalid", keychainService: service),
                              paths: .inside(try TemporaryFolder.ofTest), preferences: try Preferences.ofTest)
        let keychain = AccountKeychain(service: service)
        let store = UUID().uuidString
        // the session, and the search index's key made as it opens, go with the test.
        defer {
            bestEffort("the test's kept session stays") { try keychain.delete() }
            SearchKey.delete(for: store)
        }
        try keychain.write(KeptAccount(session: .init(userId: "@anna:example.invalid", deviceId: "LUXTEST",
                                                      homeserverUrl: "https://example.invalid", accessToken: "token",
                                                      refreshToken: nil, oauthClientId: nil, nativeSlidingSync: true),
                                       store: store))
        var opened = 0
        let counting = session.uploadsChanges.observe { if session.uploads != nil { opened += 1 } }

        async let first = session.restore()
        async let second = session.restore()
        let restored = await [first, second]

        #expect(restored == [true, true])
        #expect(opened == 1)
        withExtendedLifetime(counting) {}
        await session.close()
    }
}
