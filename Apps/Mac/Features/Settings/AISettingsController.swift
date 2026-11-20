import AppKit
import LuxCore

/// AI: the one switch for AI in Lux, Apple Intelligence's state on this Mac, and under them the
/// agents on this Mac (`AgentsSettingsController`).
final class AISettingsController: NSViewController {
    private let actions: TextActions
    private let agents: AgentsSettingsController
    private lazy var toggle = NSButton(checkboxWithTitle: String(localized: "AI features"), target: self,
                                       action: #selector(toggled))
    private let status = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: String(localized: """
        Proofread and format a message from the + or the composer's menu in a chat. Off, no AI in Lux \
        reads anything.
        """))
    private var observation: AnyObject?

    init(session: Session) {
        actions = session.textActions
        agents = AgentsSettingsController(session: session)
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "AI")
        addChild(agents)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for label in [note, status] {
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.preferredMaxLayoutWidth = 340
        }
        let separator = NSBox()
        separator.boxType = .separator
        let sections = NSStackView(views: [
            settingsForm([
                [NSTextField(labelWithString: String(localized: "AI:")), toggle],
                [NSGridCell.emptyContentView, note],
                [NSTextField(labelWithString: String(localized: "Apple Intelligence:")), status],
            ]),
            separator,
            agents.view,
        ])
        sections.orientation = .vertical
        sections.spacing = 0
        separator.widthAnchor.constraint(equalTo: sections.widthAnchor, constant: -56).isActive = true
        view = sections
        observation = actions.changes.observe { [weak self] in self?.update() }
        update()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // the system's settings may have changed while the window was away.
        update()
    }

    private func update() {
        toggle.state = actions.isOn ? .on : .off
        status.stringValue = actions.status
    }

    @objc private func toggled() {
        actions.isOn = toggle.state == .on
    }
}
