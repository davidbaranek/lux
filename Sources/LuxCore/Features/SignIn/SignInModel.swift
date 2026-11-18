import AuthenticationServices
import Foundation

/// The sign-in form: the server (Lux's own until the user types another), what it allows, and
/// signing in by password or on its own page. Typing a server asks it, after a short pause, how to
/// sign in; a newer server drops an older answer.
@MainActor
public final class SignInModel {
    public enum State: Equatable, Sendable {
        case checking
        case ready(LoginMethods)
        /// No Matrix server answers at what was typed.
        case unreachable
    }

    public private(set) var homeserver: String
    public private(set) var state = State.checking {
        didSet { if state != oldValue { onChange?() } }
    }
    public private(set) var isSigningIn = false {
        didSet { if isSigningIn != oldValue { onChange?() } }
    }
    public var onChange: (() -> Void)?

    /// What the form offers now: the server's answer, or while it is being asked, the last answer
    /// (both ways at first), so the fields are there at once and change only if the server says so.
    public var methods: LoginMethods {
        if case .ready(let methods) = state { lastMethods = methods }
        return lastMethods
    }
    private var lastMethods = LoginMethods(password: true, browser: true)

    private let session: any SignInPort
    private var checking: Task<Void, Never>?

    public convenience init(session: Session) {
        self.init(port: session)
    }

    init(port: any SignInPort) {
        session = port
        homeserver = port.homeserver
    }

    public func start() { check(homeserver, after: .zero) }

    /// The user typed a server.
    public func setHomeserver(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text != homeserver else { return }
        homeserver = text
        check(text, after: .milliseconds(500))
    }

    private func check(_ server: String, after pause: Duration) {
        checking?.cancel()
        guard !server.isEmpty else { state = .unreachable; return }
        state = .checking
        checking = Task { [session] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            // the field says the server cannot be reached; why goes to the log.
            let methods = await bestEffort("sign in: the server's ways in") { try await session.loginMethods(for: server) }
            guard !Task.isCancelled, server == homeserver else { return }
            state = methods.map(State.ready) ?? .unreachable
        }
    }

    /// Signs in with a user name and password. Throws what the server said.
    public func signIn(user: String, password: String) async throws {
        isSigningIn = true
        defer { isSigningIn = false }
        session.homeserver = homeserver
        try await session.signIn(user: user.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
    }

    /// Signs in on the server's page, in a browser sheet over `window`.
    public func signInInBrowser(presentingFrom window: ASPresentationAnchor) async throws {
        isSigningIn = true
        defer { isSigningIn = false }
        session.homeserver = homeserver
        try await session.signIn(presentingFrom: window)
    }
}
