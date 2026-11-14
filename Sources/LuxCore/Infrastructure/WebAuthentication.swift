import AuthenticationServices
import Foundation

/// ASWebAuthenticationSession as one async call. The caller keeps it until the call returns.
@MainActor
final class WebAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    private var session: ASWebAuthenticationSession?

    init(anchor: ASPresentationAnchor) { self.anchor = anchor }

    func run(url: URL, callbackScheme: String) async throws -> URL {
        defer { session = nil }
        return try await withCheckedThrowingContinuation { continuation in
            // the system calls back on a queue of its own: the handler must not be main-actor isolated.
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { @Sendable url, error in
                if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: error ?? CancellationError()) }
            }
            session.presentationContextProvider = self
            self.session = session
            session.start()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor }
    }
}
