@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import ScreenCaptureKit
import Testing
import UtsushieCore
@testable import Utsushie

// サンプルは作成後に変更しない。SCStream同様、保持してwriterの専用キューへ渡す。
private struct Sample: @unchecked Sendable { let buffer: CMSampleBuffer }

private func frame(time: Double) throws -> Sample {
    var pixels: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess)
    let image = try #require(pixels)
    var description: CMVideoFormatDescription?
    #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &description) == noErr)
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 60000), decodeTimeStamp: .invalid)
    var buffer: CMSampleBuffer?
    #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
        formatDescription: try #require(description), sampleTiming: &timing, sampleBufferOut: &buffer) == noErr)
    let result = try #require(buffer)
    let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true)) as NSArray
    (attachments.firstObject as? NSMutableDictionary)?[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
    return Sample(buffer: result)
}

/// SCStreamと同じ非インターリーブのFloat32。振幅0.3の正弦波。
private func tone(time: Double, frames: Int, rate: Double = 48_000, channels: UInt32 = 2) throws -> Sample {
    var description = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    #expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr)
    let audioFormat = try #require(format)
    let silence = try #require(AudioBuffers.silence(like: audioFormat, frames: frames, at: 0))
    let block = try #require(CMSampleBufferGetDataBuffer(silence))
    var length = 0; var pointer: UnsafeMutablePointer<CChar>?
    #expect(CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr)
    let samples = try #require(pointer).withMemoryRebound(to: Float.self, capacity: length / 4) { $0 }
    for index in 0..<(length / 4) { samples[index] = 0.3 * sinf(Float(index % frames) * 0.06) }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
        presentationTimeStamp: CMTime(seconds: time, preferredTimescale: CMTimeScale(rate)), decodeTimeStamp: .invalid)
    var copy: CMSampleBuffer?
    #expect(CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: silence,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr)
    return Sample(buffer: try #require(copy))
}

private func onQueue(_ writer: MP4Writer, _ work: @escaping @Sendable () -> Void) async {
    await withCheckedContinuation { continuation in writer.queue.async { work(); continuation.resume() } }
}

/// 10msごとの音を元録画の時刻で流す。間はSCStreamが音を送らなかった区間。
private func feedTone(_ writer: MP4Writer, from start: Double, to end: Double, source: AudioSource,
                      rate: Double = 48_000, channels: UInt32 = 2) async throws {
    let frames = Int(rate / 100)
    var time = start
    while time < end - 1e-9 {
        let sample = try tone(time: 100 + time, frames: frames, rate: rate, channels: channels)
        await onQueue(writer) { writer.appendAudio(sample.buffer, from: source) }
        time += 0.01
        try await Task.sleep(for: .milliseconds(1))
    }
}

/// 書き出したMP4の音を48kHzステレオで読み、時刻の範囲の最大振幅を返す。
private struct Loudness {
    let samples: [Float]
    let tracks: Int
    init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        tracks = audio.count
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: VideoEncoding.pcmSettings)
        reader.add(output)
        #expect(reader.startReading())
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            let block = try #require(CMSampleBufferGetDataBuffer(buffer))
            var data = Data(count: CMBlockBufferGetDataLength(block))
            data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            samples.append(contentsOf: data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
        }
        #expect(reader.status == .completed)
        self.samples = samples
    }
    var duration: Double { Double(samples.count / 2) / 48_000 }
    func peak(_ start: Double, _ end: Double) -> Float {
        let lower = min(samples.count, max(0, Int(start * 48_000) * 2))
        let range = lower..<max(lower, min(samples.count, Int(end * 48_000) * 2))
        return range.isEmpty ? 0 : samples[range].map(abs).max() ?? 0
    }
}

private func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func silentSourceMakesNoAudioTrackChangeForPlainRecording() async throws {
    let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let writer = try MP4Writer(url: dir.appendingPathComponent("recording.mp4"), width: 64, height: 48, fps: 30, audio: [.system])
    let first = try frame(time: 100)
    await onQueue(writer) { writer.append(first.buffer, hostTime: 1000) }
    let result = try await writer.finish(hostTime: 1002)
    let asset = AVURLAsset(url: result.temporaryURL)
    #expect(abs(try await asset.load(.duration).seconds - 2) < 0.05)
    #expect(try await asset.load(.isPlayable))
}

@Test func audioGapsAreFilledWithSilenceAndSoundBeforeFirstFrameIsDropped() async throws {
    let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let writer = try MP4Writer(url: dir.appendingPathComponent("recording.mp4"), width: 64, height: 48, fps: 30, audio: [.system])
    try await feedTone(writer, from: -0.5, to: 0, source: .system)
    let first = try frame(time: 100)
    await onQueue(writer) { writer.append(first.buffer, hostTime: 1000) }
    try await feedTone(writer, from: 0.3, to: 0.8, source: .system)
    try await feedTone(writer, from: 1.8, to: 2.3, source: .system)
    let result = try await writer.finish(hostTime: 1003)
    let sound = try await Loudness(url: result.temporaryURL)
    #expect(sound.tracks == 1)
    #expect(sound.peak(0.02, 0.26) < 0.01)
    #expect(sound.peak(0.35, 0.75) > 0.2)
    #expect(sound.peak(0.86, 1.74) < 0.01)
    #expect(sound.peak(1.85, 2.25) > 0.2)
    #expect(abs(try await AVURLAsset(url: result.temporaryURL).load(.duration).seconds - 3) < 0.05)
}

