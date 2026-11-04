@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import ScreenCaptureKit
import ImageIO
import Testing
import VideoToolbox
import UtsushieCore
@testable import Utsushie

// サンプルは作成後に変更しない。SCStream同様、保持してwriterの専用キューへ渡す。
private struct ImmutableSample: @unchecked Sendable { let buffer: CMSampleBuffer }

private func sample(time: Double, status: SCFrameStatus = .complete, gray: UInt8 = 255, width: Int = 64, height: Int = 48,
                    noise: Bool = false) throws -> ImmutableSample {
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
    // 画面の文字のように細かい模様。同じ時刻なら同じ画素になる。
    if noise, let base = CVPixelBufferGetBaseAddress(image) {
        var seed: UInt32 = 1
        for y in 0..<height { for x in 0..<width {
            seed = seed &* 1_103_515_245 &+ 12345
            let value = UInt8(truncatingIfNeeded: seed >> 16)
            let offset = y * CVPixelBufferGetBytesPerRow(image) + x * 4
            for channel in 0..<3 { base.storeBytes(of: value, toByteOffset: offset + channel, as: UInt8.self) }
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

@Test func compressionSettingsUseQualityOnlyWhenEncoderSupportsIt() throws {
    func properties(_ compression: VideoCompression) throws -> NSDictionary {
        let settings = VideoEncoding.settings(width: 320, height: 240, fps: 30, compression: compression)
        return try #require(settings[AVVideoCompressionPropertiesKey] as? [String: Any]) as NSDictionary
    }
    let compact = try properties(.compact), standard = try properties(.standard)
    #expect(standard[AVVideoAverageBitRateKey] as? Int == 500_000 && standard[AVVideoMaxKeyFrameIntervalKey] as? Int == 60)
    #expect(standard[kVTCompressionPropertyKey_Quality as String] == nil)
    guard VideoEncoding.supportsQuality else {
        // 画質を指定できないエンコーダーでは、小も大と同じ設定で書く。
        #expect(compact == standard)
        return
    }
    #expect(compact[kVTCompressionPropertyKey_Quality as String] as? Double == VideoEncoding.compactQuality)
    #expect(compact[AVVideoMaxKeyFrameIntervalKey] as? Int == 300 && compact[AVVideoMaxKeyFrameIntervalDurationKey] as? Int == 10)
    #expect(compact[AVVideoAverageBitRateKey] == nil)
}

@Test func compactCompressionWritesStaticScreenSmallerWithFewerKeyFrames() async throws {
    // 画質を指定できないエンコーダーでは小と大が同じ設定になり、比べる意味がない。
    guard VideoEncoding.supportsQuality else { return }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    var results: [VideoCompression: (bytes: Int, keyFrames: Int)] = [:]
    for compression in [VideoCompression.compact, .standard] {
        // 録画用Writerは追いつかないコマを落とすため、全コマを受け取るWriterで設定だけを比べる。
        let url = dir.appendingPathComponent("\(compression).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video,
                                       outputSettings: VideoEncoding.settings(width: 320, height: 240, fps: 30, compression: compression))
        input.expectsMediaDataInRealTime = false; writer.add(input)
        #expect(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        // 静止した画面を30fpsで4.5秒。大は60コマごとにキーフレームを置く。
        for index in 0..<135 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw try #require(writer.error) }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(input.append(try sample(time: Double(index) / 30, width: 320, height: 240, noise: true).buffer))
        }
        input.markAsFinished(); await writer.finishWriting()
        #expect(writer.status == .completed)
        let bytes = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try #require(try await asset.loadTracks(withMediaType: .video).first), outputSettings: nil)
        reader.add(output); reader.startReading()
        var keyFrames = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(buffer) > 0 else { continue }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
            if !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false) { keyFrames += 1 }
        }
        results[compression] = (bytes, keyFrames)
    }
    // 最大間隔はエンコーダーの追加のキーフレームを禁じないため、個数と容量は大との大小だけを見る。
    let compact = try #require(results[.compact]), standard = try #require(results[.standard])
    #expect(compact.keyFrames < standard.keyFrames)
    #expect(compact.bytes < standard.bytes)
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
    let a = try ArtifactStore.publishVideo(from: first, date: date).url
    let b = try ArtifactStore.publishVideo(from: second, date: date).url
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
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: VideoEncoding.settings(width: 64, height: 48, fps: 30, compression: .compact))
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

/// 左半分が暗く右半分が明るい、30fpsの録画。
private func splitVideo(in directory: URL, width: Int = 160, height: Int = 120, seconds: Int = 3) async throws -> URL {
    let url = directory.appendingPathComponent("split.mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: VideoEncoding.settings(width: width, height: height, fps: 30, compression: .standard))
    input.expectsMediaDataInRealTime = false; writer.add(input)
    #expect(writer.startWriting()); writer.startSession(atSourceTime: .zero)
    for index in 0..<(seconds * 30) {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw try #require(writer.error) }
            try await Task.sleep(for: .milliseconds(1))
        }
        let frame = try sample(time: Double(index) / 30, gray: 220, width: width, height: height).buffer
        let pixels = try #require(frame.imageBuffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pixels))
        for y in 0..<height { for x in 0..<(width / 2) {
            for channel in 0..<3 { base.storeBytes(of: UInt8(30), toByteOffset: y * CVPixelBufferGetBytesPerRow(pixels) + x * 4 + channel, as: UInt8.self) }
        } }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        #expect(input.append(frame))
    }
    writer.endSession(atSourceTime: CMTime(seconds: Double(seconds), preferredTimescale: 60000)); input.markAsFinished()
    await writer.finishWriting(); #expect(writer.status == .completed)
    return url
}

private func green(_ image: CGImage, x: Int, y: Int) throws -> Int {
    let data = try #require(image.dataProvider?.data) as Data
    return Int(data[y * image.bytesPerRow + x * (image.bitsPerPixel / 8) + 1])
}

@Test func zoomExportMagnifiesOnlyFramesInsideRangeAndEasesBothEnds() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await splitVideo(in: dir)
    // 右上の明るい1/4へ寄せる。
    let rect = CGRect(x: 80, y: 0, width: 80, height: 60)
    let document = VideoEditDocument(duration: 3, zooms: [VideoZoom(range: .init(1, 2), rect: rect)])
    let target = dir.appendingPathComponent("zoom.mp4")
    let result = try await VideoEditExporter.export(source: source, destination: target, document: document, fps: 30)
    #expect(result.width == 160 && result.height == 120)
    #expect(abs(try await AVURLAsset(url: target).load(.duration).seconds - 3) < 0.001)
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: target))
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    func frame(_ time: Double) async throws -> CGImage {
        try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60000)).image
    }
    // 区間外は元のまま。左は暗く右は明るい。
    for time in [0.5, 2.5] {
        let image = try await frame(time)
        #expect(try green(image, x: 20, y: 60) < 60)
        #expect(try green(image, x: 140, y: 60) > 190)
    }
    // 寄りきった間は全体が明るい。
    let held = try await frame(1.5)
    #expect(try green(held, x: 20, y: 60) > 190)
    #expect(try green(held, x: 60, y: 100) > 190)
    // 補間の途中は境目が左へ動く。x=60は全体では暗く、半分寄ると明るい。
    #expect(try green(try await frame(1.2), x: 60, y: 60) > 190)
    #expect(try green(try await frame(1.0), x: 60, y: 60) < 60)
    #expect(try green(try await frame(1.85), x: 60, y: 60) > 190)
}

