import AuthenticationServices
import Foundation

/// The server to sign in to, how it lets the app in, and the two ways in. What `SignInModel` needs
/// of the session; `Session` is its adapter.
@MainActor
protocol SignInPort: AnyObject {
    /// The server to sign in to: the last one chosen, else Lux's own.
    var homeserver: String { get set }
    /// How `homeserver` lets the app sign in. Throws when no Matrix server answers there.
    func loginMethods(for homeserver: String) async throws -> LoginMethods
    /// Signs in at `homeserver` with a user name and password.
    func signIn(user: String, password: String) async throws
    /// Signs in on `homeserver`'s page, in a browser sheet over `anchor`. A sheet the user closed
    /// throws `CancellationError`.
    func signIn(presentingFrom anchor: ASPresentationAnchor) async throws
}

extension Session: SignInPort {}
