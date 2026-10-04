@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import CoreImage
import UtsushieCore

enum VideoEditExporter {
    static func export(source: URL, destination: URL, document: VideoEditDocument, fps: Int) async throws -> RecordedVideo {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptureError.unavailable("元の動画を読めません")
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let job = try VideoExportJob(asset: asset, track: track, destination: destination,
                                     plan: VideoExportPlan(document: document), sourceDuration: document.duration,
                                     width: Int(size.width), height: Int(size.height), fps: fps, transform: transform)
        return try await job.run()
    }
}

/// Reader/Writerとサンプルはqueueからだけ操作する。2コマの先読みでVFRの表示時間を求める。
private final class VideoExportJob: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.tadashi-aikawa.utsushie.video-edit")
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let destination: URL
    private let plan: VideoExportPlan
    private let sourceDuration: Double
    private let width: Int
    private let height: Int
    private var current: CMSampleBuffer?
    private var next: CMSampleBuffer?
    private var pending: [CMSampleBuffer] = []
    private var image: CGImage?
    private var completed = false
    private var continuation: CheckedContinuation<RecordedVideo, Error>?

    init(asset: AVAsset, track: AVAssetTrack, destination: URL, plan: VideoExportPlan, sourceDuration: Double,
         width: Int, height: Int, fps: Int, transform: CGAffineTransform) throws {
        guard plan.duration > 0 else { throw CaptureError.unavailable("残す範囲がありません") }
        self.destination = destination; self.plan = plan; self.sourceDuration = sourceDuration
        self.width = width; self.height = height
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CaptureError.unavailable("動画の読み取り設定を作れません") }
        reader.add(output)
        writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        input = AVAssetWriterInput(mediaType: .video, outputSettings: VideoEncoding.settings(width: width, height: height, fps: fps))
        input.expectsMediaDataInRealTime = false; input.transform = transform
        guard writer.canAdd(input) else { throw CaptureError.unavailable("H.264の書き出し設定を作れません") }
        writer.add(input)
    }
    func run() async throws -> RecordedVideo {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                guard self.reader.startReading(), self.writer.startWriting() else {
                    self.fail(self.reader.error ?? self.writer.error ?? CaptureError.unavailable("書き出しを開始できません")); return
                }
                self.writer.startSession(atSourceTime: .zero)
                self.current = self.output.copyNextSampleBuffer(); self.next = self.output.copyNextSampleBuffer()
                self.input.requestMediaDataWhenReady(on: self.queue) { self.pump() }
            }
        }
    }
    private func pump() {
        guard !completed else { return }
        do {
            while input.isReadyForMoreMediaData {
                if !pending.isEmpty {
                    let sample = pending.removeFirst()
                    guard input.append(sample) else { throw writer.error ?? CaptureError.unavailable("動画のコマを書けません") }
                    if image == nil, let pixels = sample.imageBuffer {
                        image = CIContext().createCGImage(CIImage(cvPixelBuffer: pixels), from: CGRect(x: 0, y: 0, width: width, height: height))
                    }
                    continue
                }
                guard let sample = current else {
                    guard reader.status == .completed, image != nil else {
                        throw reader.error ?? CaptureError.unavailable("動画のコマを読み取れません")
                    }
                    finish(); return
                }
                let a = sample.presentationTimeStamp.seconds
                let b = next?.presentationTimeStamp.seconds ?? sourceDuration
                guard a.isFinite, b.isFinite, b > a else { throw CaptureError.unavailable("動画のコマの時刻が不正です") }
                // 静止画が保持されている途中を切る場合も、境界の画像を先頭へ置く。
                for segment in plan.segments where segment.source.start < b && segment.source.end > a {
                    let start = max(a, segment.source.start), end = min(b, segment.source.end)
                    pending.append(try retimed(sample, start: segment.outputStart + start - segment.source.start, duration: end - start))
                }
                current = next; next = output.copyNextSampleBuffer()
            }
            if writer.status == .failed { throw writer.error ?? CaptureError.unavailable("動画の書き出しに失敗しました") }
        } catch { fail(error) }
    }
    private func finish() {
        completed = true; current = nil; next = nil
        writer.endSession(atSourceTime: CMTime(seconds: plan.duration, preferredTimescale: 60000))
        input.markAsFinished()
        writer.finishWriting {
            self.queue.async {
                guard self.writer.status == .completed, let image = self.image else {
                    self.fail(self.writer.error ?? CaptureError.unavailable("MP4の書き出しに失敗しました")); return
                }
                self.continuation?.resume(returning: RecordedVideo(temporaryURL: self.destination, image: image,
                    width: self.width, height: self.height, duration: self.plan.duration))
                self.continuation = nil
            }
        }
    }
    private func fail(_ error: Error) {
        completed = true; reader.cancelReading(); writer.cancelWriting()
        current = nil; next = nil; pending = []
        try? FileManager.default.removeItem(at: destination)
        continuation?.resume(throwing: error); continuation = nil
    }
    private func retimed(_ sample: CMSampleBuffer, start: Double, duration: Double) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: duration, preferredTimescale: 60000),
            presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 60000), decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
        guard status == noErr, let copy else { throw CaptureError.unavailable("動画の時刻を変換できません") }
        return copy
    }
}

enum VideoEditMedia {
    /// コマ送りはfpsの割り算ではなく、録画に実在するコマのPTSを使う。
    static func frameTimes(url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let task = Task.detached(priority: .userInitiated) {
            let reader = try AVAssetReader(asset: asset)
            // 圧縮サンプルのPTSはBフレームの遅延とMP4のedit listを含む。
            // デコード後のPTSはAVPlayer/ImageGeneratorと同じ元録画の時刻になる。
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CaptureError.unavailable("コマの時刻を読めません") }
            defer { if reader.status == .reading { reader.cancelReading() } }
            var times: [Double] = []
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                times.append(sample.presentationTimeStamp.seconds)
            }
            guard reader.status == .completed else { throw reader.error ?? CaptureError.unavailable("コマの時刻を読めません") }
            return Array(Set(times.filter(\.isFinite))).sorted()
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
