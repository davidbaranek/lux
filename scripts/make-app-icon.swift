// SPDX-License-Identifier: GPL-3.0-only
// Makes the app icons from design/lux-icon-source.png. Run from the repository root:
// `swift scripts/make-app-icon.swift .`
// A full-bleed 1024 for iOS (the system masks it) and the macOS sizes on Apple's icon grid (an
// 824 pt rounded square on 1024, with a soft shadow), since the Mac draws an icon as given.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let source = NSImage(contentsOf: root.appendingPathComponent("design/lux-icon-source.png"))!
let out = root.appendingPathComponent("Apps/Shared/AppIcon.xcassets/AppIcon.appiconset")

func render(_ pixels: Int, mac: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let size = CGFloat(pixels)
    if mac {
        let scale = size / 1024
        let rect = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
        let path = NSBezierPath(roundedRect: rect, xRadius: 185 * scale, yRadius: 185 * scale)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 20 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -8 * scale)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor(red: 0x0C / 255, green: 0x11 / 255, blue: 0x18 / 255, alpha: 1).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        path.addClip()
        source.draw(in: rect)
    } else {
        source.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
try render(1024, mac: false).write(to: out.appendingPathComponent("ios-1024.png"))
images.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "ios-1024.png"])
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "mac-\(points)@\(scale)x.png"
        try render(points * scale, mac: true).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))
