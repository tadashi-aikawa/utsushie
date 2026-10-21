import AppKit
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

/// 選択画面を出す前に撮った1枚のディスプレイ。画像は左上原点・ディスプレイの倍率のピクセル。
struct FrozenDisplay: Sendable {
    let geometry: DisplayGeometry
    let image: CGImage
}

@MainActor
final class CaptureService {
    /// 選択画面がカーソル下の窓を覆うと、ホバーで出たポップアップが閉じる。覆う前に全画面を撮る。
    func freeze(excluding windows: [NSWindow]) async throws -> [FrozenDisplay] {
        let shareable = try await content()
        let excluded = try CaptureWindowExclusion.excludedWindows(in: shareable, policy: CaptureWindowExclusion.policy(for: windows))
        var frozen: [FrozenDisplay] = []
        for geometry in ScreenGeometry.displays {
            guard let display = shareable.displays.first(where: { $0.displayID == geometry.id }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let size = CaptureGeometry.outputSize(points: geometry.frame.size, scale: geometry.scale, downscale: false)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration(width: size.width, height: size.height))
            frozen.append(FrozenDisplay(geometry: geometry, image: image))
        }
        guard !frozen.isEmpty else { throw CaptureError.unavailable("画面を撮れませんでした") }
        return frozen
    }
    /// 止めた画面から切り出す。ウィンドウは見えているとおりに、手前の窓やポップアップも含めて写す。
    nonisolated static func image(for request: CaptureRequest, downscale: Bool, frozen: [FrozenDisplay]) throws -> CGImage {
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
        return image
    }
    func content() async throws -> SCShareableContent {
        // 非表示の共有カードも列挙し、再表示や合成の遅延でもフィルターで外す。
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }
    func image(for request: CaptureRequest, downscale: Bool, excluding windows: [NSWindow]) async throws -> CGImage {
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
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
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
            return image
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
