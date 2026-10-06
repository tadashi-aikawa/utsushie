@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import ScreenCaptureKit
import ImageIO
import Testing
import UtsushieCore
@testable import Utsushie

// サンプルは作成後に変更しない。SCStream同様、保持してwriterの専用キューへ渡す。
private struct ImmutableSample: @unchecked Sendable { let buffer: CMSampleBuffer }

private func sample(time: Double, status: SCFrameStatus = .complete, gray: UInt8 = 255, width: Int = 64, height: Int = 48) throws -> ImmutableSample {
    var pixels: CVPixelBuffer?
    let created = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
    #expect(created == kCVReturnSuccess)
    let image = try #require(pixels)
    CVPixelBufferLockBaseAddress(image, [])
    memset(CVPixelBufferGetBaseAddress(image), 255, CVPixelBufferGetDataSize(image))
    if gray != 255, let base = CVPixelBufferGetBaseAddress(image) {
        for y in 0..<height { for x in 0..<width {
            let offset = y * CVPixelBufferGetBytesPerRow(image) + x * 4
            for channel in 0..<3 { base.storeBytes(of: gray, toByteOffset: offset + channel, as: UInt8.self) }
        } }
    }
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

private func editableVideo(in directory: URL, width: Int = 64, height: Int = 48) async throws -> RecordedVideo {
    let writer = try MP4Writer(url: directory.appendingPathComponent("recording.mp4"), width: width, height: height, fps: 30)
    for (time, gray) in [(0.0, UInt8(30)), (0.3, 80), (1.4, 140), (2.7, 200)] {
        await feed(writer, sample: try sample(time: 100 + time, gray: gray, width: width, height: height), host: 1000 + time)
        try await Task.sleep(for: .milliseconds(100))
    }
    return try await writer.finish(hostTime: 1003.6)
}

@Test func fastForwardExportRetimesVFRAndBurnsBadgeOnlyIntoAcceleratedFrames() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await editableVideo(in: dir, width: 640, height: 360)
    var document = VideoEditDocument(duration: source.duration, kept: [.init(0, 0.6), .init(2.6, 3.6)])
    document.setTransition(for: .init(0.6, 2.6), kind: .fastForward, speed: 4)
    let target = dir.appendingPathComponent("fast-forward.mp4")
    _ = try await VideoEditExporter.export(source: source.temporaryURL, destination: target, document: document, fps: 30)
    #expect(abs(try await AVURLAsset(url: target).load(.duration).seconds - 2.1) < 0.001)
    let times = try await VideoEditMedia.frameTimes(url: target)
    #expect(times.map { Int(($0 * 60000).rounded()) } == [0, 18000, 36000, 48000, 66000, 72000, 124000])
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: target))
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    for (time, expected) in [(0.3, 80), (0.8, 140), (1.1, 140), (1.2, 200)] {
        let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60000))
        let pixels = try #require(frame.image.dataProvider?.data) as Data
        #expect(abs(Int(pixels[1]) - expected) < 8)
        if time == 0.8 {
            let badge = VideoFastForwardBadge.rect(width: 640, height: 360, speed: 4)
            let x = Int(badge.midX), y = 360 - Int(badge.minY + 3)
            let offset = y * frame.image.bytesPerRow + x * (frame.image.bitsPerPixel / 8)
            #expect(Int(pixels[offset + 1]) < 95)
        }
    }
}

