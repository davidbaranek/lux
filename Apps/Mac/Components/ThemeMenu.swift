import AppKit
import LuxCore

/// The colours a place (or every place) can take, as menu items: Default (the one for every
/// place), Neutral, then the system's colours, each with its swatch; the current one ticked.
@MainActor
enum ThemeMenu {
    /// A swatch: the colour's filled circle, an empty one for neutral, a dashed one for the default.
    static func swatch(_ theme: PlaceTheme?) -> NSImage? {
        let name = switch theme {
        case nil: "circle.dashed"
        case .neutral?: "circle"
        default: "circle.fill"
        }
        let color = theme?.color ?? .secondaryLabelColor
        return NSImage(systemSymbolName: name, accessibilityDescription: theme?.title)?
            .withSymbolConfiguration(.init(paletteColors: [color]))
    }

    /// The items, each calling `action` on `target` with its theme (an `NSNumber`-free
    /// `representedObject`: a `PlaceTheme`, or nil for the default) under `place`.
    static func items(current: PlaceTheme?, defaultTheme: PlaceTheme?, target: AnyObject, action: Selector,
                      place: Place? = nil) -> [NSMenuItem] {
        func item(_ title: String, _ theme: PlaceTheme?) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = target
            entry.representedObject = Choice(place: place, theme: theme)
            entry.image = swatch(theme)
            // macOS 27 hides menu images unless asked: the swatch is what the item means.
            if #available(macOS 27, *) { entry.preferredImageVisibility = .visible }
            entry.state = current == theme ? .on : .off
            return entry
        }
        var items: [NSMenuItem] = []
        if let defaultTheme {
            let follows = item(String(localized: "Default"), nil)
            follows.subtitle = defaultTheme.title
            items += [follows, .separator()]
        }
        items += [item(PlaceTheme.neutral.title, .neutral), .separator()]
        items += PlaceTheme.allCases.filter { $0 != .neutral }.map { item($0.title, $0) }
        return items
    }

    /// What an item chooses.
    final class Choice: NSObject {
        let place: Place?
        let theme: PlaceTheme?
        init(place: Place?, theme: PlaceTheme?) { self.place = place; self.theme = theme }
    }
}
