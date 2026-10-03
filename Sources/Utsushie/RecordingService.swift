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

    static func prepare(request: CaptureRequest, config: VideoConfig, directory: URL,
                        onStop: @escaping @MainActor @Sendable () -> Void) async throws -> RecordingService {
        let displays = ScreenGeometry.displays
        guard let geometry = VideoGeometry.display(containing: request.rect, displays: displays) else {
            throw CaptureError.unavailable("動画は1つのディスプレイの中で選んでください")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let filter: SCContentFilter
        let points: CGSize
        let scale: Double
        switch request {
        case let .region(rect):
            guard let display = content.displays.first(where: { $0.displayID == geometry.id }) else {
                throw CaptureError.unavailable("選択したディスプレイが見つかりません")
            }
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            points = rect.size; scale = geometry.scale
        case let .window(id, _):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
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
        return RecordingService(request: request, displayID: geometry.id, width: size.width, height: size.height, stream: stream, sink: sink)
    }
    private init(request: CaptureRequest, displayID: UInt32, width: Int, height: Int, stream: SCStream, sink: RecordingSink) {
        self.request = request; self.displayID = displayID; self.width = width; self.height = height
        self.stream = stream; self.sink = sink
    }
    func start() async throws {
        do { try await stream.startCapture() }
        catch { await sink.writer.abort(); throw error }
    }
    func stop() async {
        // 対象消失後のstopCaptureはエラーでもよい。書き込みキューに残った正常フレームを保存する。
        try? await stream.stopCapture()
    }
    func abort() async { try? await stream.stopCapture(); await sink.writer.abort() }
    func firstFrame() async -> CGImage? { await sink.writer.firstFrame() }
    func finish(hostTime: Double) async throws -> RecordedVideo { try await sink.writer.finish(hostTime: hostTime) }
}
