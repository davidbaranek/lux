import AppKit
import LuxCore
import SwiftUI

/// Networks: the networks the account's server bridges, one row each with its logo, whether the
/// account is signed in there, and a button to sign in or out. A server that offers none, or a
/// bridge that does not answer, says so, with the guide for its admin.
final class NetworksSettingsController: NSViewController, SearchablePane {
    private let model: NetworksModel
    private var observation: AnyObject?
    private lazy var form = PaneForm(makeForm())

    init(model: NetworksModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Networks")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func reveal(_ item: SettingsItem) {
        form.focus.reveal(item)
    }

    override func loadView() {
        view = form.view
        observation = model.changes.observe { [weak self] in self?.update() }
        Task { await model.load() }
    }

    private func update() {
        form.show(makeForm())
    }

    private func makeForm() -> NetworksForm {
        NetworksForm(offers: model.offers, statuses: model.statuses, actions: .init(
            connect: { [weak self] offer in
                guard let self, let window = view.window else { return }
                NetworkSignInController.present(model.signIn(to: offer), over: window) {}
            },
            signOut: { [weak self] offer, login in
                guard let self, let window = view.window else { return }
                NetworksController.confirmLogOut(offer, login: login, model: model, over: window)
            },
            retry: { [weak self] offer in Task { await self?.model.refresh(offer) } },
            reload: { [weak self] in Task { await self?.model.load() } }
        ))
    }
}

struct NetworksForm: View {
    struct Actions {
        var connect: @MainActor (NetworkOffer) -> Void
        var signOut: @MainActor (NetworkOffer, NetworkAccount.Login) -> Void
        var retry: @MainActor (NetworkOffer) -> Void
        var reload: @MainActor () -> Void
    }

    let offers: NetworksModel.Offers
    let statuses: [NetworkOffer: NetworksModel.Status]
    let actions: Actions

    var body: some View {
        Form {
            Section {
                switch offers {
                case .loading:
                    HStack {
                        Text(String(localized: "Asking your server…")).foregroundStyle(.secondary)
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                case .notSet(let server):
                    message(String(localized: "\(server) offers no networks to Lux"),
                            String(localized: "Its server may bridge WhatsApp, Messenger and others, but does not tell Lux where. Its admin can set that up; until then, you can still sign in to a bridge by writing to its bot."),
                            symbol: "network.slash") {
                        Button(String(localized: "How a Server Offers Networks")) { NSWorkspace.shared.open(BridgeSetup.guide) }
                    }
                case .failed(let failure):
                    message(String(localized: "Your server could not be asked"), failure.localizedDescription,
                            symbol: "exclamationmark.triangle") {
                        Button(String(localized: "Try Again"), action: actions.reload)
                    }
                case .offered(let offers):
                    ForEach(offers, id: \.self, content: row)
                }
            } footer: {
                Text(SettingsItem.networks.detail ?? "").formFooter().settingsRow(.networks)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ offer: NetworkOffer) -> some View {
        let (status, color, button) = state(of: offer)
        return HStack(spacing: 10) {
            Image(nsImage: NetworkImage.image(offer.network)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(offer.name)
                Text(status).font(.callout).foregroundStyle(color)
            }
            Spacer(minLength: 8)
            if let (title, perform) = button {
                Button(title, action: perform).accessibilityLabel("\(title) \(offer.name)")
            }
        }
        .padding(.vertical, 2)
    }

    /// What a network's row says, in which colour, and its button.
    private func state(of offer: NetworkOffer) -> (String, Color, (String, @MainActor () -> Void)?) {
        switch statuses[offer] ?? .loading {
        case .loading:
            return (String(localized: "Checking…"), .secondary, nil)
        case .account(let account):
            guard let login = account.logins.first else {
                return (String(localized: "Not connected"), .secondary, (String(localized: "Connect…"), { actions.connect(offer) }))
            }
            let status = login.state == .connected ? String(localized: "Connected as \(login.name)") : "\(login.name) · \(login.state.title)"
            let color: Color = login.state.needsSignIn ? .orange : .secondary
            if account.needsSignIn {
                return (status, color, (String(localized: "Connect…"), { actions.connect(offer) }))
            }
            return (status, color, (String(localized: "Sign Out…"), { actions.signOut(offer, login) }))
        case .failed(let failure):
            return (failure.localizedDescription, .red, (String(localized: "Retry"), { actions.retry(offer) }))
        }
    }

    private func message(_ title: String, _ detail: String, symbol: String, @ViewBuilder button: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    Text(detail).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            }
            button()
        }
        .padding(.vertical, 4)
    }
}
