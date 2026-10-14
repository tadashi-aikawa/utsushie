@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import OSLog

enum AudioSource: Sendable, CaseIterable { case system, microphone }

/// 1つの音源を1トラックへ書く。状態はMP4Writer.queueだけで読む。
/// AVAssetWriterは音の途中の隙間を詰めてしまうため、無音で埋めて映像との時刻を保つ。
final class AudioTrackWriter {
    let input: AVAssetWriterInput
    private var next = 0.0
    init() {
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: VideoEncoding.audioSettings)
        input.expectsMediaDataInRealTime = true
    }
    func append(_ sample: CMSampleBuffer, at start: Double) throws {
        guard let format = sample.formatDescription,
              let rate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate, rate > 0 else { return }
        let frames = CMSampleBufferGetNumSamples(sample)
        // 書けなかった音は落とし、次の音の前を無音で埋める。2msを超えて重なる音は使わない。
        guard frames > 0, start >= next - 0.002 else { return }
        while start - next > 1 / rate {
            guard input.isReadyForMoreMediaData else { return }
            let count = min(Int(((start - next) * rate).rounded()), Int(rate))
            guard let silence = AudioBuffers.silence(like: format, frames: count, at: next) else { break }
            guard input.append(silence) else { throw CaptureError.unavailable("録画の無音を書けません") }
            next += Double(count) / rate
        }
        guard input.isReadyForMoreMediaData else { return }
        let presentation = max(start, next)
        guard input.append(try AudioBuffers.retimed(sample, at: presentation, rate: rate)) else {
            throw CaptureError.unavailable("録画の音を書けません")
        }
        next = presentation + Double(frames) / rate
    }
}

enum AudioBuffers {
    static func retimed(_ sample: CMSampleBuffer, at seconds: Double, rate: Double) throws -> CMSampleBuffer {
        let scale = CMTimeScale(rate.rounded())
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: scale),
            presentationTimeStamp: CMTime(value: CMTimeValue((seconds * rate).rounded()), timescale: scale), decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
        guard status == noErr, let copy else { throw CaptureError.unavailable("録画の音の時刻を変換できません: \(status)") }
        return copy
    }
    /// 同じ形式の無音。非インターリーブはチャンネルごとの面を続けて置く。
    static func silence(like format: CMAudioFormatDescription, frames: Int, at seconds: Double) -> CMSampleBuffer? {
        guard frames > 0, let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM, description.mBytesPerFrame > 0, description.mSampleRate > 0 else { return nil }
        let planes = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Int(description.mChannelsPerFrame) : 1
        let length = frames * Int(description.mBytesPerFrame) * planes
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                  blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: length,
                  flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == noErr else { return nil }
        let scale = CMTimeScale(description.mSampleRate.rounded())
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
                  formatDescription: format, sampleCount: frames,
                  presentationTimeStamp: CMTime(value: CMTimeValue((seconds * description.mSampleRate).rounded()), timescale: scale),
                  packetDescriptions: nil, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}

/// アプリの音とマイクの2トラックを1トラックへ混ぜる。多くの再生先は最初の音のトラックしか鳴らさないため。
/// 映像は再エンコードせずに写す。
enum AudioMixdown {
    private static let log = Logger(subsystem: "com.tadashi-aikawa.utsushie", category: "Recording")
    /// 失敗しても元のファイルを残す。混ぜる前の2トラックのまま共有できるようにするため。
    static func mixInPlace(_ url: URL) async {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".utsushie-\(UUID().uuidString).mixing.mp4")
        do {
            let asset = AVURLAsset(url: url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first,
                  let format = try await video.load(.formatDescriptions).first else {
                throw CaptureError.unavailable("録画の映像を読めません")
            }
            let job = try AudioMixdownJob(asset: asset, video: video, format: format,
                transform: try await video.load(.preferredTransform),
                audio: try await asset.loadTracks(withMediaType: .audio),
                duration: try await asset.load(.duration), destination: temporary)
            try await job.run()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            log.error("音を混ぜられませんでした: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// readerとwriterはqueueからだけ操作する。
private final class AudioMixdownJob: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.tadashi-aikawa.utsushie.audio-mix")
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let pairs: [(output: AVAssetReaderOutput, input: AVAssetWriterInput)]
    private let duration: CMTime
    private let destination: URL
    private var finished: [Bool]
    private var done = false
    private var continuation: CheckedContinuation<Void, Error>?

    init(asset: AVAsset, video: AVAssetTrack, format: CMFormatDescription, transform: CGAffineTransform,
         audio: [AVAssetTrack], duration: CMTime, destination: URL) throws {
        self.duration = duration; self.destination = destination
        reader = try AVAssetReader(asset: asset)
        writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        videoInput.transform = transform
        pairs = [(AVAssetReaderTrackOutput(track: video, outputSettings: nil), videoInput),
                 (AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: VideoEncoding.pcmSettings),
                  AVAssetWriterInput(mediaType: .audio, outputSettings: VideoEncoding.audioSettings))]
        for pair in pairs {
            guard reader.canAdd(pair.output), writer.canAdd(pair.input) else { throw CaptureError.unavailable("音を混ぜる設定を作れません") }
            reader.add(pair.output); writer.add(pair.input)
        }
        finished = Array(repeating: false, count: pairs.count)
    }
    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.continuation = continuation
                guard self.reader.startReading(), self.writer.startWriting() else {
                    self.fail(self.reader.error ?? self.writer.error ?? CaptureError.unavailable("音を混ぜ始められません")); return
                }
                self.writer.startSession(atSourceTime: .zero)
                for index in self.pairs.indices {
                    self.pairs[index].input.requestMediaDataWhenReady(on: self.queue) { self.pump(index) }
                }
            }
        }
    }
    private func pump(_ index: Int) {
        guard !done, !finished[index] else { return }
        let (output, input) = pairs[index]
        while input.isReadyForMoreMediaData {
            if let sample = output.copyNextSampleBuffer() {
                guard input.append(sample) else { fail(writer.error ?? CaptureError.unavailable("混ぜた音を書けません")); return }
                continue
            }
            guard reader.status != .failed else { fail(reader.error ?? CaptureError.unavailable("録画を読めません")); return }
            finished[index] = true; input.markAsFinished()
            if !finished.contains(false) { finish() }
            return
        }
    }
    private func finish() {
        done = true
        writer.endSession(atSourceTime: duration)
        writer.finishWriting {
            self.queue.async {
                guard self.writer.status == .completed else {
                    self.fail(self.writer.error ?? CaptureError.unavailable("音を混ぜた録画を書けません")); return
                }
                self.continuation?.resume(); self.continuation = nil
            }
        }
    }
    private func fail(_ error: Error) {
        done = true; reader.cancelReading(); writer.cancelWriting()
        try? FileManager.default.removeItem(at: destination)
        continuation?.resume(throwing: error); continuation = nil
    }
}