@Test func fastForwardExportThinsDenseFramesToConfiguredFPS() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // 録画用Writerのリアルタイム間引きを避け、全コマを確実に用意する。
    let source = dir.appendingPathComponent("dense.mp4")
    let writer = try AVAssetWriter(outputURL: source, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: VideoEncoding.settings(width: 64, height: 48, fps: 30))
    input.expectsMediaDataInRealTime = false; writer.add(input)
    #expect(writer.startWriting()); writer.startSession(atSourceTime: .zero)
    for index in 0..<90 {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw try #require(writer.error) }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(input.append(try sample(time: Double(index) / 30).buffer))
    }
    writer.endSession(atSourceTime: CMTime(seconds: 3, preferredTimescale: 60000)); input.markAsFinished()
    await writer.finishWriting(); #expect(writer.status == .completed)
    #expect(try await VideoEditMedia.frameTimes(url: source).count == 90)
    var document = VideoEditDocument(duration: 3, kept: [.init(0, 0.5), .init(2.5, 3)])
    document.setTransition(for: .init(0.5, 2.5), kind: .fastForward, speed: 4)
    let target = dir.appendingPathComponent("thin.mp4")
    _ = try await VideoEditExporter.export(source: source, destination: target, document: document, fps: 10)
    let times = try await VideoEditMedia.frameTimes(url: target).filter { $0 >= 0.5 && $0 < 1 }
    #expect(times.count == 5)
    #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 >= 0.1 - 0.0001 })
}

@Test(arguments: [VideoTransitionKind.fade, .dissolve])
func transitionExportFreezesBoundaryFramesAndAddsHalfSecond(_ kind: VideoTransitionKind) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await editableVideo(in: dir)
    var document = VideoEditDocument(duration: source.duration, kept: [.init(0.15, 0.8), .init(2.9, 3.3)])
    document.setTransition(for: .init(0.8, 2.9), kind: kind)
    let target = dir.appendingPathComponent("fade.mp4")
    _ = try await VideoEditExporter.export(source: source.temporaryURL, destination: target, document: document, fps: 30)
    #expect(abs(try await AVURLAsset(url: target).load(.duration).seconds - 1.55) < 0.001)
    let times = try await VideoEditMedia.frameTimes(url: target)
    let transitionTimes: [Int] = (0..<16).map { 39000 + $0 * 1875 }
    let expectedTimes: [Int] = [0, 9000] + transitionTimes + [69000]
    #expect(times.map { Int(($0 * 60000).rounded()) } == expectedTimes)
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: target))
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    for (time, gray) in [(0.65, 80), (0.9, kind == .fade ? 0 : 140), (1.15, 200)] {
        let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60000))
        let pixelData = try #require(frame.image.dataProvider?.data) as Data
        #expect(abs(Int(pixelData[1]) - gray) <= 6)
    }
}

@Test func videoExportKeepsVFRAndClipsHeldFramesAtEveryJoin() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await editableVideo(in: dir)
    let sourceTimes = try await VideoEditMedia.frameTimes(url: source.temporaryURL)
    #expect(sourceTimes.map { Int(($0 * 60000).rounded()) } == [0, 18000, 84000, 162000, 214000])
    #expect(sourceTimes.contains { abs($0 - 0.3) < 0.0001 })
    #expect(sourceTimes.contains { abs($0 - 1.4) < 0.0001 })
    let document = VideoEditDocument(duration: source.duration, kept: [.init(0.15, 0.8), .init(1.2, 2.1), .init(2.9, 3.3)])
    let target = VideoEditStore.temporaryURL(for: source.temporaryURL)
    let result = try await VideoEditExporter.export(source: source.temporaryURL, destination: target, document: document, fps: 30)
    let asset = AVURLAsset(url: target)
    #expect(abs(try await asset.load(.duration).seconds - 1.95) < 0.001)
    let times = try await VideoEditMedia.frameTimes(url: target)
    #expect(times.map { Int(($0 * 60000).rounded()) } == [0, 9000, 39000, 51000, 93000])
    #expect(times.count == 5)
    for (actual, expected) in zip(times, [0, 0.15, 0.65, 0.85, 1.55]) { #expect(abs(actual - expected) < 0.0001) }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    for (time, gray) in [(0.0, 30), (0.15, 80), (0.65, 80), (0.85, 140), (1.55, 200)] {
        let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60000))
        let pixelData = try #require(frame.image.dataProvider?.data) as Data
        #expect(abs(Int(pixelData[1]) - gray) <= 5)
    }
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let formats = try await track.load(.formatDescriptions)
    #expect(CMFormatDescriptionGetMediaSubType(try #require(formats.first)) == kCMVideoCodecType_H264)
    #expect(try await track.load(.naturalSize) == CGSize(width: 64, height: 48))
    #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
    #expect(result.image.width == 64 && result.image.height == 48)
}

