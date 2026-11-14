import AppKit
import LuxCore
import UniformTypeIdentifiers

/// Sets up recovery for an account that has none, in a sheet, as Element X does: the core makes
/// a recovery key and backs this Mac's message keys up under it; the user saves the key, the
/// only way a new device reads the history when no other device is at hand.
final class RecoverySetupController: NSViewController {
    private let security: SecurityModel
    private let symbol = NSImageView()
    private let heading = NSTextField(labelWithString: "")
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let keyField = NSTextField(wrappingLabelWithString: "")
    private let keyBox = NSView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private lazy var setUp = NSButton(title: String(localized: "Set Up Recovery"), target: self, action: #selector(start))
    private lazy var copy = NSButton(title: String(localized: "Copy"), target: self, action: #selector(copyKey))
    private lazy var save = NSButton(title: String(localized: "Save…"), target: self, action: #selector(saveKey))
    private lazy var done = NSButton(title: String(localized: "Done"), target: self, action: #selector(closeSheet))
    private lazy var later = NSButton(title: String(localized: "Not Now"), target: self, action: #selector(closeSheet))
    private var key: String?

    init(security: SecurityModel) {
        self.security = security
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        symbol.image = NSImage(systemSymbolName: "key.viewfinder", accessibilityDescription: nil)
        symbol.symbolConfiguration = .init(pointSize: 44, weight: .regular)
        symbol.contentTintColor = .controlAccentColor
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        explanation.alignment = .center
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = 400
        keyField.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        keyField.alignment = .center
        keyField.isSelectable = true
        keyField.preferredMaxLayoutWidth = 400
        keyField.setAccessibilityLabel(String(localized: "Recovery key"))
        keyBox.wantsLayer = true
        keyBox.layer?.cornerRadius = 10
        keyBox.layer?.cornerCurve = .continuous
        keyBox.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyBox.addSubview(keyField)
        NSLayoutConstraint.activate([
            keyField.topAnchor.constraint(equalTo: keyBox.topAnchor, constant: 12),
            keyField.bottomAnchor.constraint(equalTo: keyBox.bottomAnchor, constant: -12),
            keyField.leadingAnchor.constraint(equalTo: keyBox.leadingAnchor, constant: 14),
            keyField.trailingAnchor.constraint(equalTo: keyBox.trailingAnchor, constant: -14),
        ])
        keyBox.isHidden = true
        message.alignment = .center
        message.preferredMaxLayoutWidth = 400
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        later.keyEquivalent = "\u{1b}"
        setUp.keyEquivalent = "\r"
        done.keyEquivalent = "\r"
        done.isHidden = true
        copy.isHidden = true
        save.isHidden = true
        let buttons = NSStackView(views: [later, progress, NSView(), copy, save, setUp, done])
        let stack = NSStackView(views: [symbol, heading, explanation, keyBox, message, buttons])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(20, after: message)
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 24, bottom: 20, right: 24)
        for row in [buttons, keyBox] { row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: 480).isActive = true
        view = stack
        heading.stringValue = String(localized: "Keep your messages safe")
        explanation.stringValue = String(localized: """
            Lux makes a recovery key and backs up your message keys with it, encrypted. With the key, \
            a new device reads your encrypted history even when no other device is at hand.
            """)
    }

    @objc private func start() {
        setUp.isEnabled = false
        progress.startAnimation(nil)
        message.stringValue = ""
        Task {
            defer {
                setUp.isEnabled = true
                progress.stopAnimation(nil)
            }
            do {
                show(key: try await security.setUpRecovery())
            } catch {
                message.textColor = .systemRed
                message.stringValue = error.localizedDescription
            }
        }
    }

    private func show(key: String) {
        self.key = key
        symbol.image = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: nil)
        symbol.contentTintColor = .systemGreen
        heading.stringValue = String(localized: "Save your recovery key")
        explanation.stringValue = String(localized: """
            Keep it somewhere safe, such as a password manager. Anyone with it can read your encrypted \
            messages; without it, and with no other device, they cannot be recovered.
            """)
        keyField.stringValue = key
        keyBox.isHidden = false
        later.isHidden = true
        setUp.isHidden = true
        copy.isHidden = false
        save.isHidden = false
        done.isHidden = false
        // the key must be saved before the sheet goes.
        done.isEnabled = false
    }

    @objc private func copyKey() {
        guard let key else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        saved(String(localized: "Copied."))
    }

    @objc private func saveKey() {
        guard let key, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(localized: "Lux Recovery Key.txt")
        panel.allowedContentTypes = [.plainText]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(key.utf8).write(to: url, options: .atomic)
                self?.saved(String(localized: "Saved."))
            } catch {
                self?.message.textColor = .systemRed
                self?.message.stringValue = error.localizedDescription
            }
        }
    }

    private func saved(_ words: String) {
        message.textColor = .secondaryLabelColor
        message.stringValue = words
        done.isEnabled = true
    }

    @objc private func closeSheet() { dismiss(nil) }
}
