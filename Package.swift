// swift-tools-version:6.2
import PackageDescription

// LuxKit: everything both apps share. The UI (UIKit, AppKit) lives in the app targets only.
// Run scripts/setup-sdk.sh first: it builds the Rust core into Vendor/.
// a warning fails the build: what the compiler can tell is fixed before it runs.
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "LuxKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "LuxCore", targets: ["LuxCore"]),
    ],
    targets: [
        // the Rust core (`core/`, built by `cargo xtask apple`): one static library, and its
        // generated Swift bindings (UniFFI's, Sendable, checked as Swift 6).
        .binaryTarget(name: "LuxFFI", path: "Vendor/LuxFFI.xcframework"),
        .target(name: "LuxBindings", dependencies: ["LuxFFI"], path: "Vendor/LuxBindings",
                swiftSettings: [.swiftLanguageMode(.v6)]),
        // the shared model: session, chat list, threads, the image pipeline. No UI framework.
        .target(name: "LuxCore", dependencies: ["LuxBindings"], swiftSettings: strict),
        .testTarget(name: "LuxCoreTests", dependencies: ["LuxCore"], swiftSettings: strict),
    ]
)
