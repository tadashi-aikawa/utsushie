import CoreImage
import CoreText
import CoreMedia
import UtsushieCore

/// 書き出しキューからだけ操作する。描画済みコマを貯めず、Writerへ渡す直前に1枚ずつ作る。
final class VideoTransitionRenderer {
    let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private let pool: CVPixelBufferPool
    private let bounds: CGRect
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var badge: (Int, CIImage)?
    init(width: Int, height: Int) throws {
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            throw CaptureError.unavailable("つなぎの描画領域を作れません")
        }
        self.pool = pool
    }
    func fastForward(_ sample: CMSampleBuffer, speed: Int, start: Double, duration: Double) throws -> CMSampleBuffer {
        guard let pixels = sample.imageBuffer else { throw CaptureError.unavailable("早送りのコマを読めません") }
        if badge?.0 != speed {
            let image = try VideoFastForwardBadge.image(width: Int(bounds.width), height: Int(bounds.height), speed: speed)
            badge = (speed, CIImage(cgImage: image))
        }
        return try rendered(badge!.1.composited(over: CIImage(cvPixelBuffer: pixels)), start: start, duration: duration, reference: pixels)
    }
    func rendered(_ image: CIImage, start: Double, duration: Double, reference: CVPixelBuffer? = nil) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixels) == kCVReturnSuccess, let pixels else {
            throw CaptureError.unavailable("つなぎのコマを作れません")
        }
        // Readerの709転送特性をsRGBへ変えてからWriterへ渡すと、演出部分だけ明るくなる。
        let outputColorSpace = reference.flatMap { CVImageBufferGetColorSpace($0)?.takeUnretainedValue() } ?? colorSpace
        context.render(image, to: pixels, bounds: bounds, colorSpace: outputColorSpace)
        if let reference { CVBufferPropagateAttachments(reference, pixels) }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format) == noErr,
              let format else { throw CaptureError.unavailable("つなぎの形式を作れません") }
        var timing = CMSampleTimingInfo(duration: VideoExportTiming.time(duration),
            presentationTimeStamp: VideoExportTiming.time(start), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else {
            throw CaptureError.unavailable("つなぎのサンプルを作れません")
        }
        return sample
    }
    func transition(before: CMSampleBuffer, after: CMSampleBuffer, kind: VideoTransitionKind,
                    progress: Double, start: Double, duration: Double) throws -> CMSampleBuffer {
        guard let preceding = before.imageBuffer, let following = after.imageBuffer else {
            throw CaptureError.unavailable("つなぎの両端のコマを読めません")
        }
        if kind == .dissolve {
            let image = CIImage(cvPixelBuffer: preceding).applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: CIImage(cvPixelBuffer: following), kCIInputTimeKey: progress])
            return try rendered(image, start: start, duration: duration, reference: preceding)
        }
        let firstHalf = progress < 0.5
        let pixels = firstHalf ? preceding : following
        let brightness = firstHalf ? 1 - progress * 2 : (progress - 0.5) * 2
        let image = CIImage(cvPixelBuffer: pixels).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: brightness, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: brightness, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: brightness, w: 0)])
        return try rendered(image, start: start, duration: duration, reference: pixels)
    }
}

enum VideoExportTiming {
    static func time(_ seconds: Double) -> CMTime { CMTime(value: Int64((seconds * 60000).rounded()), timescale: 60000) }
}

enum VideoFastForwardBadge {
    /// モックの1280px基準: 右26px、上84px、高さ48px、角丸12px。文字は長辺の2.2%。
    static func rect(width: Int, height: Int, speed: Int) -> CGRect {
        let scale = CGFloat(max(width, height)) / 1280
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(max(width, height)) * 0.022, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "×\(speed)", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font]))
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let w = textWidth + 60 * scale
        return CGRect(x: CGFloat(width) - 26 * scale - w, y: CGFloat(height) - 132 * scale, width: w, height: 48 * scale)
    }
    static func image(width: Int, height: Int, speed: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.unavailable("早送りの印を作れません")
        }
        let scale = CGFloat(max(width, height)) / 1280
        let rect = rect(width: width, height: height, speed: speed)
        context.setFillColor(CGColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.82))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil)); context.fillPath()
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.28)); context.setLineWidth(1.5 * scale)
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.75 * scale, dy: 0.75 * scale),
            cornerWidth: 11.3 * scale, cornerHeight: 11.3 * scale, transform: nil)); context.strokePath()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for offset: CGFloat in [16, 29] {
            context.move(to: CGPoint(x: rect.minX + offset * scale, y: rect.midY - 10 * scale))
            context.addLine(to: CGPoint(x: rect.minX + (offset + 11) * scale, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.minX + offset * scale, y: rect.midY + 10 * scale))
            context.closePath(); context.fillPath()
        }
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(max(width, height)) * 0.022, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "×\(speed)", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.textPosition = CGPoint(x: rect.minX + 52 * scale, y: rect.midY - (ascent - descent) / 2)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { throw CaptureError.unavailable("早送りの印を描けません") }
        return image
    }
}
