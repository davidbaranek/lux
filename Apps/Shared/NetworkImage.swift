import LuxCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A network's picture in both apps: its logo, or for a network without one its symbol in white
/// on a tile like the logos' (24 points, corner 5.4) in its colour, so a network never shows
/// another's logo or none.
@MainActor
enum NetworkImage {
    private static let side: CGFloat = 24
    private static let corner: CGFloat = 5.4

    private static func tint(_ network: String) -> CGColor {
        let rgb = Networks.tint(network)
        let channel = { (shift: UInt32) in CGFloat(rgb >> shift & 0xFF) / 255 }
        return CGColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
    }
    #if canImport(UIKit)
    private static var tiles: [String: UIImage] = [:]

    static func image(_ network: String) -> UIImage {
        if let logo = Networks.logo(network), let image = UIImage(named: logo) { return image }
        if let tile = tiles[network] { return tile }
        let symbol = UIImage(systemName: Networks.symbol(network),
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        let tile = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            UIColor(cgColor: tint(network)).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerRadius: corner).fill()
            if let symbol {
                symbol.draw(at: CGPoint(x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2))
            }
        }.withRenderingMode(.alwaysOriginal)
        tiles[network] = tile
        return tile
    }
    #else
    private static var tiles: [String: NSImage] = [:]

    static func image(_ network: String) -> NSImage {
        if let logo = Networks.logo(network), let image = NSImage(named: logo) { return image }
        if let tile = tiles[network] { return tile }
        let symbol = NSImage(systemSymbolName: Networks.symbol(network), accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white])))
        // drawn at whatever size it shows, as the logos' vectors are.
        let color = NSColor(cgColor: tint(network))
        let tile = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            color?.setFill()
            NSBezierPath(roundedRect: rect, xRadius: corner * rect.width / side, yRadius: corner * rect.height / side).fill()
            if let symbol {
                let scale = rect.width / side
                let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
                symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                       width: size.width, height: size.height))
            }
            return true
        }
        tiles[network] = tile
        return tile
    }
    #endif
}
