import Foundation

/// What a device registers with its server to be pushed to: the server sends the ids of the
/// events that notify to the gateway, which wakes the device through Apple's service.
public struct Pusher: Sendable, Equatable {
    /// The token the system gave the app.
    public var token: Data
    /// Which of Apple's services the token is for.
    public var environment: PushEnvironment
    /// The gateway's app id for production (the sandbox's has `.dev` after it).
    public var appId: String
    /// The gateway's notify URL.
    public var gateway: URL
    /// The app's and the device's names, as the account's pushers list them.
    public var appName: String
    public var deviceName: String
    /// The language of what the server words (`en`).
    public var language: String
    /// What a notification says when the notification extension cannot read its event.
    public var fallbackText: String
}

/// Which of Apple's push services a build's token belongs to.
public enum PushEnvironment: Sendable, Equatable {
    case production, sandbox

    /// This build's: a build signed for development carries the sandbox in its provisioning
    /// profile; the App Store's builds (and their testers') have no profile in them, and push
    /// through production.
    public static let current: PushEnvironment = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = bestEffort("push: read the provisioning profile", { try Data(contentsOf: url) }) else { return .production }
        return environment(ofProfile: data)
    }()

    /// The environment a provisioning profile grants (its plist is inside a signed envelope,
    /// readable as text).
    static func environment(ofProfile data: Data) -> PushEnvironment {
        let text = String(decoding: data, as: UTF8.self)
        guard let key = text.range(of: "<key>aps-environment</key>") else { return .production }
        let rest = text[key.upperBound...].prefix(80)
        return rest.contains("<string>development</string>") ? .sandbox : .production
    }
}
