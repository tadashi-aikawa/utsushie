import AppKit
import OSLog
import ScreenCaptureKit
import UtsushieCore

enum CaptureError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case let .unavailable(message) = self { return message }; return nil }
}

enum CaptureRequest {
    case region(CGRect)
    case window(CGWindowID, CGRect)
    var rect: CGRect {
        switch self { case let .region(rect), let .window(_, rect): return rect }
    }
}

/// 撮った画像と、実際に使った1ptあたりの画素数。注釈の大きさはこの倍率で決める。
struct CapturedImage: Sendable {
    let image: CGImage
    let scale: Double
}

/// 選択画面を出す前に撮った1枚のディスプレイ。画像は左上原点・ディスプレイの倍率のピクセル。
struct FrozenDisplay: Sendable {
    let geometry: DisplayGeometry
    let image: CGImage
}

@MainActor
final class CaptureService {
    static let log = Logger(subsystem: "com.tadashi-aikawa.utsushie", category: "Capture")
    private var prefetched: SCShareableContent?
    private var prefetchTask: Task<Void, Never>?
    /// 選択画面がカーソル下の窓を覆うと、ホバーで出たポップアップが閉じる。覆う前に全画面を撮る。
    func freeze(excluding windows: [NSWindow]) async throws -> [FrozenDisplay] {
        let start = ContinuousClock.now
        let policy = CaptureWindowExclusion.policy(for: windows)
        let geometries = ScreenGeometry.displays
        let shareable = try await freezeContent(policy: policy, displays: geometries)
        Self.log.debug("freeze content: elapsed=\(start.duration(to: .now), privacy: .public)")
        // 一覧を待つ間にディスプレイが変わったら、一部の画面だけ止めた選択画面にしない。呼び出し側は今の画面で開く。
        guard ScreenGeometry.displays == geometries else { throw CaptureError.unavailable("ディスプレイの構成が変わりました") }
        let excluded = try CaptureWindowExclusion.excludedWindows(in: shareable, policy: policy)
        let requests = try geometries.map { geometry -> (DisplayGeometry, SCContentFilter, SCStreamConfiguration) in
            guard let display = shareable.displays.first(where: { $0.displayID == geometry.id }) else {
                throw CaptureError.unavailable("ディスプレイが見つかりません")
            }
            let size = CaptureGeometry.outputSize(points: geometry.frame.size, scale: geometry.scale, downscale: false)
            return (geometry, SCContentFilter(display: display, excludingWindows: excluded), configuration(width: size.width, height: size.height))
        }
        // ディスプレイごとの撮影は独立している。順に待たず同時に撮る。
        // SCKのフィルターと設定はSendableでないため、子タスクへ渡さずメインアクターのTaskで走らせる。
        let tasks = requests.map { geometry, filter, config in
            Task {
                try Task.checkCancellation()
                return FrozenDisplay(geometry: geometry, image: try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config))
            }
        }
        var frozen: [FrozenDisplay] = []
        do {
            for task in tasks { frozen.append(try await task.value) }
        } catch {
            // 1枚でも失敗したら残りを取り消し、終わるのを待ってから返す。次の撮影と重ねない。
            tasks.forEach { $0.cancel() }
            for task in tasks { _ = try? await task.value }
            throw error
        }
        Self.log.debug("freeze displays: elapsed=\(start.duration(to: .now), privacy: .public)")
        guard !frozen.isEmpty else { throw CaptureError.unavailable("画面を撮れませんでした") }
        return frozen
    }
    /// 窓の一覧は取得に約50msかかる。選択画面を開く前に取っておき、ホットキーからの待ちから外す。
    func prefetch() {
        // 画面収録の許可の確認は撮影操作のときに出す。起動時の先読みで許可を求めない。
        guard CGPreflightScreenCaptureAccess() else { return }
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                  !Task.isCancelled else { return }
            self?.prefetched = content
        }
    }
    private func freezeContent(policy: CaptureWindowPolicy, displays: [DisplayGeometry]) async throws -> SCShareableContent {
        // 先読みの後に出たカードやディスプレイの変化があれば、写り込みを避けて取り直す。
        if let prefetched, policy.canReuse(listedWindowIDs: Set(prefetched.windows.map(\.windowID))),
           displays.allSatisfy({ geometry in prefetched.displays.contains {
               $0.displayID == geometry.id && Double($0.width) == geometry.frame.width && Double($0.height) == geometry.frame.height } }) {
            return prefetched
        }
        let fresh = try await content()
        prefetched = fresh
        return fresh
    }
    /// 止めた画面から切り出す。ウィンドウは見えているとおりに、手前の窓やポップアップも含めて写す。
    nonisolated static func image(for request: CaptureRequest, downscale: Bool, frozen: [FrozenDisplay]) throws -> CapturedImage {
        let displays = frozen.map(\.geometry)
        let rect: CGRect
        switch request {
        case let .window(_, frame):
            guard let visible = CaptureGeometry.visibleBounds(frame, displays: displays) else { throw CaptureError.unavailable("選んだウィンドウが画面外です") }
            rect = visible
        case let .region(region):
            guard CaptureGeometry.isVisible(region, displays: displays) else { throw CaptureError.unavailable("範囲が画面外です。選び直してください") }
            rect = region
        }
        let scale = CaptureGeometry.scale(for: rect, displays: displays, downscale: downscale)
        let size = CaptureGeometry.outputSize(points: rect.size, scale: scale, downscale: false)
        guard let canvas = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw WebPError.bitmap }
        canvas.setFillColor(CGColor(gray: 0, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        canvas.interpolationQuality = .high
        for display in frozen {
            let part = rect.intersection(display.geometry.frame)
            guard !part.isNull, part.width > 0, part.height > 0,
                  let piece = display.image.cropping(to: CaptureGeometry.pixelSource(part, display: display.geometry)) else { continue }
            canvas.draw(piece, in: CGRect(x: (part.minX - rect.minX) * scale, y: (part.minY - rect.minY) * scale,
                width: part.width * scale, height: part.height * scale))
        }
        guard let image = canvas.makeImage() else { throw WebPError.bitmap }
        return CapturedImage(image: image, scale: scale)
    }
    func content() async throws -> SCShareableContent {
        // 非表示の共有カードも列挙し、再表示や合成の遅延でもフィルターで外す。
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }
    func image(for request: CaptureRequest, downscale: Bool, excluding windows: [NSWindow]) async throws -> CapturedImage {
        let shareable = try await content()
        let policy = CaptureWindowExclusion.policy(for: windows)
        switch request {
        case let .window(id, _):
            guard let window = shareable.windows.first(where: { $0.windowID == id }),
                  !policy.excludes(windowID: id) else {
                throw CaptureError.unavailable("選んだウィンドウが見つかりません")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = downscale ? 1 : Double(filter.pointPixelScale)
            let dimensions = CaptureGeometry.outputSize(points: filter.contentRect.size, scale: scale, downscale: downscale)
            let configuration = configuration(width: dimensions.width, height: dimensions.height)
            configuration.ignoreShadowsSingleWindow = true
            configuration.includeChildWindows = false
            return CapturedImage(image: try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration), scale: scale)
        case let .region(rect):
            let displays = ScreenGeometry.displays
            guard CaptureGeometry.isVisible(rect, displays: displays) else { throw CaptureError.unavailable("範囲が画面外です。選び直してください") }
            let scale = CaptureGeometry.scale(for: rect, displays: displays, downscale: downscale)
            let size = CaptureGeometry.outputSize(points: rect.size, scale: scale, downscale: false)
            guard let canvas = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw WebPError.bitmap }
            canvas.setFillColor(CGColor(gray: 0, alpha: 1))
            canvas.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
            let excluded = try CaptureWindowExclusion.excludedWindows(in: shareable, policy: policy)
            // 隠すタイミングだけに頼らず、撮影用UIを窓単位のフィルターで除外する。
            for geometry in displays {
                let part = rect.intersection(geometry.frame)
                guard !part.isNull, part.width > 0, part.height > 0,
                      let display = shareable.displays.first(where: { $0.displayID == geometry.id }) else { continue }
                let filter = SCContentFilter(display: display, excludingWindows: excluded)
                let partSize = CaptureGeometry.outputSize(points: part.size, scale: scale, downscale: false)
                let config = configuration(width: partSize.width, height: partSize.height)
                config.sourceRect = CaptureGeometry.localSource(part, display: geometry)
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                canvas.draw(image, in: CGRect(x: (part.minX - rect.minX) * scale, y: (part.minY - rect.minY) * scale,
                    width: part.width * scale, height: part.height * scale))
            }
            guard let image = canvas.makeImage() else { throw WebPError.bitmap }
            return CapturedImage(image: image, scale: scale)
        }
    }
    private func configuration(width: Int, height: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width; config.height = height
        config.showsCursor = false
        config.scalesToFit = true
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }
}
