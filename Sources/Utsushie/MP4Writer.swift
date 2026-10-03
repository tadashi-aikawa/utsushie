@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import CoreImage
import ScreenCaptureKit
import UtsushieCore

struct RecordedVideo: Sendable {
    var temporaryURL: URL
    var image: CGImage
    var width: Int
    var height: Int
    var duration: Double
}

/// AVAssetWriterと全可変状態はqueueだけで読む。SCStreamも同じキューへ出力する。
/// SDKのCMSampleBufferはSendable宣言がないが、保持した不変サンプルをキューへ渡すだけ。
final class MP4Writer: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.tadashi-aikawa.utsushie.video")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let url: URL
    private let width: Int
    private let height: Int
    private let fps: Int
    private var timeline = VideoTimeline()
    private var lastSample: CMSampleBuffer?
    private var firstImage: CGImage?
    private var failure: Error?
    private var finishing = false
    private let onFailure: @Sendable () -> Void

    init(url: URL, width: Int, height: Int, fps: Int, onFailure: @escaping @Sendable () -> Void = {}) throws {
        self.url = url; self.width = width; self.height = height; self.fps = fps; self.onFailure = onFailure
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(40_000_000, max(500_000, Int(Double(width * height * fps) * 0.12))),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureError.unavailable("H.264の録画設定を作れません") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CaptureError.unavailable("MP4の保存を開始できません") }
    }

    /// 呼び出し元はSCStreamへ渡したqueue。通常フレームでキューを増やさない。
    func append(_ sample: CMSampleBuffer, hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finishing, failure == nil, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: status) == .complete else { return }
        if writer.status == .failed {
            failure = writer.error ?? CaptureError.unavailable("MP4の書き出しに失敗しました")
            onFailure(); return
        }
        guard input.isReadyForMoreMediaData else { return } // 実時間優先。バックプレッシャー時は落とす。
        var nextTimeline = timeline
        guard let presentation = nextTimeline.accept(sourceTime: sample.presentationTimeStamp.seconds, hostTime: hostTime) else { return }
        do {
            let copy = try retimed(sample, presentation: presentation, duration: 1 / Double(fps))
            if lastSample == nil { writer.startSession(atSourceTime: .zero) }
            guard input.append(copy) else { throw writer.error ?? CaptureError.unavailable("MP4フレームを書けません") }
            timeline = nextTimeline; lastSample = sample
            if firstImage == nil, let pixels = sample.imageBuffer {
                firstImage = CIContext().createCGImage(CIImage(cvPixelBuffer: pixels), from: CGRect(x: 0, y: 0, width: width, height: height))
            }
        } catch { failure = error; onFailure() }
    }

    func finish(hostTime: Double = ProcessInfo.processInfo.systemUptime) async throws -> RecordedVideo {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.finishing else {
                    continuation.resume(throwing: CaptureError.unavailable("録画はすでに書き出し中です")); return
                }
                self.finishing = true
                self.finishWhenReady(hostTime: hostTime, deadline: ProcessInfo.processInfo.systemUptime + 5, continuation: continuation)
            }
        }
    }
    private func finishWhenReady(hostTime: Double, deadline: Double, continuation: CheckedContinuation<RecordedVideo, Error>) {
        if let failure { fail(failure, continuation: continuation); return }
        guard let end = timeline.end(hostTime: hostTime, fps: fps), let lastSample, let firstImage else {
            fail(CaptureError.unavailable("録画フレームを受信できませんでした"), continuation: continuation); return
        }
        if end.tailPresentation != nil && !input.isReadyForMoreMediaData {
            guard writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline else {
                fail(writer.error ?? CaptureError.unavailable("MP4の書き出しが応答しません"), continuation: continuation); return
            }
            // 最後の複製フレームは落とさない。キューを塞がずencoderの空きを待つ。
            queue.asyncAfter(deadline: .now() + 0.01) {
                self.finishWhenReady(hostTime: hostTime, deadline: deadline, continuation: continuation)
            }
            return
        }
        do {
            if let tail = end.tailPresentation {
                let copy = try retimed(lastSample, presentation: tail, duration: end.duration - tail)
                guard input.append(copy) else { throw writer.error ?? CaptureError.unavailable("録画末尾を書けません") }
            }
            writer.endSession(atSourceTime: CMTime(seconds: end.duration, preferredTimescale: 60000))
            input.markAsFinished()
            writer.finishWriting {
                self.queue.async {
                    guard self.writer.status == .completed else {
                        self.fail(self.writer.error ?? CaptureError.unavailable("MP4の書き出しに失敗しました"), continuation: continuation); return
                    }
                    self.lastSample = nil
                    continuation.resume(returning: RecordedVideo(temporaryURL: self.url, image: firstImage,
                        width: self.width, height: self.height, duration: end.duration))
                }
            }
        } catch { fail(error, continuation: continuation) }
    }
    private func fail(_ error: Error, continuation: CheckedContinuation<RecordedVideo, Error>) {
        writer.cancelWriting(); lastSample = nil
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            continuation.resume(throwing: error)
        } catch {
            continuation.resume(throwing: CaptureError.unavailable("書き出しに失敗し、中途ファイルも削除できませんでした: \(url.path)\n\(error.localizedDescription)"))
        }
    }
    func abort() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.finishing = true; self.writer.cancelWriting(); self.lastSample = nil
                try? FileManager.default.removeItem(at: self.url)
                continuation.resume()
            }
        }
    }
    func firstFrame() async -> CGImage? {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.firstImage) } }
    }
    private func retimed(_ sample: CMSampleBuffer, presentation: Double, duration: Double) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: duration, preferredTimescale: 60000),
            presentationTimeStamp: CMTime(seconds: presentation, preferredTimescale: 60000), decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let result = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
        guard result == noErr, let copy else { throw CaptureError.unavailable("録画フレームの時刻を変換できません: \(result)") }
        return copy
    }
}

final class RecordingSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let writer: MP4Writer
    private let onStop: @Sendable () -> Void
    init(writer: MP4Writer, onStop: @escaping @Sendable () -> Void) { self.writer = writer; self.onStop = onStop }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen { writer.append(sampleBuffer) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // 対象の消失などでストリームが止まった場合も、受信済みのフレームをfinalizeする。
        onStop()
    }
}