@MainActor @Test func videoEditSessionOverwritesSameNameAndAlwaysReeditsOriginal() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await editableVideo(in: dir)
    let bytes = try Data(contentsOf: source.temporaryURL)
    let artifact = SharedArtifact(url: source.temporaryURL, kind: .mp4, width: 64, height: 48, byteCount: bytes.count,
                                  duration: source.duration, videoFPS: 30)
    let session = VideoEditSession(artifact: artifact, fps: 60, rememberDirectory: { _ in })
    session.document = VideoEditDocument(duration: source.duration, kept: [.init(0.3, 1.4)])
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let (first, _) = try await session.save(artifact: artifact) { ClipboardWriter.copy($0, mode: .both, to: pasteboard) }
    let original = try #require(session.originalURL)
    #expect(first.url == artifact.url)
    #expect(abs((first.duration ?? 0) - 1.1) < 0.0001)
    let savedBytes = try Data(contentsOf: artifact.url)
    #expect(first.byteCount == savedBytes.count)
    #expect(try Data(contentsOf: original) == bytes)
    #expect(!session.needsExport)
    #expect(pasteboard.pasteboardItems?.first?.types == [.fileURL])
    session.document = VideoEditDocument(duration: source.duration, kept: [.init(2.0, 3.0)])
    let (second, _) = try await session.save(artifact: first) { ClipboardWriter.copy($0, mode: .file, to: pasteboard) }
    #expect(second.duration == 1)
    #expect(session.originalURL == original)
    #expect(try Data(contentsOf: original) == bytes)
    #expect(abs(try await AVURLAsset(url: artifact.url).load(.duration).seconds - 1) < 0.001)
    let previousBytes = try Data(contentsOf: artifact.url)
    session.document.setStart(2.4)
    do {
        _ = try await session.save(artifact: second) { _ in false }
        Issue.record("コピー失敗が成功扱いになりました")
    } catch {
        #expect(try Data(contentsOf: artifact.url) == previousBytes)
        #expect(try Data(contentsOf: original) == bytes)
        #expect(session.needsExport)
        #expect(session.document.kept == [.init(2.4, 3)])
    }
    _ = try await session.save(artifact: second) { _ in true }
    #expect(!session.needsExport)
    session.close()
    #expect(!FileManager.default.fileExists(atPath: original.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["recording.mp4"])
}

@MainActor @Test func transitionOnlyReeditReexportsOriginalAndRetainsChoicesAfterFailedCopy() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await editableVideo(in: dir)
    let originalBytes = try Data(contentsOf: source.temporaryURL)
    let artifact = SharedArtifact(url: source.temporaryURL, kind: .mp4, width: 64, height: 48, byteCount: originalBytes.count,
        duration: source.duration, videoFPS: 30)
    let session = VideoEditSession(artifact: artifact, fps: 60, rememberDirectory: { _ in })
    session.document = VideoEditDocument(duration: 3.6, kept: [.init(0, 0.6), .init(2.6, 3.6)])
    let range = session.document.interiorCuts[0]
    session.document.setTransition(for: range, kind: .fastForward, speed: 4)
    let (first, _) = try await session.save(artifact: artifact) { _ in true }
    #expect(first.duration == 2.1 && !session.needsExport)
    let savedBytes = try Data(contentsOf: first.url)
    session.document.setTransition(for: range, kind: .dissolve)
    #expect(session.needsExport)
    do {
        _ = try await session.save(artifact: first) { _ in false }
        Issue.record("コピー失敗が成功扱いになりました")
    } catch {
        #expect(try Data(contentsOf: first.url) == savedBytes)
        #expect(session.needsExport && session.document.transitions[0].kind == .dissolve)
        #expect(session.document.transitions[0].multiplier == 4)
    }
    let (second, _) = try await session.save(artifact: first) { _ in true }
    #expect(second.duration == 2.1 && !session.needsExport)
    #expect(try Data(contentsOf: session.sourceURL) == originalBytes)
    session.document.setTransition(for: range, kind: .fastForward)
    #expect(session.document.transitions[0].multiplier == 4)
    session.close()
}

