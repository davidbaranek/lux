import LuxCore
import UIKit

/// The colours a place (or every place) can take, as a menu: Default (the one for every place),
/// Neutral, then the system's colours, each with its swatch; the current one ticked.
@MainActor
enum ThemeMenu {
    /// A swatch: the colour's filled circle, an empty one for neutral, a dashed one for the default.
    static func swatch(_ theme: PlaceTheme?) -> UIImage? {
        guard let theme else { return UIImage(systemName: "circle.dashed") }
        guard let color = theme.color else {
            return UIImage(systemName: "circle")?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
        }
        return UIImage(systemName: "circle.fill")?.withTintColor(color, renderingMode: .alwaysOriginal)
    }

    /// The menu: `current` ticked; with `defaultTheme`, a first choice that takes it (nil).
    static func menu(title: String = "", current: PlaceTheme?, defaultTheme: PlaceTheme? = nil,
                     choose: @escaping @MainActor (PlaceTheme?) -> Void) -> UIMenu {
        var sections: [UIMenuElement] = []
        if let defaultTheme {
            let follows = UIAction(title: String(localized: "Default"), subtitle: defaultTheme.title, image: swatch(nil),
                                   state: current == nil ? .on : .off) { _ in choose(nil) }
            sections.append(UIMenu(options: .displayInline, children: [follows]))
        }
        let neutral = UIAction(title: PlaceTheme.neutral.title, image: swatch(.neutral), state: current == .neutral ? .on : .off) { _ in
            choose(.neutral)
        }
        sections.append(UIMenu(options: .displayInline, children: [neutral]))
        let colors = PlaceTheme.allCases.filter { $0 != .neutral }.map { theme in
            UIAction(title: theme.title, image: swatch(theme), state: current == theme ? .on : .off) { _ in choose(theme) }
        }
        sections.append(UIMenu(options: .displayInline, children: colors))
        return UIMenu(title: title, image: UIImage(systemName: "paintpalette"), children: sections)
    }
}