@Test func zoomExportUsesPerRangeEaseSeconds() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await splitVideo(in: dir)
    // 1秒の区間に1秒の補間を指定すると、半分ずつの0.5秒で寄って戻る。
    let document = VideoEditDocument(duration: 3, zooms: [VideoZoom(range: .init(1, 2), rect: CGRect(x: 80, y: 0, width: 80, height: 60), ease: 1)])
    let target = dir.appendingPathComponent("ease.mp4")
    _ = try await VideoEditExporter.export(source: source, destination: target, document: document, fps: 30)
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: target))
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    func frame(_ time: Double) async throws -> CGImage {
        try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60000)).image
    }
    // 0.3秒の補間なら寄りきっている時刻でも、まだ寄り始め。境目は右に残る。
    #expect(try green(try await frame(1.1), x: 40, y: 60) < 60)
    #expect(try green(try await frame(1.5), x: 40, y: 60) > 190)
    #expect(try green(try await frame(1.9), x: 40, y: 60) < 60)
}

/// frameTimesはSetで重複を消すため、Readerが返すPTSの列をそのまま読む。
private func decodedPresentationTimes(_ url: URL) async throws -> [Int64] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    #expect(reader.startReading())
    var times: [Int64] = []
    while let sample = output.copyNextSampleBuffer() {
        times.append(CMTimeConvertScale(sample.presentationTimeStamp, timescale: 60000, method: .roundHalfAwayFromZero).value)
    }
    #expect(reader.status == .completed)
    return times
}

@Test func zoomExportKeepsStrictlyIncreasingPTSWhenRampEndsJustAfterFrame() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await splitVideo(in: dir)
    // 補間の終わりが1.000001秒で、1.0秒のコマの頭を60000分の1秒未満だけ切る。
    let document = VideoEditDocument(duration: 3, zooms: [VideoZoom(range: .init(0.700001, 2), rect: CGRect(x: 80, y: 0, width: 80, height: 60))])
    let target = dir.appendingPathComponent("tick.mp4")
    _ = try await VideoEditExporter.export(source: source, destination: target, document: document, fps: 30)
    let times = try await decodedPresentationTimes(target)
    #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
    #expect(times.filter { $0 == 60000 }.count == 1)
    #expect(abs(try await AVURLAsset(url: target).load(.duration).seconds - 3) < 0.001)
}

@Test(arguments: [0.0, 2.0])
func zoomExportKeepsStrictlyIncreasingPTSAtEaseLimits(_ ease: Double) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await splitVideo(in: dir)
    // 区間の両端をコマの時刻からわずかにずらし、補間の境目が時間単位未満でコマを切るようにする。
    let document = VideoEditDocument(duration: 3, zooms: [
        VideoZoom(range: .init(0.700001, 1.300001), rect: CGRect(x: 80, y: 0, width: 80, height: 60), ease: ease),
        VideoZoom(range: .init(1.5, 2.900001), rect: CGRect(x: 0, y: 0, width: 80, height: 60), ease: ease)])
    #expect(document.zooms.map(\.ease) == [ease, ease])
    let target = dir.appendingPathComponent("ease-limit.mp4")
    _ = try await VideoEditExporter.export(source: source, destination: target, document: document, fps: 30)
    let times = try await decodedPresentationTimes(target)
    #expect(!times.isEmpty && times.first == 0)
    #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
    #expect(abs(try await AVURLAsset(url: target).load(.duration).seconds - 3) < 0.001)
}

@Test func zoomExportRedrawsHeldVFRFrameDuringRamp() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await editableVideo(in: dir)
    // 0.3秒のコマは1.4秒まで保持される。その間に寄って戻る。
    let document = VideoEditDocument(duration: source.duration,
        zooms: [VideoZoom(range: .init(0.4, 1.3), rect: CGRect(x: 0, y: 0, width: 32, height: 24))])
    let target = dir.appendingPathComponent("held.mp4")
    _ = try await VideoEditExporter.export(source: source.temporaryURL, destination: target, document: document, fps: 30)
    let times = try await VideoEditMedia.frameTimes(url: target)
    // 寄る0.3秒と戻る0.3秒は1/30秒ごとに描き直し、寄りきった間と区間外は保持したまま。
    #expect(times.filter { $0 > 0.4 + 1e-6 && $0 < 0.7 - 1e-6 }.count == 8)
    #expect(times.filter { $0 > 1.0 + 1e-6 && $0 < 1.3 - 1e-6 }.count == 8)
    #expect(times.filter { $0 >= 0.7 - 1e-6 && $0 <= 1.0 + 1e-6 }.count == 1)
    #expect(times.filter { $0 > 1.3 + 1e-6 && $0 < 1.4 - 1e-6 }.isEmpty)
    #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
    #expect(abs(try await AVURLAsset(url: target).load(.duration).seconds - source.duration) < 0.001)
}

@Test func zoomAppliesAfterFastForwardThinningAndKeepsBadgeUnscaled() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await splitVideo(in: dir, width: 640, height: 360)
    var document = VideoEditDocument(duration: 3, kept: [.init(0, 0.5), .init(2.5, 3)],
        zooms: [VideoZoom(range: .init(0.6, 2.4), rect: CGRect(x: 320, y: 0, width: 320, height: 180))])
    document.setTransition(for: .init(0.5, 2.5), kind: .fastForward, speed: 4)
    let target = dir.appendingPathComponent("fast-zoom.mp4")
    _ = try await VideoEditExporter.export(source: source, destination: target, document: document, fps: 30)
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: target))
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    // 早送りの中ほど(元録画1.5秒)は寄っていて、左も明るい。印は元の大きさのまま右上にある。
    let image = try await generator.image(at: CMTime(seconds: 0.75, preferredTimescale: 60000)).image
    #expect(try green(image, x: 80, y: 300) > 190)
    let badge = VideoFastForwardBadge.rect(width: 640, height: 360, speed: 4)
    #expect(try green(image, x: Int(badge.midX), y: 360 - Int(badge.minY + 3)) < 95)
    // 残す範囲は寄らない。
    let plain = try await generator.image(at: CMTime(seconds: 0.25, preferredTimescale: 60000)).image
    #expect(try green(plain, x: 80, y: 300) < 60)
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

