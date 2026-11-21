import AppKit
import LuxCore
import SwiftUI

/// AI: the one switch for AI in Lux, Apple Intelligence's state on this Mac, and under them the
/// agents on this Mac (`AgentsSettings`).
final class AISettingsController: NSViewController, SearchablePane {
    private let actions: TextActions
    private let agents: AgentsSettings
    private var observation: AnyObject?
    private lazy var form = PaneForm(makeForm())

    init(session: Session) {
        actions = session.textActions
        agents = AgentsSettings(session: session)
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "AI")
        agents.host = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var focus: SettingsFocus { form.focus }

    override func loadView() {
        view = form.view
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
        form.show(makeForm())
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
                Toggle(isOn: Binding(get: { isOn }, set: turn)) { settingsLabel(.aiFeatures) }
                    .settingsRow(.aiFeatures)
                VStack(alignment: .leading, spacing: 2) {
                    Text(SettingsItem.appleIntelligence.title)
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
                .settingsRow(.appleIntelligence)
            }
            agents
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }
}
