import LuxCore
import UIKit

/// Picks any emoji from the system's emoji keyboard: an invisible field that asks for the emoji
/// input mode and reports the first emoji typed.
final class EmojiPicker: UITextField, UITextFieldDelegate {
    private var onPick: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        autocorrectionType = .no
        tintColor = .clear
        alpha = 0
        accessibilityElementsHidden = true
        addAction(UIAction { [weak self] _ in self?.picked() }, for: .editingChanged)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The emoji keyboard, when the user has one (every iPhone does).
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }

    func pick(_ completion: @escaping (String) -> Void) {
        onPick = completion
        text = ""
        becomeFirstResponder()
    }

    private func picked() {
        guard let emoji = text?.firstEmoji, let pick = onPick else { return }
        // ending the editing forgets the completion, so it is taken first.
        onPick = nil
        text = ""
        resignFirstResponder()
        pick(emoji)
    }

    func textFieldDidEndEditing(_ textField: UITextField) { onPick = nil }
}
