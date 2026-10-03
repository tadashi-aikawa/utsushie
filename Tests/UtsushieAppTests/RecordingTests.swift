@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import ScreenCaptureKit
import Testing
import UtsushieCore
@testable import Utsushie

// サンプルは作成後に変更しない。SCStream同様、保持してwriterの専用キューへ渡す。
private struct ImmutableSample: @unchecked Sendable { let buffer: CMSampleBuffer }

private func sample(time: Double, status: SCFrameStatus = .complete) throws -> ImmutableSample {
    var pixels: CVPixelBuffer?
    let created = CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
    #expect(created == kCVReturnSuccess)
    let image = try #require(pixels)
    CVPixelBufferLockBaseAddress(image, [])
    memset(CVPixelBufferGetBaseAddress(image), 255, CVPixelBufferGetDataSize(image))
    CVPixelBufferUnlockBaseAddress(image, [])
    var description: CMVideoFormatDescription?
    #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &description) == noErr)
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 60000), decodeTimeStamp: .invalid)
    var buffer: CMSampleBuffer?
    #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
        formatDescription: try #require(description), sampleTiming: &timing, sampleBufferOut: &buffer) == noErr)
    let result = try #require(buffer)
    let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true)) as NSArray
    let dictionary = try #require(attachments.firstObject as? NSMutableDictionary)
    dictionary[SCStreamFrameInfo.status.rawValue] = status.rawValue
    return ImmutableSample(buffer: result)
}

private func feed(_ writer: MP4Writer, sample: ImmutableSample, host: Double) async {
    await withCheckedContinuation { continuation in
        writer.queue.async { writer.append(sample.buffer, hostTime: host); continuation.resume() }
    }
}

@Test func frozenFrameWritesRealMP4DurationAndH264WithoutAudio() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = try MP4Writer(url: dir.appendingPathComponent("temporary.mp4"), width: 64, height: 48, fps: 30)
    await feed(writer, sample: try sample(time: 100), host: 1000)
    let result = try await writer.finish(hostTime: 1003)
    #expect(result.image.width == 64 && result.image.height == 48)
    let asset = AVURLAsset(url: result.temporaryURL)
    let duration = try await asset.load(.duration)
    #expect(abs(duration.seconds - 3) < 0.05)
    let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let dimensions = try await video.load(.naturalSize)
    #expect(dimensions == CGSize(width: 64, height: 48))
    let formats = try await video.load(.formatDescriptions)
    #expect(CMFormatDescriptionGetMediaSubType(try #require(formats.first)) == kCMVideoCodecType_H264)
    #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
    #expect(try await asset.load(.isPlayable))
}

@Test func incompleteFramesAreIgnoredAndEmptyRecordingIsRemoved() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("temporary.mp4")
    let writer = try MP4Writer(url: url, width: 64, height: 48, fps: 30)
    for status in [SCFrameStatus.idle, .blank, .started, .suspended, .stopped] {
        await feed(writer, sample: try sample(time: 100, status: status), host: 1000)
    }
    #expect(await writer.firstFrame() == nil)
    do { _ = try await writer.finish(hostTime: 1003); Issue.record("空の録画が成功扱いになりました") }
    catch { #expect(!FileManager.default.fileExists(atPath: url.path)) }
}

@MainActor
@Test(arguments: ClipboardMode.allCases)
func videoClipboardAlwaysContainsOnlyFileURL(_ mode: ClipboardMode) {
    let artifact = SharedArtifact(url: URL(fileURLWithPath: "/tmp/movie.mp4"), kind: .mp4, width: 64, height: 48, byteCount: 100)
    let item = ClipboardWriter.item(for: artifact, data: Data([1, 2]), mode: mode)
    #expect(item.types == [.fileURL])
    #expect(item.string(forType: .fileURL) == artifact.url.absoluteString)
}

@Test func publishedVideosAvoidCollisionsAndLeaveNoTemporaryFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = dir.appendingPathComponent("one.recording.mp4"), second = dir.appendingPathComponent("two.recording.mp4")
    try Data([1]).write(to: first); try Data([2]).write(to: second)
    let date = Date(timeIntervalSince1970: 0)
    let a = try ArtifactStore.publishVideo(from: first, date: date)
    let b = try ArtifactStore.publishVideo(from: second, date: date)
    #expect(a != b && b.lastPathComponent.hasSuffix("-1.mp4"))
    #expect(try Data(contentsOf: a) == Data([1]))
    #expect(try Data(contentsOf: b) == Data([2]))
    #expect(!FileManager.default.fileExists(atPath: first.path) && !FileManager.default.fileExists(atPath: second.path))
}
