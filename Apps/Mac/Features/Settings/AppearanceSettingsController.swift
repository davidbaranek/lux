import AppKit
import LuxCore
import SwiftUI

/// Appearance: the colour of the places without their own (the account keeps it, so every device
/// shows it; a place's own colour is in its menu on the rail), and how chats draw their messages
/// (on this device).
final class AppearanceSettingsController: NSViewController, SearchablePane {
    private let list: ChatListModel
    /// The colour as chosen here: the list has it a moment later.
    private lazy var theme = list.defaultTheme
    private lazy var form = PaneForm(makeForm())

    init(list: ChatListModel) {
        self.list = list
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Appearance")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var focus: SettingsFocus { form.focus }

    override func loadView() {
        view = form.view
    }

    private func makeForm() -> AppearanceForm {
        AppearanceForm(
            theme: theme, chatStyle: Preferences.shared.chatStyle,
            chooseTheme: { [weak self] theme in
                guard let self else { return }
                self.theme = theme
                list.setDefaultTheme(theme)
                form.show(makeForm())
            },
            chooseStyle: { [weak self] style in
                Preferences.shared.chatStyle = style
                if let self { form.show(makeForm()) }
            }
        )
    }
}

struct AppearanceForm: View {
    let theme: PlaceTheme
    let chatStyle: ChatStyle
    let chooseTheme: @MainActor (PlaceTheme) -> Void
    let chooseStyle: @MainActor (ChatStyle) -> Void

    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(get: { theme }, set: chooseTheme)) {
                    swatch(.neutral)
                    Divider()
                    ForEach(PlaceTheme.allCases.filter { $0 != .neutral }, id: \.self, content: swatch)
                } label: {
                    settingsLabel(.placesColour)
                }
                .settingsRow(.placesColour)
            }
            Section(SettingsItem.messageStyle.title) {
                ChatStyleChoice(style: chatStyle, choose: chooseStyle)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .settingsRow(.messageStyle)
            }
        }
        .formStyle(.grouped)
    }

    private func swatch(_ theme: PlaceTheme) -> some View {
        Label {
            Text(theme.title)
        } icon: {
            Image(nsImage: ThemeMenu.swatch(theme) ?? NSImage())
        }
        .tag(theme)
    }
}

/// The bubbles-or-rows picker (`ChatStylePicker`) in a SwiftUI form.
private struct ChatStyleChoice: NSViewRepresentable {
    let style: ChatStyle
    let choose: @MainActor (ChatStyle) -> Void

    func makeNSView(context: Context) -> ChatStylePicker {
        ChatStylePicker(style: style)
    }

    func updateNSView(_ picker: ChatStylePicker, context: Context) {
        if picker.style != style { picker.style = style }
        picker.onChoose = choose
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChatStylePicker, context: Context) -> CGSize? {
        nsView.fittingSize
    }
}
