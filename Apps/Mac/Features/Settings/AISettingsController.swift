import AppKit
import LuxCore
import SwiftUI

/// AI: the one switch for AI in Lux, Apple Intelligence's state on this Mac, and under them the
/// agents on this Mac (`AgentsSettings`).
final class AISettingsController: NSViewController {
    private let actions: TextActions
    private let agents: AgentsSettings
    private var observation: AnyObject?
    private lazy var form = NSHostingView.pane(makeForm())

    init(session: Session) {
        actions = session.textActions
        agents = AgentsSettings(session: session)
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "AI")
        agents.host = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = form
        observation = actions.changes.observe { [weak self] in self?.update() }
        agents.onChange = { [weak self] in self?.update() }
        agents.load()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // the system's settings may have changed while the pane was away.
        update()
    }

    private func update() {
        form.rootView = makeForm()
    }

    private func makeForm() -> AIForm {
        AIForm(isOn: actions.isOn, status: actions.status, agents: agents.sections) { [weak self] in self?.actions.isOn = $0 }
    }
}

struct AIForm: View {
    let isOn: Bool
    let status: String
    let agents: AgentsSections
    let turn: @MainActor (Bool) -> Void

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { isOn }, set: turn)) {
                    Text(String(localized: "AI features"))
                    Text(String(localized: """
                        Proofread and format a message from the + or the composer's menu in a chat. Off, no AI in Lux \
                        reads anything.
                        """))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Apple Intelligence"))
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            }
            agents
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }
}
