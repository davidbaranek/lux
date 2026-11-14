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

    /// The system colour; nil for neutral, which keeps the app's accent.
    public var color: Color? {
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
