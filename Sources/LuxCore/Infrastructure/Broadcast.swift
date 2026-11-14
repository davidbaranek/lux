import Foundation

/// Tells every observer of a model that it changed. An observer stays until its token goes.
@MainActor
public final class Broadcast {
    private var handlers: [UUID: () -> Void] = [:]

    public init() {}

    /// Calls `handler` on every change while the returned token is kept.
    public func observe(_ handler: @escaping () -> Void) -> AnyObject {
        let id = UUID()
        handlers[id] = handler
        return Token { [weak self] in self?.handlers[id] = nil }
    }

    public func send() {
        for handler in handlers.values { handler() }
    }

    @MainActor
    private final class Token {
        let cancel: () -> Void
        init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
        isolated deinit { cancel() }
    }
}
