import AppKit
import ScreenCaptureKit
import UtsushieCore

/// 範囲を流し続け、利用者がスクロールした分を縦長の1枚へつなぐ。録画と同じく撮影用UIはウィンドウ番号で除外する。
@MainActor
final class ScrollCaptureService {
    let displayID: UInt32
    let width: Int
    /// 1ptあたりの画素数。注釈の大きさに使う。
    let pixelScale: Double
    private let stream: SCStream
    private let sink: ScrollCaptureSink

    /// 進み具合をメインスレッドへ知らせる。上限に届いたら`reachedLimit`がtrue。
    struct Progress: Equatable { var height: Int; var lost: Bool; var reachedLimit: Bool }

    static func prepare(rect: CGRect, downscale: Bool, excluding windows: [NSWindow],
                        onProgress: @escaping @MainActor @Sendable (Progress) -> Void,
                        onStop: @escaping @MainActor @Sendable () -> Void) async throws -> ScrollCaptureService {
        guard let geometry = VideoGeometry.display(containing: rect, displays: ScreenGeometry.displays) else {
            throw CaptureError.unavailable("スクロール撮影は1つのディスプレイの中で選んでください")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == geometry.id }) else {
            throw CaptureError.unavailable("選択したディスプレイが見つかりません")
        }
        let policy = CaptureWindowExclusion.policy(for: windows)
        let excludedWindows = try excluded(in: content, policy: policy)
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let scale = downscale ? 1 : geometry.scale
        let size = CaptureGeometry.outputSize(points: rect.size, scale: geometry.scale, downscale: downscale)
        let config = SCStreamConfiguration()
        config.width = size.width; config.height = size.height
        config.sourceRect = CaptureGeometry.localSource(rect, display: geometry)
        config.scalesToFit = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 5
        // スクロール中だけ出るスクロールバーは照合から外す。画像にはそのまま写す。
        let excluded = min(size.width - 1, Int((16 * scale).rounded()))
        let sink = ScrollCaptureSink(width: size.width, height: size.height, excludedRight: excluded,
            onProgress: { progress in Task { @MainActor in onProgress(progress) } },
            onStop: { Task { @MainActor in onStop() } })
        let stream = SCStream(filter: filter, configuration: config, delegate: sink)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        return ScrollCaptureService(displayID: geometry.id, width: size.width, pixelScale: scale, stream: stream, sink: sink,
            policy: policy, excludedIDs: Set(excludedWindows.map(\.windowID)))
    }
    private init(displayID: UInt32, width: Int, pixelScale: Double, stream: SCStream, sink: ScrollCaptureSink,
                 policy: CaptureWindowPolicy, excludedIDs: Set<UInt32>) {
        self.displayID = displayID; self.width = width; self.pixelScale = pixelScale; self.stream = stream; self.sink = sink
        self.policy = policy; self.excludedIDs = excludedIDs
    }
    private let policy: CaptureWindowPolicy
    private var excludedIDs: Set<UInt32>
    private var refreshTask: Task<Void, Never>?

    /// 撮影用UIに加えて、スクロールしても動かず継ぎ目ごとに写り込むほかのウィンドウを外す。
    /// - Dock: 自動非表示のDockが範囲の下端に出る
    /// - 付属ウィンドウ: ChromeのURLの吹き出しやツールチップ。`CaptureWindowPolicy.scrollOverlayIDs`
    /// `strict`がfalseなら、一覧から消えた撮影用UIを許す。
    /// 理由: 撮り始めた後に範囲選択のパネルは閉じて一覧から消えるので、取り直しのたびに失敗し、吹き出しを外せなくなるため。
    private static func excluded(in content: SCShareableContent, policy: CaptureWindowPolicy, strict: Bool = true) throws -> [SCWindow] {
        let dockLayer = Int(CGWindowLevelForKey(.dockWindow))
        let overlays = CaptureWindowPolicy.scrollOverlayIDs(content.windows.map {
            ListedWindow(id: $0.windowID, processID: $0.owningApplication?.processID, layer: $0.windowLayer, frame: $0.frame)
        }, ownProcessID: policy.ownProcessID)
        let others = content.windows.filter {
            !policy.excludes(windowID: $0.windowID) && (overlays.contains($0.windowID)
                || CaptureWindowPolicy.isDock(bundleIdentifier: $0.owningApplication?.bundleIdentifier, layer: $0.windowLayer, dockLayer: dockLayer))
        }
        let captureUI = strict ? try CaptureWindowExclusion.excludedWindows(in: content, policy: policy)
            : content.windows.filter { policy.excludes(windowID: $0.windowID) }
        return captureUI + others
    }

    func start() async throws {
        try await stream.startCapture()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                if self.hasNewOverlay() { await self.refreshExclusions() }
            }
        }
    }
    /// 撮っている間に出た吹き出しを、0.1秒おきにCGのウィンドウ一覧で見つける。
    /// 理由: Chromeの吹き出しのウィンドウはリンクへカーソルを乗せるたびに作られ、開始時の一覧に載らないため。
    ///     SCKの一覧は取得に約50msかかるので、新しい吹き出しを見つけたときだけ取り直す。
    private func hasNewOverlay() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = list.compactMap { item -> ListedWindow? in
            guard let id = item[kCGWindowNumber as String] as? UInt32, let layer = item[kCGWindowLayer as String] as? Int,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return ListedWindow(id: id, processID: item[kCGWindowOwnerPID as String] as? Int32, layer: layer, frame: frame)
        }
        return !CaptureWindowPolicy.scrollOverlayIDs(windows, ownProcessID: policy.ownProcessID).isSubset(of: excludedIDs)
    }
    private func refreshExclusions() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              !Task.isCancelled,
              let display = content.displays.first(where: { $0.displayID == displayID }),
              let windows = try? Self.excluded(in: content, policy: policy, strict: false) else { return }
        let ids = Set(windows.map(\.windowID))
        guard !ids.isSubset(of: excludedIDs) else { return }
        do {
            try await stream.updateContentFilter(SCContentFilter(display: display, excludingWindows: windows))
            excludedIDs = ids
        } catch {
            CaptureService.log.error("scroll exclusion update failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    func stop() async {
        refreshTask?.cancel(); refreshTask = nil
        try? await stream.stopCapture()
    }
    /// つないだ画像。1コマも届いていなければnil。
    func finish() async -> (image: CGImage, reachedLimit: Bool)? { await sink.finish() }
}

