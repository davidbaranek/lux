import AppKit
import LuxCore

/// Picks any emoji from the system's Character Viewer: an invisible field takes the focus, the
/// viewer types into it, and the first emoji is reported.
final class EmojiPicker: NSTextField, NSTextFieldDelegate {
    private var onPick: ((String) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        isBordered = false
        drawsBackground = false
        alphaValue = 0
        delegate = self
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func pick(in view: NSView, _ completion: @escaping (String) -> Void) {
        if superview == nil { view.addSubview(self) }
        onPick = completion
        stringValue = ""
        window?.makeFirstResponder(self)
        NSApp.orderFrontCharacterPalette(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let emoji = stringValue.firstEmoji else { return }
        stringValue = ""
        onPick?(emoji)
        onPick = nil
    }
}
