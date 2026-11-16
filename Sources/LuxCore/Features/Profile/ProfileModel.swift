import Foundation

/// The account's own profile, as every screen shows it (Settings, the Mac's rail), and changing
/// its name and picture. One per account, made with it: a change shows everywhere at once.
@MainActor
public final class ProfileModel {
    /// The profile; nil until loaded.
    public private(set) var profile: Profile?
    /// A change is on its way to the server.
    public private(set) var isSaving = false
    public let changes = Broadcast()

    private let account: Task<any ProfilePort, any Error>

    init(account: Task<any ProfilePort, any Error>) {
        self.account = account
    }

    /// Reads the profile from the server; keeps the last one when it cannot.
    public func load() async {
        guard let profile = await bestEffort("profile", { try await account.value.profile() }) else { return }
        self.profile = profile
        changes.send()
    }

    /// Renames the account as typed; an empty name removes it (the user id shows instead). Throws an
    /// `AccountFailure`.
    public func rename(to name: String) async throws {
        try await save { try await $0.setProfileName(name) }
    }

    /// Makes a picked image (any format ImageIO reads) the account's picture.
    public func setPicture(_ image: Data) async throws {
        let jpeg = try await ProfilePicture.jpeg(from: image)
        try await save { try await $0.setProfilePicture(jpeg: jpeg) }
    }

    public func removePicture() async throws {
        try await save { try await $0.removeProfilePicture() }
    }

    /// Runs `change`, then reads the profile again, as the server now has it.
    private func save(_ change: (any ProfilePort) async throws -> Void) async throws {
        isSaving = true
        changes.send()
        defer {
            isSaving = false
            changes.send()
        }
        try await change(try await account.value)
        await load()
    }
}
