import AVFoundation
import CoreVideo
import Foundation
import Synchronization
import Testing
@testable import LuxCore

/// A video's choice before it goes: which go smaller and how, which may go as they are, and the
/// smaller copy itself.
@Suite(.ownFolder) struct VideoExportTests {
    private let folder: URL

    init() throws {
        folder = try TemporaryFolder.ofTest
    }

    @Test func optimizedA4KVideoBecomes1080pAndOneAlreadySmallGoesAsItIs() {
        #expect(VideoExport.preset(width: 3840, height: 2160, bytes: 400_000_000, limit: nil, quality: .optimized) == AVAssetExportPreset1920x1080)
        // upright: a portrait video is as tall as a landscape one is wide.
        #expect(VideoExport.preset(width: 2160, height: 3840, bytes: 400_000_000, limit: nil, quality: .optimized) == AVAssetExportPreset1920x1080)
        #expect(VideoExport.preset(width: 1920, height: 1080, bytes: 40_000_000, limit: 100_000_000, quality: .optimized) == nil)
        #expect(VideoExport.preset(width: 1280, height: 720, bytes: 4_000_000, limit: nil, quality: .optimized) == nil)
    }

    @Test func aVideoOverTheServersLimitIsOfferedSmallerAndMayNotGoAsItIs() {
        // already 1080p, still over the limit: 720p.
        #expect(VideoExport.preset(width: 1920, height: 1080, bytes: 150_000_000, limit: 100_000_000, quality: .optimized)
            == AVAssetExportPreset1280x720)
        #expect(!VideoExport.canSendOriginal(bytes: 150_000_000, limit: 100_000_000))
        #expect(VideoExport.canSendOriginal(bytes: 100_000_000, limit: 100_000_000))
        // a server that does not say refuses what is too large itself.
        #expect(VideoExport.canSendOriginal(bytes: 150_000_000, limit: nil))
    }

    @Test func theOriginalGoesAsItIs() {
        #expect(VideoExport.preset(width: 3840, height: 2160, bytes: 400_000_000, limit: nil, quality: .original) == nil)
    }

    @Test func aLargeVideoIsMadeA1080pMP4WithItsProgressToTheEnd() async throws {
        let source = try await Self.video(width: 2560, height: 1440, in: folder)
        let size = try await VideoExport.measure(source)
        #expect((size.width, size.height) == (2560, 1440))
        let preset = try #require(VideoExport.preset(width: size.width, height: size.height, bytes: size.bytes, limit: nil, quality: .optimized))

        let heard = Mutex<[Double]>([])
        let copy = try await VideoExport.export(source, preset: preset, in: folder.appending(path: "smaller")) { share in
            heard.withLock { $0.append(share) }
        }
        #expect(copy.pathExtension == "mp4")
        #expect(copy.deletingPathExtension().lastPathComponent == "clip")
        let made = try await VideoExport.measure(copy)
        #expect((made.width, made.height) == (1920, 1080))
        #expect(heard.withLock { $0.last } == 1)
    }

    @MainActor @Test func aLargeVideoWaitingIsMadeSmallerAndItsCopyGoesInItsPlaceUnlessOriginalIsChosen() async throws {
        let large = try await Self.video(width: 2560, height: 1440, in: folder)
        let videos = PendingVideos(directory: folder.appending(path: "smaller")) { 100_000_000 }
        let changes = Changes()
        videos.onChange = { changes.send() }
        videos.follow([large])
        try await changes.until { videos.videos[large] != nil && videos.videos[large]?.progress == nil }
        #expect(videos.videos[large] == PendingVideo(quality: .optimized, canSendOriginal: true, progress: nil))
        let copy = try #require(videos.take([large])[large])
        #expect(try await VideoExport.measure(copy.value).width == 1920)
        #expect(videos.videos.isEmpty)

        // Original, even once the smaller copy is made: it goes as it is.
        videos.follow([large])
        try await changes.until { videos.videos[large] != nil && videos.videos[large]?.progress == nil }
        videos.setQuality(.original, of: large)
        #expect(videos.videos[large]?.quality == .original)
        #expect(videos.videos[large]?.progress == nil)
        #expect(videos.take([large]).isEmpty)
    }

    /// A second of a plain colour, `width` by `height`, as H.264 in a QuickTime file.
    private static func video(width: Int, height: Int, in folder: URL) async throws -> URL {
        let file = folder.appending(path: "clip.mov")
        let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let frames = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<10 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            let pool = try #require(frames.pixelBufferPool)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let frame = try #require(buffer)
            CVPixelBufferLockBaseAddress(frame, [])
            if let base = CVPixelBufferGetBaseAddress(frame) {
                memset(base, Int32(index * 20), CVPixelBufferGetDataSize(frame))
            }
            CVPixelBufferUnlockBaseAddress(frame, [])
            #expect(frames.append(frame, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return file
    }
}