@MainActor @Test func zoomOnlyEditReexportsAndStillMarksDoNot() async throws {
    let artifact = SharedArtifact(url: URL(fileURLWithPath: "/tmp/utsushie-test-missing.mp4"), kind: .mp4, width: 64, height: 48,
        byteCount: 0, duration: 3.6, videoFPS: 30)
    let session = VideoEditSession(artifact: artifact, fps: 30, rememberDirectory: { _ in })
    session.document.addStill(at: 1)
    #expect(!session.needsExport)
    let added = session.document.addZoom(drag: CGRect(x: 0, y: 0, width: 32, height: 24), size: CGSize(width: 64, height: 48), at: 1)
    #expect(added != nil && session.needsExport)
    session.document.removeZoom(try #require(added))
    #expect(!session.needsExport)
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

@Test func videoOriginalKeepsLongPublicNameOutOfBackupNameAndRecoversIt() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // 設定で通る最長に近い名前。旧方式の退避名では255バイトを超えた。
    let target = dir.appendingPathComponent(String(repeating: "a", count: 240) + ".mp4")
    try Data([1, 2]).write(to: target)
    let temporary = VideoEditStore.temporaryURL(for: target)
    try Data([3]).write(to: temporary)
    let original = try VideoEditStore.replace(temporary: temporary, target: target, original: nil)
    #expect(original.lastPathComponent.utf8.count < 100 && !original.lastPathComponent.contains("aaaa"))
    #expect(VideoEditStore.originalName(of: original) == target.lastPathComponent)
    #expect(VideoEditStore.originalName(of: target) == nil)
    // 改名直後に終了して公開先が無い場合は、拡張属性の名前へ戻して属性を外す。
    try FileManager.default.removeItem(at: target)
    let unnamed = dir.appendingPathComponent("\(VideoEditStore.originalPrefix)\(UUID().uuidString).mp4")
    try Data([9]).write(to: unnamed)
    try VideoEditStore.cleanup(directory: dir)
    #expect(try Data(contentsOf: target) == Data([1, 2]))
    #expect(VideoEditStore.originalName(of: target) == nil && !FileManager.default.fileExists(atPath: original.path))
    // 公開名が分からない元は消さない。
    #expect(try Data(contentsOf: unnamed) == Data([9]))
}

@MainActor @Test func videoEditFinishesWithLongCustomFileName() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await editableVideo(in: dir)
    var config = UtsushieConfig(); config.fileName = String(repeating: "a", count: 200); config.clipboard = .none
    let published = try ArtifactStore.publishVideo(from: source.temporaryURL, date: Date(), pattern: config.fileName)
    #expect(!published.usedDefaultName && published.url.lastPathComponent == config.fileName + ".mp4")
    let bytes = try Data(contentsOf: published.url)
    let artifact = SharedArtifact(url: published.url, kind: .mp4, width: 64, height: 48,
        byteCount: bytes.count, duration: source.duration, videoFPS: 30)
    let session = VideoEditSession(artifact: artifact, fps: 30, rememberDirectory: { _ in })
    defer { session.close() }
    session.document.setStart(1.4)
    _ = session.document.addStill(at: 0.3)
    let result = try await session.finish(artifact: artifact, config: config) { _ in true }
    #expect(result.video.url == published.url && abs((result.video.duration ?? 0) - 2.2) < 0.001)
    #expect(try Data(contentsOf: try #require(session.originalURL)) == bytes)
    #expect(result.stills.count == 1 && result.stills[0].artifact.url.lastPathComponent == config.fileName + ".webp")
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
            let format = mode.format
            let expected: Set<NSPasteboard.PasteboardType> = format == .file ? [.fileURL] : format == .data ? [ArtifactKind.webP.pasteboardType] : [.fileURL, ArtifactKind.webP.pasteboardType]
            #expect(Set(item.types) == expected)
            if format != .data { #expect(item.string(forType: .fileURL) == still.artifact.url.absoluteString) }
            if format != .file { #expect(item.data(forType: ArtifactKind.webP.pasteboardType) == still.data) }
        }
    }
    #expect(!ClipboardWriter.copy([], mode: .both, to: pasteboard))
    #expect(pasteboard.pasteboardItems?.count == 2)
}

@MainActor @Test func videoFinishWithClipboardNoneSavesWithoutCopy() async throws {
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
    var config = UtsushieConfig(); config.clipboard = .none
    var copied = false
    let result = try await session.finish(artifact: artifact, config: config) { _ in copied = true; return false }
    #expect(!copied && result.image != nil && result.stills.count == 1)
    #expect(abs((result.video.duration ?? 0) - 2.2) < 0.001)
    #expect(FileManager.default.fileExists(atPath: result.stills[0].artifact.url.path))
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

@MainActor @Test func videoEditorHintSaysSaveWhenClipboardIsNone() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await editableVideo(in: dir)
    let editor = VideoEditorController(source: source.temporaryURL, document: VideoEditDocument(duration: source.duration),
        screen: nil, focus: .init(activate: {}, restore: { _ in }), copiesStills: false)
    defer { editor.window.close() }
    for _ in 0..<200 where !editor.canCapture { try await Task.sleep(for: .milliseconds(10)) }
    editor.seek(to: 1.2)
    let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: editor.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 36))
    #expect(editor.handleKey(enter))
    #expect(editor.hintText == "完了で 静止画1枚を保存")
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

