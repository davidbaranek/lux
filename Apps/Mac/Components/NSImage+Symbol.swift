import AppKit

extension NSImage {
    /// The system symbol `name`, for a control that needs an image. A name the system lacks
    /// shows nothing rather than stopping the app.
    static func symbol(_ name: String, label: String? = nil) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
    }
}
