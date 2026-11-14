import Foundation

/// The launch arguments the apps understand, for measurements, screenshots and the UI tests.
public enum LaunchOptions {
    /// `-LuxDemo`: made-up chats, no account and no server.
    public static let isDemo = ProcessInfo.processInfo.arguments.contains("-LuxDemo")
    /// `-LuxBenchmark`: the chat list and a chat scroll themselves, and report late frames (`FrameMeter`).
    public static let isBenchmark = ProcessInfo.processInfo.arguments.contains("-LuxBenchmark")
}
