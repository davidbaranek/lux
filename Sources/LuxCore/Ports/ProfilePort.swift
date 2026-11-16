import Foundation

/// The account's own profile: reading it and changing its name and picture. What `ProfileModel`
/// needs of an account; the Rust core's account adapts it (`RustAccountActions.swift`).
protocol ProfilePort: Sendable {
    func profile() async throws -> Profile
    /// Renames the account; an empty name removes it.
    func setProfileName(_ name: String) async throws
    func setProfilePicture(jpeg: Data) async throws
    func removeProfilePicture() async throws
}
