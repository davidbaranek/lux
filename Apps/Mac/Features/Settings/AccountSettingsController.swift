import AppKit
import LuxCore
import SwiftUI
import UniformTypeIdentifiers

/// The account: its picture and name (changed here, seen in every chat), its Matrix ID, read
/// receipts and Sign Out.
final class AccountSettingsController: NSViewController {
    private let model: SettingsModel
    private let profile: ProfileModel?
    private var observation: AnyObject?
    private let signOut: () -> Void
    private let images: ImagePipeline?
    /// Counts the changes that failed: the name field shows the server's name again.
    private var failures = 0
    private lazy var form = NSHostingView.pane(makeForm())

    init(model: SettingsModel, profile: ProfileModel?, images: ImagePipeline?, signOut: @escaping () -> Void) {
        self.model = model
        self.profile = profile
        self.images = images
        self.signOut = signOut
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Account")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = form
        observation = model.changes.observe { [weak self] in self?.update() }
    }

    private func update() {
        form.rootView = makeForm()
    }

    private func makeForm() -> AccountForm {
        AccountForm(
            profile: model.profile, isSaving: model.isSavingProfile, sendsReadReceipts: model.sendsReadReceipts,
            failures: failures, images: images,
            actions: .init(
                rename: { [weak self] in self?.saveName($0) },
                choosePicture: { [weak self] in self?.pickPicture() },
                removePicture: { [weak self] in self?.confirmRemovePicture() },
                readReceipts: { [weak self] in
                    self?.model.sendsReadReceipts = $0
                    self?.update()
                },
                signOut: { [weak self] in self?.confirmSignOut() }
            )
        )
    }

    // MARK: Name

    /// Return in the field saves; so does leaving it with a change.
    private func saveName(_ typed: String) {
        guard let profile, !profile.isSaving, typed.trimmingCharacters(in: .whitespacesAndNewlines) != (model.profile?.displayName ?? "") else { return }
        change(String(localized: "The name could not be saved.")) { try await profile.rename(to: typed) }
    }

    // MARK: Picture

    private func pickPicture() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a picture for your account. Its centre square is used.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let file = panel.url, let self, let profile else { return }
            change(String(localized: "The picture could not be set.")) {
                let data = try Data(contentsOf: file)
                try await profile.setPicture(data)
            }
        }
    }

    private func confirmRemovePicture() {
        guard let window = view.window, let profile else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove your picture?")
        alert.informativeText = String(localized: "People will see your initials instead.")
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.change(String(localized: "The picture could not be removed.")) { try await profile.removePicture() }
        }
    }

    /// Runs a change of the profile; a failure is told, since the user asked for the change.
    private func change(_ title: String, _ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                Log.app.error("profile change: \(String(describing: error), privacy: .public)")
                failures += 1
                update()
                guard let window = view.window else { return }
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = error.localizedDescription
                _ = await alert.beginSheetModal(for: window)
            }
        }
    }

    // MARK: Account

    private func confirmSignOut() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Sign out of this Mac?")
        alert.informativeText = String(localized: "This device leaves the account. Without a recovery key, it cannot read encrypted messages again.")
        alert.addButton(withTitle: String(localized: "Sign Out"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            window.close()
            self?.signOut()
        }
    }
}

/// The Account pane's form: who the account is, its name and picture, this device and read
/// receipts, and Sign Out under them.
struct AccountForm: View {
    struct Actions {
        var rename: @MainActor (String) -> Void
        var choosePicture: @MainActor () -> Void
        var removePicture: @MainActor () -> Void
        var readReceipts: @MainActor (Bool) -> Void
        var signOut: @MainActor () -> Void
    }

    let profile: Profile?
    let isSaving: Bool
    let sendsReadReceipts: Bool
    let failures: Int
    let images: ImagePipeline?
    let actions: Actions
    /// The name as typed: it takes the server's only while the field is not being edited.
    @State private var name = ""
    @FocusState private var editing: Bool

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Avatar(ref: profile?.avatar, name: profile?.name ?? "", side: 56, images: images)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile?.name ?? "").font(.title3.weight(.semibold))
                        Text(profile?.userId ?? "").foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                TextField(String(localized: "Name"), text: $name, prompt: Text(String(localized: "Name")))
                    .focused($editing)
                    .onSubmit { actions.rename(name) }
                    .disabled(profile?.canChangeName != true || isSaving)
                    .accessibilityIdentifier("profile.name")
                LabeledContent(String(localized: "Picture")) {
                    HStack {
                        if isSaving { ProgressView().controlSize(.small) }
                        Button(String(localized: "Remove"), action: actions.removePicture)
                            .disabled(profile?.canChangeAvatar != true || profile?.avatar == nil || isSaving)
                            .accessibilityIdentifier("profile.removePicture")
                        Button(String(localized: "Choose…"), action: actions.choosePicture)
                            .disabled(profile?.canChangeAvatar != true || isSaving)
                            .accessibilityIdentifier("profile.choosePicture")
                    }
                }
            } footer: {
                Text(String(localized: "People see this name and picture in your Matrix chats. Bridged networks such as WhatsApp keep their own."))
                    .formFooter()
            }
            Section {
                LabeledContent(String(localized: "Device"), value: String(localized: "This Mac"))
                Toggle(isOn: Binding(get: { sendsReadReceipts }, set: actions.readReceipts)) {
                    Text(String(localized: "Send read receipts"))
                    Text(String(localized: "Others see when you have read their messages, on WhatsApp and Instagram too."))
                }
            } footer: {
                HStack {
                    Spacer()
                    Button(String(localized: "Sign Out…"), action: actions.signOut)
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .onChange(of: profile?.displayName, initial: true) { if !editing { name = profile?.displayName ?? "" } }
        .onChange(of: failures) { name = profile?.displayName ?? "" }
        .onChange(of: editing) { if !editing { actions.rename(name) } }
    }
}

extension Text {
    /// A section's footer, as System Settings sets one under its group.
    func formFooter() -> some View {
        font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}