@Test func mixedTransitionsExportInSourceOrderIncludingMultipleJoinsWithinOneHeldFrame() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await editableVideo(in: dir)
    var document = VideoEditDocument(duration: 3.6,
        kept: [.init(0, 0.2), .init(0.5, 0.6), .init(0.8, 1), .init(1.2, 3.6)])
    document.setTransition(for: .init(0.2, 0.5), kind: .fastForward, speed: 3)
    document.setTransition(for: .init(0.6, 0.8), kind: .fade)
    document.setTransition(for: .init(1, 1.2), kind: .dissolve)
    let target = dir.appendingPathComponent("mixed.mp4")
    let result = try await VideoEditExporter.export(source: source.temporaryURL, destination: target, document: document, fps: 30)
    #expect(abs(result.duration - 4) < 0.000001)
    #expect(abs(try await AVURLAsset(url: target).load(.duration).seconds - 4) < 0.0001)
    let times = try await VideoEditMedia.frameTimes(url: target)
    #expect(times.first == 0 && zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
    #expect(times.contains { abs($0 - 0.4) < 0.00001 })
    #expect(times.contains { abs($0 - 1.1) < 0.00001 })
    #expect(times.contains { abs($0 - 1.6) < 0.00001 })
}

@MainActor @Test(arguments: [VideoTransitionKind.fade, .dissolve])
func seekingDuringTransitionPreviewCancelsAnimationAndDoesNotResumePlayback(_ kind: VideoTransitionKind) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await editableVideo(in: dir)
    var document = VideoEditDocument(duration: 3.6, kept: [.init(0, 0.8), .init(2.9, 3.6)])
    document.setTransition(for: .init(0.8, 2.9), kind: kind)
    let editor = VideoEditorController(source: source.temporaryURL, document: document, screen: nil,
        focus: .init(activate: {}, restore: { _ in }))
    defer { editor.window.close() }
    for _ in 0..<100 where !editor.canCapture { try await Task.sleep(for: .milliseconds(20)) }
    #expect(editor.canCapture)
    let preview = try #require(editor.window.contentView?.subviews.first { view in
        view.layer?.sublayers?.contains { $0 is AVPlayerLayer } == true
    })
    editor.seek(to: 0.6, resume: true)
    var sawTransition = false
    for _ in 0..<150 {
        if preview.layer?.sublayers?.contains(where: { $0.contents != nil && !$0.isHidden }) == true {
            sawTransition = true; break
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(sawTransition)
    editor.seek(to: 1.4)
    try await Task.sleep(for: .milliseconds(700))
    #expect(!editor.timeline.playing && editor.player.rate == 0)
    #expect(editor.position == 1.4)
    #expect(preview.layer?.sublayers?.allSatisfy { $0 is AVPlayerLayer || $0.contents == nil || $0.isHidden } == true)
}

@Test func videoOriginalRenameFailureAndLaunchCleanupPreservePublicFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("movie.mp4")
    try Data([1, 2]).write(to: target)
    do {
        _ = try VideoEditStore.replace(temporary: dir.appendingPathComponent("missing.mp4"), target: target, original: nil)
        Issue.record("一時ファイルが無い置換が成功しました")
    } catch { #expect(try Data(contentsOf: target) == Data([1, 2])) }
    let temporary = VideoEditStore.temporaryURL(for: target)
    try Data([3]).write(to: temporary)
    let original = try VideoEditStore.replace(temporary: temporary, target: target, original: nil)
    let stranded = dir.appendingPathComponent("\(VideoEditStore.originalPrefix)\(UUID().uuidString)--recovered.mp4")
    try Data([4]).write(to: stranded)
    let unrelated = dir.appendingPathComponent(".other-app-original.mp4")
    try Data([5]).write(to: unrelated)
    try VideoEditStore.cleanup(directory: dir)
    #expect(!FileManager.default.fileExists(atPath: original.path))
    #expect(try Data(contentsOf: target) == Data([3]))
    #expect(try Data(contentsOf: dir.appendingPathComponent("recovered.mp4")) == Data([4]))
    #expect(try Data(contentsOf: unrelated) == Data([5]))
}

@MainActor @Test func videoStillsSaveNativeSizeWebPAndCopyAllItemsWithoutReencodingVideo() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await editableVideo(in: dir)
    let bytes = try Data(contentsOf: source.temporaryURL)
    let artifact = SharedArtifact(url: source.temporaryURL, kind: .mp4, width: 64, height: 48,
        byteCount: bytes.count, duration: source.duration, videoFPS: 30)
    let session = VideoEditSession(artifact: artifact, fps: 30, rememberDirectory: { _ in })
    _ = session.document.addStill(at: 0.3); _ = session.document.addStill(at: 2.7)
    var config = UtsushieConfig(); config.downscale = true; config.lossless = true
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let result = try await session.finish(artifact: artifact, config: config) {
        ClipboardWriter.copy($0, mode: config.clipboard, to: pasteboard)
    }
    #expect(result.image == nil && session.originalURL == nil && !session.needsExport)
    #expect(try Data(contentsOf: artifact.url) == bytes)
    #expect(result.stills.count == 2 && result.stills[0].artifact.url != result.stills[1].artifact.url)
    for (still, gray) in zip(result.stills, [80, 200]) {
        #expect(still.image.width == 64 && still.image.height == 48)
        #expect(still.artifact.width == 64 && still.artifact.height == 48)
        #expect(try Data(contentsOf: still.artifact.url) == still.data)
        #expect(String(data: still.data.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: still.data[8..<12], encoding: .ascii) == "WEBP")
        let encoded = try #require(CGImageSourceCreateWithData(still.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
        #expect(decoded.width == 64 && decoded.height == 48)
        let pixel = try #require(still.image.dataProvider?.data) as Data
        #expect(abs(Int(pixel[1]) - gray) <= 5)
    }
    for mode in ClipboardMode.allCases {
        #expect(ClipboardWriter.copy(result.stills.map(\.clipboardEntry), mode: mode, to: pasteboard))
        let items = try #require(pasteboard.pasteboardItems)
        #expect(items.count == 2)
        for (item, still) in zip(items, result.stills) {
            let expected: Set<NSPasteboard.PasteboardType> = mode == .file ? [.fileURL] : mode == .data ? [ArtifactKind.webP.pasteboardType] : [.fileURL, ArtifactKind.webP.pasteboardType]
            #expect(Set(item.types) == expected)
            if mode != .data { #expect(item.string(forType: .fileURL) == still.artifact.url.absoluteString) }
            if mode != .file { #expect(item.data(forType: ArtifactKind.webP.pasteboardType) == still.data) }
        }
    }
    #expect(!ClipboardWriter.copy([], mode: .both, to: pasteboard))
    #expect(pasteboard.pasteboardItems?.count == 2)
}

@MainActor @Test func cutAndStillsFinishUsesOriginalAndRollsBackFailedCopy() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await editableVideo(in: dir)
    let bytes = try Data(contentsOf: source.temporaryURL)
    let artifact = SharedArtifact(url: source.temporaryURL, kind: .mp4, width: 64, height: 48,
        byteCount: bytes.count, duration: source.duration, videoFPS: 30)
    let session = VideoEditSession(artifact: artifact, fps: 30, rememberDirectory: { _ in })
    defer { session.close() }
    session.document.setStart(1.4)
    _ = session.document.addStill(at: 0.3)
    do {
        _ = try await session.finish(artifact: artifact, config: UtsushieConfig()) { _ in false }
        Issue.record("コピー失敗が成功扱いになりました")
    } catch {
        #expect(try Data(contentsOf: artifact.url) == bytes)
        #expect(session.needsExport && session.document.stills.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".webp") }.isEmpty)
    }
    let original = try #require(session.originalURL)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let result = try await session.finish(artifact: artifact, config: UtsushieConfig()) {
        #expect($0.count == 1 && $0[0].artifact.kind == .webP)
        return ClipboardWriter.copy($0, mode: .both, to: pasteboard)
    }
    #expect(result.video.url == artifact.url && result.image != nil)
    #expect(abs((result.video.duration ?? 0) - 2.2) < 0.001)
    #expect(try Data(contentsOf: original) == bytes)
    let pixel = try #require(result.stills[0].image.dataProvider?.data) as Data
    #expect(abs(Int(pixel[1]) - 80) <= 5)
    #expect(pasteboard.pasteboardItems?.first?.string(forType: .fileURL) == result.stills[0].artifact.url.absoluteString)
    // Eで開き直した場合も、公開動画から除いた元のコマを取り出せる。
    _ = session.document.addStill(at: 0)
    let second = try await session.finish(artifact: result.video, config: UtsushieConfig()) { _ in true }
    #expect(second.image == nil && second.stills.count == 2 && session.originalURL == original)
    let firstPixel = try #require(second.stills[1].image.dataProvider?.data) as Data
    #expect(abs(Int(firstPixel[1]) - 30) <= 5)
}

