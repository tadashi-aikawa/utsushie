@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import CoreImage
import UtsushieCore

enum VideoEditExporter {
    static func export(source: URL, destination: URL, document: VideoEditDocument, fps: Int,
                       compression: VideoCompression = .compact) async throws -> RecordedVideo {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptureError.unavailable("元の動画を読めません")
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let plan = VideoExportPlan(document: document)
        var audio: VideoEditAudio?
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            var sources: [(track: AVAssetTrack, range: CMTimeRange)] = []
            for audioTrack in audioTracks { sources.append((audioTrack, try await audioTrack.load(.timeRange))) }
            audio = try VideoEditAudio(sources: sources, plan: VideoAudioPlan(plan: plan, sourceDuration: document.duration))
        }
        let job = try VideoExportJob(asset: asset, track: track, audio: audio, destination: destination,
                                     plan: plan, sourceDuration: document.duration,
                                     width: Int(size.width), height: Int(size.height), fps: fps, compression: compression,
                                     transform: transform)
        return try await job.run()
    }
}

/// 残す区間の音を書き出しの時刻へ並べたComposition。前後が重なる音は別トラックへ置き、音量の変化で絞る。
struct VideoEditAudio {
    let composition: AVMutableComposition
    let tracks: [AVMutableCompositionTrack]
    let mix: AVMutableAudioMix

