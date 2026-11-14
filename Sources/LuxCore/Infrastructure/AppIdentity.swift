import Foundation

/// This build's identity, as `Config/Lux.xcconfig` sets it and the targets' Info.plists carry it.
/// The app and its notification extension read the same values (the app's bundle id, not the
/// extension's), so they share the Keychain items, the App Group and the log subsystem. A fork
/// changes the xcconfig, never this code.
public enum AppIdentity {
    /// The app's bundle id: the root of the Keychain services, the background task ids and the
    /// log subsystem. Outside the apps (unit tests), the process's own.
    public static let bundleId = string("LuxBundleID") ?? Bundle.main.bundleIdentifier ?? "lux"
    /// The App Group the iPhone app shares with its notification extension.
    public static let appGroup = string("LuxAppGroup") ?? "group.\(bundleId)"
    /// The push gateway's notify URL; nil when the build has none (no push notifications).
    public static let pushGateway = string("LuxPushGateway").flatMap(URL.init(string:))
    /// The app's page (OAuth `client_uri`); nil when the build has none (password sign-in only).
    public static let oauthClientURI = string("LuxOAuthClientURI").flatMap(URL.init(string:))

    /// An Info.plist value; an xcconfig variable left empty is no value.
    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else { return nil }
        return value
    }
}