@MainActor @Test func videoEditorCapturesDisplayedVFRFrameAndUndoRestoresTray() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await editableVideo(in: dir)
    let editor = VideoEditorController(source: source.temporaryURL, document: VideoEditDocument(duration: source.duration),
        screen: nil, focus: .init(activate: {}, restore: { _ in }))
    defer { editor.window.close() }
    for _ in 0..<200 where !editor.canCapture { try await Task.sleep(for: .milliseconds(10)) }
    #expect(editor.canCapture)
    editor.seek(to: 1.2)
    let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: editor.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 36))
    #expect(editor.handleKey(enter))
    #expect(editor.timeline.document.stills.map(\.time) == [0.3])
    #expect(editor.hintText == "完了で 静止画1枚をコピー")
    #expect(editor.handleKey(enter))
    #expect(editor.timeline.document.stills.count == 1)
    let root = try #require(editor.window.contentView)
    root.layoutSubtreeIfNeeded()
    let tray = try #require(root.subviews.compactMap { $0 as? VideoStillTray }.first)
    #expect(!tray.isHidden && tray.frame.width == 176)
    let mark = try #require(editor.timeline.document.stills.first)
    tray.onRemove?(mark.id)
    #expect(editor.timeline.document.stills.isEmpty)
    editor.undo(); #expect(editor.timeline.document.stills == [mark])
    editor.redo(); #expect(editor.timeline.document.stills.isEmpty)
    editor.undo()
    editor.goToEnd(); editor.captureFrame()
    #expect(editor.timeline.document.stills.map(\.time) == [0.3, 214000.0 / 60000])
}