    init?(sources: [(track: AVAssetTrack, range: CMTimeRange)], plan: VideoAudioPlan) throws {
        composition = AVMutableComposition()
        var tracks: [AVMutableCompositionTrack] = []
        var parameters: [AVMutableAudioMixInputParameters] = []
        for source in sources {
            for slot in 0..<2 {
                let clips = plan.clips.filter { $0.track == slot }
                guard !clips.isEmpty,
                      let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                let volume = AVMutableAudioMixInputParameters(track: track)
                // 音量の既定は1で、絞りの始まりの一瞬が鳴る。最初の絞りより前を0にしておく。
                if let first = clips.first, first.fadeIn > 0, first.outputStart > 0 { volume.setVolume(0, at: .zero) }
                var cursor = CMTime.zero
                for clip in clips {
                    // 音が映像より短い録画では、音のある範囲だけを並べる。
                    let requested = CMTimeRange(start: VideoExportTiming.time(clip.source.start), end: VideoExportTiming.time(clip.source.end))
                    let available = requested.intersection(source.range)
                    guard available.duration > .zero else { continue }
                    let start = VideoExportTiming.time(clip.outputStart) + (available.start - requested.start)
                    if start > cursor { track.insertEmptyTimeRange(CMTimeRange(start: cursor, end: start)) }
                    try track.insertTimeRange(available, of: source.track, at: start)
                    cursor = start + available.duration
                    let clipStart = VideoExportTiming.time(clip.outputStart), clipEnd = VideoExportTiming.time(clip.outputEnd)
                    if clip.fadeIn > 0 {
                        volume.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                            timeRange: CMTimeRange(start: clipStart, duration: VideoExportTiming.time(clip.fadeIn)))
                    } else { volume.setVolume(1, at: clipStart) }
                    if clip.fadeOut > 0 {
                        volume.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                            timeRange: CMTimeRange(start: clipEnd - VideoExportTiming.time(clip.fadeOut), end: clipEnd))
                    }
                }
                guard cursor > .zero else { composition.removeTrack(track); continue }
                tracks.append(track); parameters.append(volume)
            }
        }
        guard !tracks.isEmpty else { return nil }
        self.tracks = tracks
        mix = AVMutableAudioMix(); mix.inputParameters = parameters
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
    private let fps: Int
    private let renderer: VideoTransitionRenderer
    private struct HeldFrame {
        var sample: CMSampleBuffer
        var start: Double
        var speed: Int
    }
    private var heldFastForward: HeldFrame?
    private var current: CMSampleBuffer?
    private var next: CMSampleBuffer?
    private enum Emission {
        case sample(CMSampleBuffer)
        case transition(before: CMSampleBuffer, after: CMSampleBuffer, kind: VideoTransitionKind, progress: Double, start: Double, duration: Double)
    }
    private var pending: [Emission] = []
    private var precedingFrame: CMSampleBuffer?
    private var emittedJunctions: Set<Int> = []
    private var image: CGImage?
    private var completed = false
    private var continuation: CheckedContinuation<RecordedVideo, Error>?
    /// 音はCompositionを別のreaderで読み、映像と同じwriterへ並行して渡す。
    private let audioReader: AVAssetReader?
    private let audioOutput: AVAssetReaderAudioMixOutput?
    private let audioInput: AVAssetWriterInput?
    private var videoFinished = false
    private var audioFinished: Bool

    init(asset: AVAsset, track: AVAssetTrack, audio: VideoEditAudio?, destination: URL, plan: VideoExportPlan, sourceDuration: Double,
         width: Int, height: Int, fps: Int, compression: VideoCompression, transform: CGAffineTransform) throws {
        guard plan.duration > 0 else { throw CaptureError.unavailable("残す範囲がありません") }
        self.destination = destination; self.plan = plan; self.sourceDuration = sourceDuration
        self.width = width; self.height = height
        self.fps = max(1, fps); renderer = try VideoTransitionRenderer(width: width, height: height)
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CaptureError.unavailable("動画の読み取り設定を作れません") }
        reader.add(output)
        writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true; writer.movieTimeScale = 60000
        input = AVAssetWriterInput(mediaType: .video,
                                   outputSettings: VideoEncoding.settings(width: width, height: height, fps: fps, compression: compression))
        input.expectsMediaDataInRealTime = false; input.transform = transform; input.mediaTimeScale = 60000
        guard writer.canAdd(input) else { throw CaptureError.unavailable("H.264の書き出し設定を作れません") }
        writer.add(input)
        if let audio {
            let reader = try AVAssetReader(asset: audio.composition)
            let output = AVAssetReaderAudioMixOutput(audioTracks: audio.tracks, audioSettings: VideoEncoding.pcmSettings)
            output.audioMix = audio.mix
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: VideoEncoding.audioSettings)
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else { throw CaptureError.unavailable("AACの書き出し設定を作れません") }
            reader.add(output); writer.add(input)
            audioReader = reader; audioOutput = output; audioInput = input
        } else { audioReader = nil; audioOutput = nil; audioInput = nil }
        audioFinished = audio == nil
    }
    func run() async throws -> RecordedVideo {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                guard self.reader.startReading(), self.audioReader?.startReading() ?? true, self.writer.startWriting() else {
                    self.fail(self.reader.error ?? self.audioReader?.error ?? self.writer.error ?? CaptureError.unavailable("書き出しを開始できません")); return
                }
                self.writer.startSession(atSourceTime: .zero)
                self.current = self.output.copyNextSampleBuffer(); self.next = self.output.copyNextSampleBuffer()
                self.input.requestMediaDataWhenReady(on: self.queue) { self.pump() }
                self.audioInput?.requestMediaDataWhenReady(on: self.queue) { self.pumpAudio() }
            }
        }
    }
    private func pumpAudio() {
        guard !completed, !audioFinished, let audioReader, let audioOutput, let audioInput else { return }
        do {
            while audioInput.isReadyForMoreMediaData {
                if let sample = audioOutput.copyNextSampleBuffer() {
                    guard audioInput.append(sample) else { throw writer.error ?? CaptureError.unavailable("動画の音を書けません") }
                    continue
                }
                guard audioReader.status == .completed else { throw audioReader.error ?? CaptureError.unavailable("動画の音を読み取れません") }
                audioFinished = true; audioInput.markAsFinished(); finishIfReady()
                return
            }
        } catch { fail(error) }
    }
    private func pump() {
        guard !completed, !videoFinished else { return }
        do {
            while input.isReadyForMoreMediaData {
                if !pending.isEmpty {
                    let sample: CMSampleBuffer
                    switch pending.removeFirst() {
                    case .sample(let ready): sample = ready
                    case let .transition(before, after, kind, progress, start, duration):
                        sample = try renderer.transition(before: before, after: after, kind: kind, progress: progress, start: start, duration: duration)
                    }
                    guard input.append(sample) else { throw writer.error ?? CaptureError.unavailable("動画のコマを書けません") }
                    if image == nil, let pixels = sample.imageBuffer {
                        image = renderer.context.createCGImage(CIImage(cvPixelBuffer: pixels), from: CGRect(x: 0, y: 0, width: width, height: height))
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
                for (index, segment) in plan.segments.enumerated() where segment.source.start < b && segment.source.end > a {
                    if let junction = plan.junctions.first(where: { $0.followingSegment == index }),
                       (junction.transition.kind == .fade || junction.transition.kind == .dissolve),
                       !emittedJunctions.contains(index), let precedingFrame {
                        // 黒のコマを必ず0.25秒へ置く。バッファは描画直前まで2枚を共有する。
                        let count = max(1, Int(ceil(Double(fps) * 0.25))) * 2
                        for frame in 0..<count {
                            let offset = Double(frame) * 0.5 / Double(count)
                            pending.append(.transition(before: precedingFrame, after: sample, kind: junction.transition.kind,
                                progress: Double(frame) / Double(count), start: junction.outputTime + offset, duration: 0.5 / Double(count)))
                        }
                        emittedJunctions.insert(index)
                    }
                    let start = max(a, segment.source.start), end = min(b, segment.source.end)
                    let outputStart = segment.outputTime(forSource: start)
                    if segment.speed > 1 {
                        if let held = heldFastForward {
                            if outputStart - held.start >= 1 / Double(fps) - 1e-9 {
                                pending.append(.sample(try renderer.fastForward(held.sample, speed: held.speed, start: held.start, duration: outputStart - held.start)))
                                heldFastForward = HeldFrame(sample: sample, start: outputStart, speed: segment.speed)
                            }
                        } else { heldFastForward = HeldFrame(sample: sample, start: outputStart, speed: segment.speed) }
                        if end == segment.source.end, let held = heldFastForward {
                            pending.append(.sample(try renderer.fastForward(held.sample, speed: held.speed, start: held.start,
                                duration: segment.outputStart + segment.outputDuration - held.start)))
                            heldFastForward = nil
                        }
                    } else {
                        pending.append(.sample(try retimed(sample, start: outputStart, duration: end - start)))
                        precedingFrame = sample
                    }
                }
                current = next; next = output.copyNextSampleBuffer()
            }
            if writer.status == .failed { throw writer.error ?? CaptureError.unavailable("動画の書き出しに失敗しました") }
        } catch { fail(error) }
    }
    private func finish() {
        videoFinished = true; current = nil; next = nil; precedingFrame = nil; heldFastForward = nil
        input.markAsFinished()
        finishIfReady()
    }
    private func finishIfReady() {
        guard videoFinished, audioFinished, !completed else { return }
        completed = true
        writer.endSession(atSourceTime: VideoExportTiming.time(plan.duration))
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
        completed = true; reader.cancelReading(); audioReader?.cancelReading(); writer.cancelWriting()
        current = nil; next = nil; pending = []; precedingFrame = nil; heldFastForward = nil
        try? FileManager.default.removeItem(at: destination)
        continuation?.resume(throwing: error); continuation = nil
    }
    private func retimed(_ sample: CMSampleBuffer, start: Double, duration: Double) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: VideoExportTiming.time(duration),
            presentationTimeStamp: VideoExportTiming.time(start), decodeTimeStamp: .invalid)
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