@Test func appAndMicrophoneAreMixedIntoOneTrackWithVideoUntouched() async throws {
    let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let writer = try MP4Writer(url: dir.appendingPathComponent("recording.mp4"), width: 64, height: 48, fps: 30, audio: [.system, .microphone])
    let first = try frame(time: 100)
    await onQueue(writer) { writer.append(first.buffer, hostTime: 1000) }
    try await feedTone(writer, from: 0, to: 1, source: .system)
    // マイクは標本化周波数とチャンネル数が違っても同じ形式へ揃える。
    try await feedTone(writer, from: 1, to: 2, source: .microphone, rate: 44_100, channels: 1)
    let result = try await writer.finish(hostTime: 1003)
    let sound = try await Loudness(url: result.temporaryURL)
    #expect(sound.tracks == 1)
    #expect(sound.duration > 1.95, "音の長さ: \(sound.duration)")
    #expect(sound.peak(0.1, 0.9) > 0.2)
    #expect(sound.peak(1.1, 1.9) > 0.2)
    #expect(sound.peak(2.1, 2.9) < 0.01)
    let asset = AVURLAsset(url: result.temporaryURL)
    #expect(abs(try await asset.load(.duration).seconds - 3) < 0.05)
    let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let videoFormat = try #require(try await video.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(videoFormat) == kCMVideoCodecType_H264)
    let hidden = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("mixing") }
    #expect(hidden.isEmpty)
}

private func tonedRecording(in dir: URL) async throws -> RecordedVideo {
    let writer = try MP4Writer(url: dir.appendingPathComponent("source.mp4"), width: 64, height: 48, fps: 30, audio: [.system])
    for time in [0.0, 1.2, 2.4] {
        let sample = try frame(time: 100 + time)
        await onQueue(writer) { writer.append(sample.buffer, hostTime: 1000 + time) }
        try await feedTone(writer, from: time, to: time + 1.2, source: .system)
    }
    return try await writer.finish(hostTime: 1003.6)
}

@Test func exportKeepsAudioOfKeptRangesAndMutesFastForward() async throws {
    let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await tonedRecording(in: dir)
    var document = VideoEditDocument(duration: source.duration, kept: [.init(0, 0.6), .init(2.6, 3.6)])
    document.setTransition(for: .init(0.6, 2.6), kind: .fastForward, speed: 4)
    let target = dir.appendingPathComponent("fast.mp4")
    let result = try await VideoEditExporter.export(source: source.temporaryURL, destination: target, document: document, fps: 30)
    #expect(abs(result.duration - 2.1) < 0.001)
    let sound = try await Loudness(url: target)
    #expect(sound.tracks == 1)
    #expect(sound.peak(0.05, 0.55) > 0.2)
    #expect(sound.peak(0.65, 1.05) < 0.01)
    #expect(sound.peak(1.15, 2.05) > 0.2)
    #expect(abs(try await AVURLAsset(url: target).load(.duration).seconds - 2.1) < 0.05)
}

@Test func exportFadesSoundThroughBlackAndCrossesItForDissolve() async throws {
    let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let source = try await tonedRecording(in: dir)
    for kind in [VideoTransitionKind.fade, .dissolve] {
        var document = VideoEditDocument(duration: source.duration, kept: [.init(0, 1), .init(2, 3.6)])
        document.setTransition(for: .init(1, 2), kind: kind)
        let target = dir.appendingPathComponent("\(kind.rawValue).mp4")
        _ = try await VideoEditExporter.export(source: source.temporaryURL, destination: target, document: document, fps: 30)
        let sound = try await Loudness(url: target)
        #expect(sound.peak(0.1, 0.9) > 0.2)
        #expect(sound.peak(1.6, 3.0) > 0.2)
        // 暗転の中央は無音、ディゾルブは前後の音が重なって途切れない。
        if kind == .fade { #expect(sound.peak(1.24, 1.26) < 0.02) }
        else { #expect(sound.peak(1.2, 1.3) > 0.1) }
    }
}

/// 実際の録画で取り出せなかった325/600秒などのコマ。Doubleでは僅かに小さく表され、切り捨てると前のコマになる。
@Test func everyFrameOfVariableRateRecordingCanBeExtractedExactly() async throws {
    let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let writer = try MP4Writer(url: dir.appendingPathComponent("source.mp4"), width: 64, height: 48, fps: 30)
    let ticks = [0, 20, 40, 60, 80, 100, 125, 145, 165, 185, 205, 225, 245, 265, 285, 305, 325, 350, 370, 390,
                 410, 430, 450, 470, 490, 510, 530, 550, 570, 595, 615, 635, 655]
    for tick in ticks {
        let time = Double(tick) / 600
        let sample = try frame(time: 100 + time)
        await onQueue(writer) { writer.append(sample.buffer, hostTime: 1000 + time) }
        try await Task.sleep(for: .milliseconds(5))
    }
    let result = try await writer.finish(hostTime: 1001.2)
    let times = try await VideoEditMedia.frameTimes(url: result.temporaryURL)
    #expect(times.count == ticks.count + 1)
    var failed: [Double] = []
    for time in times {
        do { _ = try await VideoStillExporter.frame(source: result.temporaryURL, time: time, maximumSize: CGSize(width: 1280, height: 1280)) }
        catch { failed.append(time) }
    }
    #expect(failed.isEmpty)
}