@MainActor @Test func recentMP4ReadsDurationThumbnailAndRestoresAnEditableVideoCard() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await editableVideo(in: dir)
    let file = try #require(RecentCaptureStore.files(in: dir).first)
    let loaded = try await RecentCaptureStore.load(file, maximumPixelSize: 32)
    #expect(loaded.artifact.kind == .mp4 && loaded.artifact.width == 64 && loaded.artifact.height == 48)
    #expect(abs((loaded.artifact.duration ?? 0) - source.duration) < 0.001)
    #expect(loaded.image.width <= 32 && loaded.image.height <= 32)
    #expect(RecentCaptures.title(file: file, width: 64, height: 48, duration: loaded.artifact.duration).hasSuffix("MP4 0:03"))
    let controller = ThumbnailController(); controller.editorFocus = .init(activate: {}, restore: { _ in })
    controller.annotationConfig = { UtsushieConfig() }
    defer { for card in controller.cards { controller.remove(card.id) } }
    let id = try await controller.restore(file.url, seconds: 5, screen: nil)
    let card = try #require(controller.card(for: file.url))
    #expect(card.canEdit && card.id == id && card.timer?.isValid == true)
    #expect(abs(try #require(card.timer).fireDate.timeIntervalSinceNow - 5) < 0.5)
    card.edit()
    let editor = try #require(card.videoEditor)
    #expect(abs(editor.timeline.document.duration - source.duration) < 0.001)
    editor.window.close()
    #expect(abs(try #require(card.timer).fireDate.timeIntervalSinceNow - 5) < 0.5)
}

