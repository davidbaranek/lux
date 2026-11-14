import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The demo's pictures and files (`-LuxDemo`): drawn here once into files, so they go through
/// the same pipeline as downloaded ones. The demo's chats and threads are the Rust core's
/// (`RustAccount.demo`); it has no server to load media from.
struct DemoMedia: Sendable {
    /// A made-up picture: a chat's or a person's, a photo or a video's poster.
    func imageFile(_ ref: ImageRef, directory: URL) throws -> URL? {
        let (name, seed, size): (String, Int, CGSize) = switch ref {
        case .room(let id, _): ("demo-\(stable(id) % 64).png", stable(id) % 64, CGSize(width: 160, height: 160))
        case .person(let url): ("demo-p-\(stable(url) % 64).png", stable(url) % 64, CGSize(width: 160, height: 160))
        case .photo(_, _, let name), .poster(_, _, let name): (name, stable(name), CGSize(width: 1200, height: 900))
        }
        // a sent photo's picture is its file on the device.
        if case .photo(_, _, let name) = ref, name.hasPrefix("/") { return URL(fileURLWithPath: name) }
        let file = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.drawPicture(seed: seed, size: size, to: file)
        return file
    }

    /// A made-up photo or poster drawn large; a made-up file as a page of text.
    func mediaFile(roomId: String, messageId: String, directory: URL) throws -> URL {
        // the made-up history's media go by the message's place in it ("!room1:demo/19").
        let index = Int(messageId.split(separator: "/").last ?? "") ?? 0
        let ref: ImageRef? = if index % 45 == 19 {
            .poster(roomId: roomId, messageId: messageId, name: "demo-poster-\(index % 4).jpg")
        } else if index % 15 == 4, index % 45 != 34 {
            .photo(roomId: roomId, messageId: messageId, name: "demo-photo-\(index % 6).jpg")
        } else {
            nil
        }
        if let ref, let file = try imageFile(ref, directory: directory) { return file }
        let file = directory.appendingPathComponent(index % 45 == 34 ? "Trip plan \(index % 7).pdf" : "Demo.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("A made-up file of the demo.".utf8).write(to: file, options: .atomic)
        return file
    }

    /// A gradient, as a stand-in for a photo.
    private static func drawPicture(seed: Int, size: CGSize, to file: URL) throws {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        var generator = Seeded(seed)
        let colors = (0..<2).map { _ in
            CGColor(srgbRed: .random(in: 0.2...0.9, using: &generator), green: .random(in: 0.2...0.9, using: &generator),
                    blue: .random(in: 0.2...0.9, using: &generator), alpha: 1)
        }
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) else { return }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

/// A hash that is the same in every run (FNV-1a), unlike `hashValue`.
private func stable(_ text: String) -> Int {
    Int(text.utf8.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 } >> 1)
}

/// A small deterministic generator (SplitMix64).
private struct Seeded: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: Int) { state = UInt64(bitPattern: Int64(seed)) &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