@MainActor @Test(arguments: [false, true])
func dissolvePreviewInterpolatesZoomLikeExportPlan(zoomTool: Bool) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await splitVideo(in: dir)
    let rect = CGRect(x: 80, y: 0, width: 80, height: 60)
    var document = VideoEditDocument(duration: 3, kept: [.init(0, 1.5), .init(2.2, 3)], zooms: [VideoZoom(range: .init(0.5, 1.8), rect: rect)])
    document.setTransition(for: .init(1.5, 2.2), kind: .dissolve)
    let plan = VideoExportPlan(document: document)
    let junction = try #require(plan.junctions.first)
    let size = CGSize(width: 160, height: 120)
    let editor = VideoEditorController(source: source, document: document, screen: nil, focus: .init(activate: {}, restore: { _ in }))
    defer { editor.window.close() }
    for _ in 0..<300 where editor.videoSize == nil || !editor.canCapture { try await Task.sleep(for: .milliseconds(10)) }
    try #require(editor.videoSize == size)
    editor.window.contentView?.layoutSubtreeIfNeeded()
    if zoomTool { editor.toggleZoomTool(); #expect(editor.zoomTool) }
    editor.seek(to: 1.3, resume: true)
    // 演出の前半・後半とも、プレビューの矩形が書き出しの計画と一致する。位置が末尾へ飛んでも倍率を戻さない。
    var checked: Set<Bool> = []
    let deadline = ContinuousClock.now + .seconds(4)
    while checked.count < 2, ContinuousClock.now < deadline {
        if let progress = editor.transitionPreviewProgress, progress > 0.1, progress < 0.9 {
            // ツール中でも再生中は寄るので、演出の間も書き出しと同じ補間にし、枠は出さない。
            let crop = try #require(editor.previewZoomCrop)
            let expected = try #require(plan.transitionCrop(junction, progress: progress, size: size))
            #expect(abs(crop.minX - expected.minX) < 0.001 && abs(crop.width - expected.width) < 0.001)
            #expect(crop != rect && editor.previewOutline == nil)
            checked.insert(progress >= 0.5)
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(checked == [false, true])
    editor.seek(to: 2.5)
    #expect(editor.transitionPreviewProgress == nil && editor.previewZoomCrop == nil)
}

@MainActor @Test(arguments: [false, true])
func zoomPlacedAwayFromPlayheadSeeksIntoRangeAndKeepsOutline(fromCut: Bool) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await splitVideo(in: dir)
    let document = VideoEditDocument(duration: 3, kept: fromCut ? [.init(0, 1), .init(2, 3)] : nil)
    let editor = VideoEditorController(source: source, document: document, screen: nil, focus: .init(activate: {}, restore: { _ in }))
    defer { editor.window.close() }
    for _ in 0..<300 where editor.videoSize == nil { try await Task.sleep(for: .milliseconds(10)) }
    try #require(editor.videoSize == CGSize(width: 160, height: 120))
    let root = try #require(editor.window.contentView)
    root.layoutSubtreeIfNeeded()
    let preview = try #require(root.subviews.first { $0.layer?.sublayers?.contains { $0 is AVPlayerLayer } == true })
    let stage = AVMakeRect(aspectRatio: CGSize(width: 160, height: 120), insideRect: preview.bounds.insetBy(dx: 16, dy: 4))
    func mouse(_ type: NSEvent.EventType, _ fx: Double, _ fy: Double) throws -> NSEvent {
        let point = preview.convert(CGPoint(x: stage.minX + stage.width * fx, y: stage.maxY - stage.height * fy), to: nil)
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: editor.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    // 録画末尾(End)か、切った範囲の中から置く。
    if fromCut { editor.seek(to: 1.5) } else { editor.goToEnd() }
    editor.toggleZoomTool()
    preview.mouseDown(with: try mouse(.leftMouseDown, 0.5, 0.01))
    preview.mouseDragged(with: try mouse(.leftMouseDragged, 1, 0.3))
    preview.mouseUp(with: try mouse(.leftMouseUp, 1, 0.3))
    let zoom = try #require(editor.timeline.document.zooms.first)
    #expect(zoom.range == (fromCut ? .init(0, 1) : .init(1, 3)))
    // 区間の頭へ移り、ツールのまま枠とリサイズの対象を保つ。
    #expect(editor.position == zoom.range.start && editor.zoomTool && editor.timeline.selectedZoom == zoom.id)
    #expect(editor.previewOutline == zoom.rect)
    preview.mouseMoved(with: try mouse(.mouseMoved, 0.5, 0.15))
    #expect(editor.previewCursor == .resize([.minX]))
}

@MainActor @Test func optionDragMovesZoomRectInsideAndOutsideToolAndStopsAtEdges() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await splitVideo(in: dir)
    let rect = CGRect(x: 80, y: 0, width: 80, height: 60)
    let zoom = VideoZoom(range: .init(0.5, 2.5), rect: rect)
    let editor = VideoEditorController(source: source, document: VideoEditDocument(duration: 3, zooms: [zoom]), screen: nil,
        focus: .init(activate: {}, restore: { _ in }))
    defer { editor.window.close() }
    for _ in 0..<300 where editor.videoSize == nil { try await Task.sleep(for: .milliseconds(10)) }
    try #require(editor.videoSize == CGSize(width: 160, height: 120))
    let root = try #require(editor.window.contentView)
    root.layoutSubtreeIfNeeded()
    let preview = try #require(root.subviews.first { $0.layer?.sublayers?.contains { $0 is AVPlayerLayer } == true })
    let stage = AVMakeRect(aspectRatio: CGSize(width: 160, height: 120), insideRect: preview.bounds.insetBy(dx: 16, dy: 4))
    func mouse(_ type: NSEvent.EventType, _ fx: Double, _ fy: Double, option: Bool = false) throws -> NSEvent {
        let point = preview.convert(CGPoint(x: stage.minX + stage.width * fx, y: stage.maxY - stage.height * fy), to: nil)
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: option ? .option : [], timestamp: 0,
            windowNumber: editor.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    // ツール外: レーンで選んだ区間の矩形を薄い枠で示す。寄った表示なので、枠は映像全体に重なる。
    editor.timeline.selectedZoom = zoom.id
    editor.seek(to: 1.5)
    #expect(editor.previewZoomCrop == rect && editor.previewOutline == rect)
    preview.mouseMoved(with: try mouse(.mouseMoved, 0.5, 0.5, option: true)); #expect(editor.previewCursor == .openHand)
    preview.mouseMoved(with: try mouse(.mouseMoved, 0.5, 0.5)); #expect(editor.previewCursor == .arrow)
    // ⌥なしはツール外では何もしない。
    preview.mouseDown(with: try mouse(.leftMouseDown, 0.5, 0.5))
    preview.mouseDragged(with: try mouse(.leftMouseDragged, 0.2, 0.5))
    preview.mouseUp(with: try mouse(.leftMouseUp, 0.2, 0.5))
    #expect(editor.timeline.document.zooms[0].rect == rect)
    // ⌥はmouseDownで決め、途中で離しても移動を続ける。寄った表示の4分の1は元録画の20px。
    preview.mouseDown(with: try mouse(.leftMouseDown, 0.5, 0.5, option: true))
    #expect(editor.previewCursor == .closedHand)
    preview.mouseDragged(with: try mouse(.leftMouseDragged, 0.25, 0.5))
    #expect(editor.previewOutline == CGRect(x: 60, y: 0, width: 80, height: 60) && editor.previewCursor == .closedHand)
    #expect(editor.previewZoomCrop == rect)
    preview.mouseUp(with: try mouse(.leftMouseUp, 0.25, 0.5))
    #expect(editor.timeline.document.zooms[0].rect == CGRect(x: 60, y: 0, width: 80, height: 60))
    #expect(editor.timeline.document.zooms[0].range == zoom.range && editor.timeline.selectedZoom == zoom.id)
    #expect(editor.previewZoomCrop == CGRect(x: 60, y: 0, width: 80, height: 60))
    editor.undo(); #expect(editor.timeline.document.zooms[0].rect == rect)
    // プレビューの外まで引いても頭打ちにせず、元録画の左端まで届く。
    preview.mouseDown(with: try mouse(.leftMouseDown, 0.5, 0.5, option: true))
    preview.mouseDragged(with: try mouse(.leftMouseDragged, -2, 0.5, option: true))
    #expect(editor.previewOutline == CGRect(x: 0, y: 0, width: 80, height: 60))
    preview.mouseUp(with: try mouse(.leftMouseUp, -2, 0.5, option: true))
    #expect(editor.timeline.document.zooms[0].rect == CGRect(x: 0, y: 0, width: 80, height: 60))
    editor.undo(); #expect(editor.timeline.document.zooms[0].rect == rect)
    // ⌥ドラッグの途中でEscを押すと、選択と一緒にドラッグを取り消し、未確定の枠と握った手を残さない。
    preview.mouseDown(with: try mouse(.leftMouseDown, 0.5, 0.5, option: true))
    preview.mouseDragged(with: try mouse(.leftMouseDragged, 0.3, 0.5))
    #expect(editor.previewOutline == CGRect(x: 64, y: 0, width: 80, height: 60))
    #expect(editor.handleKey(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: editor.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))))
    #expect(editor.timeline.selectedZoom == nil && editor.previewOutline == nil && editor.previewCursor != .closedHand)
    preview.mouseUp(with: try mouse(.leftMouseUp, 0.3, 0.5))
    #expect(editor.timeline.document.zooms[0].rect == rect && editor.previewOutline == nil)
    editor.timeline.selectedZoom = zoom.id; editor.seek(to: 1.5)
    // ツール中: 再生位置の区間を⌥ドラッグで動かし、元録画の端で止める。ツールは抜けない。
    #expect(editor.handleKey(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: editor.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 6))))
    #expect(editor.zoomTool && editor.previewZoomCrop == nil && editor.previewOutline == rect)
    preview.mouseMoved(with: try mouse(.mouseMoved, 0.25, 0.2, option: true)); #expect(editor.previewCursor == .crosshair)
    preview.mouseMoved(with: try mouse(.mouseMoved, 0.6, 0.2, option: true)); #expect(editor.previewCursor == .openHand)
    preview.mouseDown(with: try mouse(.leftMouseDown, 0.6, 0.2, option: true))
    preview.mouseDragged(with: try mouse(.leftMouseDragged, 0, 0.9, option: true))
    preview.mouseUp(with: try mouse(.leftMouseUp, 0, 0.9, option: true))
    #expect(editor.timeline.document.zooms[0].rect == CGRect(x: 0, y: 60, width: 80, height: 60))
    #expect(editor.zoomTool && editor.timeline.document.zooms.count == 1)
    editor.undo(); #expect(editor.timeline.document.zooms[0].rect == rect)
}

@MainActor @Test func zoomToolPlacesRangeFromPreviewDragAndPreviewShowsZoomedPlayer() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await splitVideo(in: dir)
    let editor = VideoEditorController(source: source, document: VideoEditDocument(duration: 3), screen: nil,
        focus: .init(activate: {}, restore: { _ in }))
    defer { editor.window.close() }
    for _ in 0..<300 where editor.videoSize == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(editor.videoSize == CGSize(width: 160, height: 120))
    let root = try #require(editor.window.contentView)
    root.layoutSubtreeIfNeeded()
    let preview = try #require(root.subviews.first { $0.layer?.sublayers?.contains { $0 is AVPlayerLayer } == true })
    let player = try #require(preview.layer?.sublayers?.first { $0 is AVPlayerLayer })
    func key(_ code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: editor.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }
    // 映像の範囲の割合で、プレビューのウィンドウ座標を作る。yは上からの割合。
    let stage = AVMakeRect(aspectRatio: CGSize(width: 160, height: 120), insideRect: preview.bounds.insetBy(dx: 16, dy: 4))
    func mouse(_ type: NSEvent.EventType, _ fx: Double, _ fy: Double) throws -> NSEvent {
        let point = preview.convert(CGPoint(x: stage.minX + stage.width * fx, y: stage.maxY - stage.height * fy), to: nil)
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: editor.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    editor.seek(to: 1.5)
    #expect(editor.handleKey(try key(6)))
    #expect(editor.zoomTool && editor.toolbar.zoomButton.state == .on && editor.hintText.contains("ドラッグ"))
    // 4pt以内はクリックとして扱い、置かない。
    preview.mouseDown(with: try mouse(.leftMouseDown, 0.6, 0.1))
    preview.mouseUp(with: try mouse(.leftMouseUp, 0.6, 0.1))
    #expect(editor.timeline.document.zooms.isEmpty && editor.zoomTool)
    // ドラッグ中の枠は最小の1/8(20px)へ跳ねず、カーソルに沿った大きさのまま。⌘Zでドラッグだけを取り消す。
    preview.mouseDown(with: try mouse(.leftMouseDown, 0.5, 0.5))
    preview.mouseDragged(with: try mouse(.leftMouseDragged, 0.6, 0.55))
    let small = try #require(editor.previewOutline)
    #expect(abs(small.width - 16) < 0.5 && abs(small.height - 12) < 0.5 && abs(small.minX - 80) < 0.5)
    editor.undo()
    #expect(editor.previewOutline == nil && editor.timeline.document.zooms.isEmpty)
    preview.mouseUp(with: try mouse(.leftMouseUp, 0.6, 0.55))
    #expect(editor.timeline.document.zooms.isEmpty)
    preview.mouseDown(with: try mouse(.leftMouseDown, 0.5, 0.01))
    preview.mouseDragged(with: try mouse(.leftMouseDragged, 1, 0.3))
    preview.mouseUp(with: try mouse(.leftMouseUp, 1, 0.3))
    let zoom = try #require(editor.timeline.document.zooms.first)
    #expect(zoom.range == .init(0.5, 2.5))
    // 横長のドラッグを出力と同じ4:3へ広げる。
    #expect(abs(zoom.rect.width - 80) < 0.5 && abs(zoom.rect.height - 60) < 0.5 && abs(zoom.rect.minX - 80) < 0.5)
    // 確定してもツールに留まり、区間を選んで全体表示に枠を出し続ける。
    #expect(editor.zoomTool && editor.timeline.selectedZoom == zoom.id)
    #expect(editor.previewOutline == zoom.rect && CATransform3DIsIdentity(player.transform))
    // ツール中でも、Z・Escを押さずに再生すると寄る。停止したら全体表示と枠へ戻る。
    editor.seek(to: 1.5, resume: true)
    try await Task.sleep(for: .milliseconds(50))
    #expect(editor.zoomTool && abs(player.transform.m11 - 2) < 0.01 && editor.previewOutline == nil)
    editor.seek(to: 1.5)
    #expect(editor.zoomTool && CATransform3DIsIdentity(player.transform) && editor.previewOutline == zoom.rect)
    // ツールを抜けると寄った見え方をプレビューに出す。
    #expect(editor.handleKey(try key(6)) && !editor.zoomTool)
    #expect(abs(player.transform.m11 - 2) < 0.01)
    editor.seek(to: 0.2)
    #expect(CATransform3DIsIdentity(player.transform))
    // 区間の中で左上へ描き直すと、押した点を右下の角に固定した矩形になる。
    editor.seek(to: 1.5)
    #expect(editor.handleKey(try key(6)) && editor.zoomTool)
    preview.mouseDown(with: try mouse(.leftMouseDown, 0.75, 0.75))
    preview.mouseDragged(with: try mouse(.leftMouseDragged, 0.5, 0.5))
    preview.mouseUp(with: try mouse(.leftMouseUp, 0.5, 0.5))
    let redrawn = try #require(editor.timeline.document.zooms.first)
    #expect(editor.timeline.document.zooms.count == 1 && redrawn.id == zoom.id && redrawn.range == zoom.range)
    #expect(abs(redrawn.rect.maxX - 120) < 0.5 && abs(redrawn.rect.maxY - 90) < 0.5)
    #expect(abs(redrawn.rect.width - 40) < 0.5 && abs(redrawn.rect.height - 30) < 0.5)
    editor.undo(); #expect(editor.timeline.document.zooms.first?.rect == zoom.rect)
    editor.undo(); #expect(editor.timeline.document.zooms.isEmpty)
    editor.redo(); #expect(editor.timeline.document.zooms.count == 1)
    // 左の辺の縁は⌥を押していてもリサイズ。右の辺を固定し、縦は中心を保って元録画の中へ押し戻す。
    #expect(editor.zoomTool)
    func optionMouse(_ type: NSEvent.EventType, _ fx: Double, _ fy: Double) throws -> NSEvent {
        let point = preview.convert(CGPoint(x: stage.minX + stage.width * fx, y: stage.maxY - stage.height * fy), to: nil)
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: .option, timestamp: 0,
            windowNumber: editor.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    preview.mouseMoved(with: try mouse(.mouseMoved, 0.5, 0.3)); #expect(editor.previewCursor == .resize([.minX]))
    preview.mouseMoved(with: try optionMouse(.mouseMoved, 0.5, 0.3)); #expect(editor.previewCursor == .resize([.minX]))
    preview.mouseMoved(with: try mouse(.mouseMoved, 0.75, 0.3)); #expect(editor.previewCursor == .crosshair)
    preview.mouseDown(with: try optionMouse(.leftMouseDown, 0.5, 0.3))
    preview.mouseDragged(with: try mouse(.leftMouseDragged, 0.25, 0.3))
    let resizing = try #require(editor.previewOutline)
    #expect(abs(resizing.minX - 40) < 0.5 && abs(resizing.maxX - 160) < 0.5 && abs(resizing.width / resizing.height - 4 / 3) < 0.001)
    #expect(editor.previewCursor == .resize([.minX]))
    preview.mouseUp(with: try mouse(.leftMouseUp, 0.25, 0.3))
    let resized = try #require(editor.timeline.document.zooms.first)
    #expect(abs(resized.rect.minX - 40) < 0.5 && abs(resized.rect.width - 120) < 0.5 && abs(resized.rect.height - 90) < 0.5)
    #expect(resized.rect.minY >= 0 && resized.range == zoom.range && editor.zoomTool)
    editor.undo(); #expect(editor.timeline.document.zooms.first?.rect == zoom.rect)
    // ツールを抜けるのはZ・Escなどの明示した操作だけ。
    #expect(editor.handleKey(try key(6)) && !editor.zoomTool)
    // 時間軸のレーンをクリックして選び、⌫で消す。
    let timeline = editor.timeline, width = timeline.bounds.width - 48
    let lane = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: timeline.convert(CGPoint(x: 24 + width * 1.5 / 3, y: 70 + 46), to: nil),
        modifierFlags: [], timestamp: 0, windowNumber: editor.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    timeline.mouseDown(with: lane)
    #expect(timeline.selectedZoom == zoom.id && abs(editor.position - 1.5) < 0.01)
    #expect(editor.handleKey(try key(51)))
    #expect(editor.timeline.document.zooms.isEmpty && editor.timeline.document.kept == [.init(0, 3)])
    #expect(editor.handleKey(try key(6)) && editor.zoomTool)
    #expect(editor.handleKey(try key(53)) && !editor.zoomTool)
    #expect(!editor.handleKey(try key(53)))
}

@MainActor @Test func zoomDragStaysOnGrabbedRangeAndSeekOrUndoCancelsIt() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await splitVideo(in: dir)
    let size = CGSize(width: 160, height: 120)
    var document = VideoEditDocument(duration: 3)
    let placedFirst = document.addZoom(drag: CGRect(x: 40, y: 30, width: 80, height: 60), size: size, at: 0.5)
    // 2つ目も左の辺を広げられる位置に置き、取り違えたら矩形が変わるようにする。
    let placedSecond = document.addZoom(drag: CGRect(x: 60, y: 40, width: 80, height: 60), size: size, at: 2.5)
    let first = try #require(placedFirst), second = try #require(placedSecond)
    #expect(document.zooms.map(\.range) == [.init(0, 2), .init(2, 3)])
    let original = document.zooms
    let editor = VideoEditorController(source: source, document: document, screen: nil, focus: .init(activate: {}, restore: { _ in }))
    defer { editor.window.close() }
    for _ in 0..<300 where editor.videoSize == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(editor.videoSize == size)
    let root = try #require(editor.window.contentView)
    root.layoutSubtreeIfNeeded()
    let preview = try #require(root.subviews.first { $0.layer?.sublayers?.contains { $0 is AVPlayerLayer } == true })
    func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: editor.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }
    let stage = AVMakeRect(aspectRatio: size, insideRect: preview.bounds.insetBy(dx: 16, dy: 4))
    func mouse(_ type: NSEvent.EventType, _ fx: Double, _ fy: Double, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let point = preview.convert(CGPoint(x: stage.minX + stage.width * fx, y: stage.maxY - stage.height * fy), to: nil)
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
            windowNumber: editor.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    func rect(_ id: UUID) -> CGRect? { editor.timeline.document.zooms.first { $0.id == id }?.rect }
    editor.seek(to: 1)
    #expect(editor.handleKey(try key(6)) && editor.zoomTool)
    // 1つ目の区間の左の辺をつかんだまま、⇧→で2つ目の区間へ移ると、ドラッグを取り消して2つ目の枠を出す。
    preview.mouseDown(with: try mouse(.leftMouseDown, 0.25, 0.5))
    preview.mouseDragged(with: try mouse(.leftMouseDragged, 0.1, 0.5))
    #expect(editor.previewOutline != original[0].rect)
    #expect(editor.handleKey(try key(124, .shift)))
    #expect(abs(editor.position - 2) < 0.01 && editor.previewOutline == original[1].rect)
    #expect(editor.previewCursor != .resize([.minX]))
    // 離しても、どちらの区間も変えない。
    preview.mouseDragged(with: try mouse(.leftMouseDragged, 0.05, 0.5))
    preview.mouseUp(with: try mouse(.leftMouseUp, 0.05, 0.5))
    #expect(editor.timeline.document.zooms == original)
    // 1つ目の区間を縮めてから、⌥ドラッグの途中で⌘Zを押すと、ドラッグだけを取り消して履歴は戻さない。
    editor.seek(to: 1)
    preview.mouseDown(with: try mouse(.leftMouseDown, 0.25, 0.5))
    preview.mouseDragged(with: try mouse(.leftMouseDragged, 0.1, 0.5))
    preview.mouseUp(with: try mouse(.leftMouseUp, 0.1, 0.5))
    let resized = try #require(rect(first))
    #expect(resized != original[0].rect && rect(second) == original[1].rect)
    preview.mouseDown(with: try mouse(.leftMouseDown, 0.5, 0.5, .option))
    preview.mouseDragged(with: try mouse(.leftMouseDragged, 0.6, 0.6))
    #expect(editor.previewOutline != resized)
    #expect(editor.handleKey(try key(6, .command)))
    #expect(rect(first) == resized && editor.previewOutline == resized && editor.previewCursor != .closedHand)
    preview.mouseUp(with: try mouse(.leftMouseUp, 0.6, 0.6))
    #expect(rect(first) == resized)
    // 次の⌘Zで縮める前へ戻る。やり直しの途中のドラッグも取り消し、やり直しは進める。
    editor.undo(); #expect(editor.timeline.document.zooms == original)
    preview.mouseDown(with: try mouse(.leftMouseDown, 0.5, 0.5, .option))
    preview.mouseDragged(with: try mouse(.leftMouseDragged, 0.6, 0.6))
    editor.redo()
    #expect(rect(first) == resized && editor.previewOutline == resized)
    preview.mouseUp(with: try mouse(.leftMouseUp, 0.6, 0.6))
    #expect(rect(first) == resized && rect(second) == original[1].rect)
}

@MainActor @Test func zoomToolPlacesRangeOnTimelineSelectionWhenOneIsChosen() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await splitVideo(in: dir)
    let editor = VideoEditorController(source: source, document: VideoEditDocument(duration: 3), screen: nil,
        focus: .init(activate: {}, restore: { _ in }))
    defer { editor.window.close() }
    for _ in 0..<300 where editor.videoSize == nil { try await Task.sleep(for: .milliseconds(10)) }
    let root = try #require(editor.window.contentView)
    root.layoutSubtreeIfNeeded()
    let preview = try #require(root.subviews.first { $0.layer?.sublayers?.contains { $0 is AVPlayerLayer } == true })
    func key(_ code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: editor.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }
    let stage = AVMakeRect(aspectRatio: CGSize(width: 160, height: 120), insideRect: preview.bounds.insetBy(dx: 16, dy: 4))
    func mouse(_ type: NSEvent.EventType, _ fx: Double, _ fy: Double) throws -> NSEvent {
        let point = preview.convert(CGPoint(x: stage.minX + stage.width * fx, y: stage.maxY - stage.height * fy), to: nil)
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: editor.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    // 置いた矩形の縁から始めるとリサイズになるので、2回目からは右下の離れた所から描く。
    var draws = 0
    func draw() throws {
        let from = draws == 0 ? 0.05 : 0.6, to = draws == 0 ? 0.35 : 0.95
        draws += 1
        preview.mouseDown(with: try mouse(.leftMouseDown, from, from))
        preview.mouseDragged(with: try mouse(.leftMouseDragged, to, to))
        preview.mouseUp(with: try mouse(.leftMouseUp, to, to))
    }
    // 時間軸で範囲を選んでからツールで描くと、2秒の目安ではなくその範囲に置き、選択を外す。
    let timeline = editor.timeline, width = timeline.bounds.width - 48
    func strip(_ type: NSEvent.EventType, _ time: Double) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: timeline.convert(CGPoint(x: 24 + width * time / 3, y: 70 + 20), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: editor.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    timeline.mouseDown(with: try strip(.leftMouseDown, 0.3))
    timeline.mouseDragged(with: try strip(.leftMouseDragged, 1.5))
    timeline.mouseUp(with: try strip(.leftMouseUp, 1.5))
    let selected = try #require(timeline.selection)
    #expect(abs(selected.start - 0.3) < 0.02 && abs(selected.end - 1.5) < 0.02)
    #expect(editor.handleKey(try key(6)) && editor.zoomTool)
    #expect(editor.hintText.hasPrefix(String(format: "選んだ%.1f秒に", selected.duration)))
    try draw()
    let placed = try #require(editor.timeline.document.zooms.first)
    #expect(placed.range == selected && timeline.selection == nil && editor.zoomTool)
    #expect(!editor.hintText.hasPrefix("選んだ"))
    // 既存の区間と重なる範囲を選んで描いたら置かず、選択を残して知らせる。
    timeline.selection = .init(1, 2.5)
    try draw()
    #expect(editor.timeline.document.zooms.count == 1 && timeline.selection == .init(1, 2.5))
    #expect(editor.hintText.contains("選んだ範囲にはズームを置けません"))
    // 選択がなければ従来どおり、再生位置のまわりに置く。
    timeline.selection = nil
    editor.undo(); #expect(editor.timeline.document.zooms.isEmpty)
    editor.seek(to: 1.5)
    try draw()
    #expect(editor.timeline.document.zooms.first?.range == .init(0.5, 2.5))
}

@MainActor @Test func zoomLaneStandsOutOnWhiteVideoAndShortensTitleToFit() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // 白い画面の30秒の録画。2秒の区間はレーンで70pt足らずになる。
    let writer = try MP4Writer(url: dir.appendingPathComponent("recording.mp4"), width: 640, height: 360, fps: 30)
    for time in [0.0, 10.0, 20.0, 29.0] {
        await feed(writer, sample: try sample(time: 100 + time, gray: 250, width: 640, height: 360), host: 1000 + time)
        try await Task.sleep(for: .milliseconds(50))
    }
    let source = try await writer.finish(hostTime: 1030)
    let size = CGSize(width: 640, height: 360)
    var document = VideoEditDocument(duration: source.duration)
    _ = document.addZoom(drag: CGRect(x: 160, y: 90, width: 320, height: 180), size: size, at: 5)
    _ = document.addZoom(drag: CGRect(x: 0, y: 0, width: 213.3, height: 120), size: size, at: 17)
    _ = document.moveZoomBoundary(index: 1, start: false, to: 23)
    _ = document.addZoom(drag: CGRect(x: 0, y: 0, width: 320, height: 180), size: size, at: 28)
    _ = document.moveZoomBoundary(index: 2, start: true, to: 29.5)
    #expect(document.zooms.count == 3)
    let editor = VideoEditorController(source: source.temporaryURL, document: document, screen: nil, focus: .init(activate: {}, restore: { _ in }))
    defer { editor.window.close() }
    for _ in 0..<300 where editor.videoSize == nil { try await Task.sleep(for: .milliseconds(10)) }
    // 区間の下のコマまで白く描かれてから測る。読み込み前の黒い背景では、台形が無くても暗く見える。
    for _ in 0..<300 where editor.timeline.images.count < 12 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(editor.timeline.images.count == 12)
    editor.window.contentView?.layoutSubtreeIfNeeded()
    let timeline = editor.timeline, zooms = timeline.document.zooms
    #expect(timeline.zoomLaneRect(zooms[0]).width < 76)
    // 狭い区間は倍率だけ、広い区間は「ズーム」も付け、どちらも入らない区間は形だけにする。
    #expect(timeline.zoomLaneTitle(zooms[0]) == "×2.0")
    #expect(timeline.zoomLaneTitle(zooms[1]) == "ズーム ×3.0")
    #expect(timeline.zoomLaneTitle(zooms[2]) == nil)
    // 白いコマの上でも、台形は墨の濃さで描く。台形のすぐ上は白いコマのまま。
    let rep = try #require(timeline.bitmapImageRepForCachingDisplay(in: timeline.bounds))
    timeline.cacheDisplay(in: timeline.bounds, to: rep)
    let lane = timeline.zoomLaneRect(zooms[0])
    let scale = Double(rep.pixelsWide) / timeline.bounds.width
    func brightness(_ point: CGPoint) throws -> CGFloat {
        let row = timeline.isFlipped ? point.y : timeline.bounds.height - point.y
        return try #require(rep.colorAt(x: Int(point.x * scale), y: Int(row * scale))?.usingColorSpace(.sRGB)).brightnessComponent
    }
    let probeX = lane.minX + lane.width * 0.3
    #expect(try brightness(CGPoint(x: probeX, y: lane.maxY - 3)) < 0.25)
    #expect(try brightness(CGPoint(x: probeX, y: lane.minY - 4)) > 0.85)
    // 補間が区間の半分を占めると上辺が尖るので、中ほどで入る幅でも文字を出さない。
    var steep = timeline.document
    steep.setZoomEase(zooms[1].id, seconds: 2)
    _ = steep.moveZoomBoundary(index: 1, start: false, to: zooms[1].range.start + 3.9)
    timeline.document = steep
    let tall = try #require(timeline.document.zooms.first { $0.id == zooms[1].id })
    #expect(abs(tall.ramp - tall.range.duration / 2) < 0.001)
    #expect(timeline.zoomLaneRect(tall).width > 120 && timeline.zoomLaneTitle(tall) == nil)
}

@MainActor @Test func videoBoundaryDragDisplaysActualVFRPixelsAndRestoresPlayerOnReleaseOrUndo() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await editableVideo(in: dir)
    let editor = VideoEditorController(source: source.temporaryURL, document: VideoEditDocument(duration: source.duration),
        screen: nil, focus: .init(activate: {}, restore: { _ in }))
    defer { editor.window.close() }
    for _ in 0..<300 where !editor.canCapture { try await Task.sleep(for: .milliseconds(10)) }
    try #require(editor.canCapture)
    editor.seek(to: 1.2)
    let root = try #require(editor.window.contentView)
    root.layoutSubtreeIfNeeded()
    let view = try #require(root.subviews.first { $0.layer?.sublayers?.contains { $0 is AVPlayerLayer } == true })
    let overlay = try #require(view.layer?.sublayers?.last)
    let timeline = editor.timeline, width = timeline.bounds.width - 48
    func event(_ type: NSEvent.EventType, _ time: Double) throws -> NSEvent {
        let location = timeline.convert(CGPoint(x: 24 + width * time / source.duration, y: 95), to: nil)
        return try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: editor.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    func pixel() -> Int? {
        guard let contents = overlay.contents else { return nil }
        let image = contents as! CGImage
        guard let data = image.dataProvider?.data else { return nil }
        return Int((data as Data)[1])
    }
    func expectPixel(_ expected: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while abs((pixel() ?? -1000) - expected) > 8, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!overlay.isHidden && abs((pixel() ?? -1000) - expected) <= 8)
    }
    timeline.mouseDown(with: try event(.leftMouseDown, source.duration))
    try await expectPixel(200) // 録画末尾は最後の実コマ。
    timeline.mouseDragged(with: try event(.leftMouseDragged, 1.39))
    try await expectPixel(80) // 1.4秒の次コマを先取りしない。
    #expect(editor.position == 1.2 && timeline.position == 1.2)
    timeline.mouseUp(with: try event(.leftMouseUp, 1.39))
    #expect(overlay.isHidden && overlay.contents == nil && editor.position == 1.2)
    editor.undo()
    #expect(timeline.document.kept == [.init(0, source.duration)])
    timeline.mouseDown(with: try event(.leftMouseDown, 0))
    timeline.mouseDragged(with: try event(.leftMouseDragged, 1.6))
    try await expectPixel(140)
    editor.undo()
    try await Task.sleep(for: .milliseconds(100))
    #expect(overlay.isHidden && overlay.contents == nil && editor.position == 1.2)
    #expect(timeline.document.kept == [.init(0, source.duration)])
    timeline.mouseDown(with: try event(.leftMouseDown, 0))
    timeline.mouseDragged(with: try event(.leftMouseDragged, 2.7))
    editor.window.close()
    try await Task.sleep(for: .milliseconds(100))
    #expect(overlay.isHidden && overlay.contents == nil)
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
