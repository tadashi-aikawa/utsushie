import AppKit
import ScreenCaptureKit
import AVFoundation
import UtsushieCore

@MainActor
final class RecordingService {
    let request: CaptureRequest
    let displayID: UInt32
    let width: Int
    let height: Int
    private let stream: SCStream
    private let sink: RecordingSink
    private var excludedWindows: [NSWindow]
    private var filteredWindowIDs: Set<UInt32>
    private var exclusionUpdate: Task<Void, Error>?

    static func prepare(request: CaptureRequest, config: VideoConfig, directory: URL,
                        excluding windows: [NSWindow],
                        onStop: @escaping @MainActor @Sendable () -> Void) async throws -> RecordingService {
        let displays = ScreenGeometry.displays
        guard let geometry = VideoGeometry.display(containing: request.rect, displays: displays) else {
            throw CaptureError.unavailable("動画は1つのディスプレイの中で選んでください")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        let policy = CaptureWindowExclusion.policy(for: windows)
        let filter: SCContentFilter
        let points: CGSize
        let scale: Double
        switch request {
        case let .region(rect):
            guard let display = content.displays.first(where: { $0.displayID == geometry.id }) else {
                throw CaptureError.unavailable("選択したディスプレイが見つかりません")
            }
            filter = SCContentFilter(display: display,
                excludingWindows: try CaptureWindowExclusion.excludedWindows(in: content, policy: policy))
            points = rect.size; scale = geometry.scale
        case let .window(id, _):
            guard let window = content.windows.first(where: { $0.windowID == id }),
                  !policy.excludes(windowID: id) else {
                throw CaptureError.unavailable("選択したウィンドウが見つかりません")
            }
            // 独立ウィンドウのフィルターが移動を追う。自アプリの枠/カードは対象外。
            filter = SCContentFilter(desktopIndependentWindow: window)
            points = filter.contentRect.size; scale = Double(filter.pointPixelScale)
        }
        let size = VideoGeometry.size(points: points, scale: scale, downscale: config.downscale)
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = size.width; streamConfig.height = size.height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        streamConfig.showsCursor = config.showsCursor
        streamConfig.capturesAudio = false; streamConfig.captureMicrophone = false
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.colorSpaceName = CGColorSpace.sRGB
        streamConfig.queueDepth = 5
        streamConfig.scalesToFit = true
        streamConfig.ignoreShadowsSingleWindow = true; streamConfig.includeChildWindows = false
        if case let .region(rect) = request { streamConfig.sourceRect = CaptureGeometry.localSource(rect, display: geometry) }
        // 出力寸法は開始時に固定する。ウィンドウの移動/サイズ変更でencoderを作り直さない。
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".utsushie-\(UUID().uuidString).recording.mp4")
        let notify: @Sendable () -> Void = { Task { @MainActor in onStop() } }
        let writer: MP4Writer
        do { writer = try MP4Writer(url: temporaryURL, width: size.width, height: size.height, fps: config.fps, onFailure: notify) }
        catch { try? FileManager.default.removeItem(at: temporaryURL); throw error }
        let sink = RecordingSink(writer: writer, onStop: notify)
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: sink)
        do { try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: writer.queue) }
        catch { await writer.abort(); throw error }
        return RecordingService(request: request, displayID: geometry.id, width: size.width, height: size.height,
                                stream: stream, sink: sink, excludedWindows: windows)
    }
    private init(request: CaptureRequest, displayID: UInt32, width: Int, height: Int, stream: SCStream,
                 sink: RecordingSink, excludedWindows: [NSWindow]) {
        self.request = request; self.displayID = displayID; self.width = width; self.height = height
        self.stream = stream; self.sink = sink
        self.excludedWindows = excludedWindows
        self.filteredWindowIDs = CaptureWindowExclusion.policy(for: excludedWindows).excludedWindowIDs
    }
    /// 編集の完了などで録画中に増えるカードは、フィルターへの追加完了後に表示する。
    func excludeBeforeShowing(_ window: NSWindow) async throws {
        guard case .region = request else { return }
        if let id = UInt32(exactly: window.windowNumber), filteredWindowIDs.contains(id) { return }
        if !excludedWindows.contains(where: { $0 === window }) { excludedWindows.append(window) }
        let previous = exclusionUpdate
        let update = Task { @MainActor in
            // 同時に複数のカードが増えても、古いフィルターが最後に適用されないよう直列化する。
            try await previous?.value
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let policy = CaptureWindowExclusion.policy(for: excludedWindows)
            let excluded = try CaptureWindowExclusion.excludedWindows(in: content, policy: policy)
            guard excluded.contains(where: { $0.windowID == UInt32(exactly: window.windowNumber) }),
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.unavailable("共有カードを録画の対象から外せませんでした")
            }
            try await stream.updateContentFilter(SCContentFilter(display: display, excludingWindows: excluded))
            filteredWindowIDs = Set(excluded.map(\.windowID))
        }
        exclusionUpdate = update
        try await update.value
    }
    func start() async throws {
        do { try await stream.startCapture() }
        catch { await sink.writer.abort(); throw error }
    }
    func stop() async {
        _ = try? await exclusionUpdate?.value
        // 対象消失後のstopCaptureはエラーでもよい。書き込みキューに残った正常フレームを保存する。
        try? await stream.stopCapture()
    }
    func abort() async { await stop(); await sink.writer.abort() }
    func firstFrame() async -> CGImage? { await sink.writer.firstFrame() }
    func finish(hostTime: Double) async throws -> RecordedVideo { try await sink.writer.finish(hostTime: hostTime) }
}
