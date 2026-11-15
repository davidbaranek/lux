import AppKit
import LuxCore

/// The window's chat pane. A newly chosen chat loads behind the one shown and replaces it at once,
/// with no animation, when its first messages are drawn: switching chats never shows an empty pane.
/// Behind it all, the shown place's colour, faint: under a chat and under "Select a chat" alike.
final class ChatContainerController: NSViewController {
    private var current: NSViewController?
    private let tint = ThemeTint(strength: ThemeTint.chat)
    var theme: PlaceTheme {
        get { tint.theme }
        set { tint.theme = newValue }
    }
    /// A chat slower than this shows at once, with its own loading bubble.
    private static let longestWait: Duration = .milliseconds(600)

    override func loadView() {
        view = NSView()
        tint.frame = view.bounds
        tint.autoresizingMask = [.width, .height]
        view.addSubview(tint)
    }

    func show(_ next: NSViewController) {
        let previous = current
        current = next
        addChild(next)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.width, .height]
        guard let thread = next as? ThreadController, let previous else {
            view.addSubview(next.view)
            remove(previous)
            return
        }
        // the new chat appears whole, at once: its messages do not fade in on their own.
        thread.fadesIn = false
        next.view.alphaValue = 0
        view.addSubview(next.view, positioned: .above, relativeTo: previous.view)
        var revealed = false
        let reveal = { [weak self, weak next] in
            guard !revealed, let next else { return }
            revealed = true
            next.view.alphaValue = 1
            self?.remove(previous)
        }
        thread.onReady = reveal
        Task { @MainActor in
            try? await Task.sleep(for: Self.longestWait)
            reveal()
        }
    }

    private func remove(_ controller: NSViewController?) {
        guard let controller, controller !== current else { return }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }
}