/// 専用キューでコマを受け、照合と画素の写しを行う。可変状態はこのキューだけで触る。
final class ScrollCaptureSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.tadashi-aikawa.utsushie.scroll")
    private let width: Int
    private let height: Int
    private let matchWidth: Int
    private let columns: Int
    private var stitcher = ScrollStitcher()
    private var canvas: ScrollCanvas
    private var frames = 0
    private var last: ScrollCaptureService.Progress?
    private let onProgress: @Sendable (ScrollCaptureService.Progress) -> Void
    private let onStop: @Sendable () -> Void

    init(width: Int, height: Int, excludedRight: Int, onProgress: @escaping @Sendable (ScrollCaptureService.Progress) -> Void,
         onStop: @escaping @Sendable () -> Void) {
        self.width = width; self.height = height
        matchWidth = max(1, width - excludedRight)
        columns = min(160, matchWidth)
        canvas = ScrollCanvas(rowBytes: width * 4)
        self.onProgress = onProgress; self.onStop = onStop
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stitcher.reachedLimit,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        process(buffer)
    }
    /// 1コマを照合してつなぐ。`queue`の上で呼ぶ。
    func process(_ buffer: CVPixelBuffer) {
        guard !stitcher.reachedLimit, CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = UnsafeRawBufferPointer(start: base, count: stride * height)
        let step = stitcher.add(luma(pixels, stride: stride))
        canvas.add(pixels, stride: stride, step: step)
        frames += 1
        let progress = ScrollCaptureService.Progress(height: stitcher.outputHeight, lost: stitcher.lost, reachedLimit: stitcher.reachedLimit)
        if progress != last { last = progress; onProgress(progress) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop() }

    /// 照合用に、右端を除いた列を`columns`個へ平均し、行はそのまま持つ。
    private func luma(_ pixels: UnsafeRawBufferPointer, stride: Int) -> ScrollLuma {
        var values = [UInt8](repeating: 0, count: columns * height)
        let bytes = pixels.bindMemory(to: UInt8.self)
        values.withUnsafeMutableBufferPointer { values in
            for row in 0..<height {
                let offset = row * stride
                for column in 0..<columns {
                    let start = column * matchWidth / columns
                    let end = max(start + 1, (column + 1) * matchWidth / columns)
                    var total = 0, count = 0
                    var x = start
                    while x < end {
                        let pixel = offset + x * 4
                        // BGRA。
                        total += (Int(bytes[pixel + 2]) * 77 + Int(bytes[pixel + 1]) * 150 + Int(bytes[pixel]) * 29) >> 8
                        count += 1
                        x += 1
                    }
                    values[row * columns + column] = UInt8(total / count)
                }
            }
        }
        return ScrollLuma(width: columns, height: height, values: values)
    }

    func finish() async -> (image: CGImage, reachedLimit: Bool)? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard frames > 0 else { continuation.resume(returning: nil); return }
                let bytes = canvas.output(still: stitcher.isStill)
                let rows = bytes.count / (width * 4)
                let image = CFDataCreate(nil, bytes, bytes.count).flatMap { CGDataProvider(data: $0) }.flatMap { provider in
                    CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
                }
                continuation.resume(returning: image.map { ($0, stitcher.reachedLimit) })
            }
        }
    }
}
