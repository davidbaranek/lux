#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A place's colour (`lux_core::places::Theme`): neutral, the apps' own look, or one of the
/// system's colours, drawn in the platform's shade of it. The account keeps one for each place the
/// user gave one, and one for the others.
public enum PlaceTheme: String, CaseIterable, Hashable, Sendable {
    case neutral, red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown

    public var title: String {
        switch self {
        case .neutral: String(localized: "Neutral")
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .mint: String(localized: "Mint")
        case .teal: String(localized: "Teal")
        case .cyan: String(localized: "Cyan")
        case .blue: String(localized: "Blue")
        case .indigo: String(localized: "Indigo")
        case .purple: String(localized: "Purple")
        case .pink: String(localized: "Pink")
        case .brown: String(localized: "Brown")
        }
    }

    #if canImport(UIKit)
    public typealias Color = UIColor
    #else
    public typealias Color = NSColor
    #endif

    /// The colour: the system's, deepened (darker and a little less saturated) so it reads as a
    /// calm accent rather than a bright one; nil for neutral, which keeps the app's accent.
    public var color: Color? {
        guard let base = systemColor else { return nil }
        #if canImport(UIKit)
        return UIColor { traits in Self.deepened(base.resolvedColor(with: traits), dark: traits.userInterfaceStyle == .dark) }
        #else
        return NSColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance { resolved = base.usingColorSpace(.sRGB) ?? base }
            return Self.deepened(resolved, dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        }
        #endif
    }

    /// The same hue, darker and less saturated; in the dark a little less so, to stay readable.
    private static func deepened(_ color: Color, dark: Bool) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: saturation * 0.8, brightness: brightness * (dark ? 0.8 : 0.68), alpha: alpha)
    }

    private var systemColor: Color? {
        switch self {
        case .neutral: nil
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .mint: .systemMint
        case .teal: .systemTeal
        case .cyan: .systemCyan
        case .blue: .systemBlue
        case .indigo: .systemIndigo
        case .purple: .systemPurple
        case .pink: .systemPink
        case .brown: .systemBrown
        }
    }
}
