import Foundation

/// The launch arguments the apps understand, for measurements, screenshots and the UI tests.
public enum LaunchOptions {
    /// `-LuxDemo`: made-up chats, no account and no server.
    public static let isDemo = ProcessInfo.processInfo.arguments.contains("-LuxDemo")
    /// The demo shows the welcome to the server's networks, as after signing in (`-LuxNetworksWelcome`).
    public static let showsNetworksWelcome = ProcessInfo.processInfo.arguments.contains("-LuxNetworksWelcome")
    /// The demo's device must verify after signing in, the account keeping a recovery key (`-LuxDemoUnverified`).
    public static let demoUnverified = ProcessInfo.processInfo.arguments.contains("-LuxDemoUnverified")
    /// The demo's account has no recovery yet (`-LuxDemoNoRecovery`).
    public static let demoNoRecovery = ProcessInfo.processInfo.arguments.contains("-LuxDemoNoRecovery")
    /// Another of the demo's devices asks to verify, a few seconds after launch (`-LuxDemoVerificationRequest`).
    public static let demoVerificationRequest = ProcessInfo.processInfo.arguments.contains("-LuxDemoVerificationRequest")
    /// `-LuxPhotoModel <folder>`: photo search's model from this folder (`scripts/image-search/
    /// package.sh` writes it) in place of its asset pack, before App Store Connect hosts the pack.
    /// The folder must be one the app can read (in its container on the Mac).
    public static let photoModel: URL? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let at = arguments.firstIndex(of: "-LuxPhotoModel"), arguments.indices.contains(at + 1) else { return nil }
        return URL(fileURLWithPath: arguments[at + 1], isDirectory: true)
    }()
    /// `-LuxBenchmark`: the chat list and a chat scroll themselves, and report late frames (`FrameMeter`).
    public static let isBenchmark = ProcessInfo.processInfo.arguments.contains("-LuxBenchmark")
}
