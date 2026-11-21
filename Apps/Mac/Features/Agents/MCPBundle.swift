import Foundation
import LuxCore

/// Lux as an MCP Bundle (`.mcpb`): a zip of a `manifest.json` whose server is this app's own
/// executable, run as `agent mcp`. It holds no binary of its own: the app's, signed and in its
/// sandbox, is the server.
enum MCPBundle {
    struct Failed: LocalizedError {
        var errorDescription: String?
    }

    /// The bundle, made in the app's temporary folder.
    static func make() throws -> URL {
        let executable = Bundle.main.executablePath ?? "/Applications/Lux.app/Contents/MacOS/Lux"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let manifest: [String: Any] = [
            "manifest_version": "0.3",
            "name": "lux",
            "display_name": "Lux",
            "version": version,
            "description": "Your chats in Lux on this Mac: search, read and draft, each session approved in Lux.",
            "author": ["name": "Lux"],
            "server": [
                "type": "binary",
                "entry_point": executable,
                "mcp_config": ["command": executable, "args": ["agent", "mcp"]],
            ],
            "compatibility": ["platforms": ["darwin"]],
        ]
        let folder = FileManager.default.temporaryDirectory.appending(path: "Lux-mcpb", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appending(path: "manifest.json"))
        let bundle = FileManager.default.temporaryDirectory.appending(path: "Lux.mcpb")
        if FileManager.default.fileExists(atPath: bundle.path) { try FileManager.default.removeItem(at: bundle) }
        try zip(folder, to: bundle)
        return bundle
    }

    /// `folder`'s contents as a zip at `destination`, the manifest at its root (`ditto`, as
    /// Finder's Compress makes them).
    private static func zip(_ folder: URL, to destination: URL) throws {
        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--norsrc", "--noextattr", folder.path, destination.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw Failed(errorDescription: String(localized: "The bundle could not be compressed."))
        }
    }
}
