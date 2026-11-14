#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A name's stand-in for a missing picture, as every list shows it: up to two initials, white,
/// on a colour the name picks from a fixed palette (the same name, the same colour, on every
/// device). The notification extension draws it too, so a sender without a picture is no app icon.
public enum Monogram {
    /// The first letters of the name's first two words.
    public static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" }).filter { $0.first?.isLetter == true }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }

    #if canImport(UIKit)
    public typealias Color = UIColor
    #else
    public typealias Color = NSColor
    #endif

    private static let palette: [Color] = [.systemBlue, .systemGreen, .systemOrange, .systemPink, .systemPurple, .systemTeal, .systemIndigo, .systemRed]

    /// The name's colour.
    public static func color(_ name: String) -> Color {
        palette[Int(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ $1.value) % 9_973 }) % palette.count]
    }

    /// The initials' size in a circle of `side` points.
    public static func fontSize(_ side: CGFloat) -> CGFloat { side * 0.38 }

    #if canImport(UIKit)
    /// The monogram as a round picture `side` points across.
    public static func image(_ name: String, side: CGFloat) -> UIImage {
        let initials = initials(name) as NSString
        let font = UIFont.systemFont(ofSize: fontSize(side), weight: .semibold)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            color(name).setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            let size = initials.size(withAttributes: attributes)
            initials.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attributes)
        }
    }
    #endif
}