@MainActor @Test func libraryVideoCompletionKeepsOriginalSuppressesStillCardsAndRecoversFromFailedCopy() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await editableVideo(in: dir)
    let initial = try Data(contentsOf: source.temporaryURL)
    let controller = ThumbnailController()
    controller.editorFocus = .init(activate: {}, restore: { _ in })
    controller.annotationConfig = { UtsushieConfig() }
    controller.makeVideoSession = { VideoEditSession(artifact: $0, fps: $1, rememberDirectory: { _ in }) }
    defer { controller.closeLibrarySessions() }
    var statuses: [String?] = [], returned = 0
    controller.onLibraryExportStatus = { _, status in statuses.append(status) }
    try await controller.editFromLibrary(source.temporaryURL) { returned += 1 }
    let card = try #require(controller.card(for: source.temporaryURL))
    // 試験では専用pasteboardへコピーし、利用者のクリップボードを変えない。
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    card.copyEntries = { ClipboardWriter.copy($0, mode: $1, to: board, preservingOnFailure: true) }
    let editor = try #require(card.videoEditor)
    var document = VideoEditDocument(duration: source.duration, kept: [.init(0.3, 2.7)])
    _ = document.addStill(at: 1.4)
    let complete = try #require(editor.onComplete)
    editor.window.close() // 実装と同じく閉じた後に完了する。
    #expect(returned == 1)
    complete(document)
    #expect(card.finalizing && statuses.last! == "書き出し中…")
    for _ in 0..<300 where card.finalizing { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!card.finalizing && statuses.last! == nil)
    #expect(controller.cards.isEmpty && !card.panel.isVisible && card.timer == nil)
    #expect(board.pasteboardItems?.count == 1 && board.pasteboardItems?.first?.types.contains(ArtifactKind.webP.pasteboardType) == true)
    let afterFirst = try RecentCaptureStore.files(in: dir)
    #expect(afterFirst.filter { $0.kind == .webP }.count == 1)
    let originals = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix(VideoEditStore.originalPrefix) }
    let original = try #require(originals.first)
    #expect(try Data(contentsOf: original) == initial)
    let firstSaved = try Data(contentsOf: source.temporaryURL)
    try await controller.editFromLibrary(source.temporaryURL) { returned += 1 }
    let second = try #require(card.videoEditor)
    #expect(second.timeline.document == document)
    var changed = VideoEditDocument(duration: source.duration, kept: [.init(0, 3)])
    _ = changed.addStill(at: 1.4)
    card.copyEntries = { _, _ in false }
    let retry = try #require(second.onComplete); second.window.close(); retry(changed)
    for _ in 0..<300 where card.finalizing { try await Task.sleep(for: .milliseconds(10)) }
    #expect(statuses.last!!.hasPrefix("!") && !card.finalizing && controller.cards.isEmpty)
    #expect(try Data(contentsOf: source.temporaryURL) == firstSaved)
    #expect(try RecentCaptureStore.files(in: dir).filter { $0.kind == .webP }.count == 1)
    try await controller.editFromLibrary(source.temporaryURL) { returned += 1 }
    #expect(card.videoEditor?.timeline.document == changed)
    card.videoEditor?.window.close(); controller.closeLibrarySessions()
    #expect(returned == 3 && !FileManager.default.fileExists(atPath: original.path))
}
