import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LuxCore

/// The account's profile over the Rust core's demo account: renaming it, and setting and removing
/// its picture, as every screen sees them.
@MainActor
@Suite(.closesDemoSessions)
struct ProfileTests {
    private let session = DemoSessions.open(rooms: 4, messagesPerRoom: 2)

    @Test func renamingTrimsTheNameAndAnEmptyOneShowsTheUserId() async throws {
        let profile = try #require(session.profile)
        await profile.load()
        #expect(profile.profile?.name == "Demo")
        #expect(profile.profile?.canChangeName == true)

        try await profile.rename(to: "  Ada Lovelace ")
        #expect(profile.profile?.displayName == "Ada Lovelace")
        try await profile.rename(to: " ")
        #expect(profile.profile?.displayName == nil)
        #expect(profile.profile?.name == "me")
    }

    @Test func aNameTooLongIsRefused() async throws {
        let profile = try #require(session.profile)
        await #expect(throws: AccountFailure.nameTooLong) { try await profile.rename(to: String(repeating: "x", count: 257)) }
    }

    @Test func aPictureIsSetAndRemoved() async throws {
        let profile = try #require(session.profile)
        try await profile.setPicture(Self.png(width: 900, height: 600))
        let set = try #require(profile.profile?.avatar)
        try await profile.setPicture(Self.png(width: 40, height: 40))
        #expect(profile.profile?.avatar != set)
        try await profile.removePicture()
        #expect(profile.profile?.avatar == nil)
    }

    @Test func aPictureIsCutToItsCentreSquareAtMostTheSide() async throws {
        let large = try await ProfilePicture.jpeg(from: Self.png(width: 1800, height: 1200))
        #expect(Self.size(large) == CGSize(width: ProfilePicture.side, height: ProfilePicture.side))
        let small = try await ProfilePicture.jpeg(from: Self.png(width: 80, height: 120))
        #expect(Self.size(small) == CGSize(width: 80, height: 80))
        await #expect(throws: ProfilePicture.Failure.self) { try await ProfilePicture.jpeg(from: Data("no picture".utf8)) }
    }

    private static func png(width: Int, height: Int) throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func size(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}

/// The profile model over its port alone: a rename goes to the server and the profile shows
/// what the server then has.
@MainActor
struct ProfilePortTests {
    private actor Server: ProfilePort {
        private var name: String?

        func profile() async throws -> Profile {
            Profile(userId: "@anna:example.org", name: name ?? "anna", displayName: name, avatar: nil,
                    canChangeName: true, canChangeAvatar: false)
        }
        func setProfileName(_ name: String) async throws { self.name = name.isEmpty ? nil : name }
        func setProfilePicture(jpeg: Data) async throws {}
        func removeProfilePicture() async throws {}
    }

    @Test func aRenameShowsWhatTheServerNowHas() async throws {
        let model = ProfileModel(account: Task { Server() })
        await model.load()
        #expect(model.profile?.name == "anna" && model.profile?.displayName == nil)
        try await model.rename(to: "Anna Nováková")
        #expect(model.profile?.displayName == "Anna Nováková")
        #expect(!model.isSaving)
        try await model.rename(to: "")
        #expect(model.profile?.name == "anna")
    }
}
