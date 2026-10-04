import AppKit
import UtsushieCore

/// プレビューと書き出しで同じ描画を使う。入力は撮影時のCGImageに限定する。
@MainActor
enum AnnotationRenderer {
    static var red: NSColor { UITheme.red }

    static func bitmap(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw WebPError.bitmap }
        return context
    }
    static func textSize(_ text: String, style: AnnotationStyle) -> CGSize {
        let size = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: style.fontSize, weight: .bold)])
        return CGSize(width: ceil(size.width) + style.horizontalPadding * 2, height: ceil(size.height) + style.verticalPadding * 2)
    }
    static func compose(_ original: CGImage, document: AnnotationDocument) throws -> CGImage {
        guard !document.annotations.isEmpty else { return original }
        let width = original.width, height = original.height
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        let style = AnnotationStyle(imageSize: full.size)
        let context = try bitmap(width: width, height: height)
        context.draw(original, in: full)
        if document.annotations.contains(where: { $0.tool == .mosaic }) {
            try drawMosaics(original, document: document, context: context, style: style, full: full)
        }
        let spots = document.annotations.filter { $0.tool == .spotlight }
        if !spots.isEmpty {
            let curtain = try bitmap(width: width, height: height)
            curtain.setFillColor(CGColor(gray: 0, alpha: 0.5)); curtain.fill(full)
            curtain.translateBy(x: 0, y: CGFloat(height)); curtain.scaleBy(x: 1, y: -1)
            curtain.setBlendMode(.clear)
            // 個別にclearすることで穴の和集合になる。even-oddでは重なった穴が暗くなる。
            for spot in spots {
                curtain.addPath(CGPath(roundedRect: spot.rect, cornerWidth: style.radius, cornerHeight: style.radius, transform: nil))
                curtain.fillPath()
            }
            guard let overlay = curtain.makeImage() else { throw WebPError.bitmap }
            context.draw(overlay, in: full)
        }
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for annotation in document.ordered {
            draw(annotation, document: document, style: style, context: context)
        }
        guard let image = context.makeImage() else { throw WebPError.bitmap }
        return image
    }
    private static func drawMosaics(_ original: CGImage, document: AnnotationDocument, context: CGContext, style: AnnotationStyle, full: CGRect) throws {
        let width = original.width, height = original.height
        // CGContextの生バイトは上から並ぶ。各範囲は元画像のブロック平均を使い、重なっても再平均しない。
        let source = try bitmap(width: width, height: height)
        source.draw(original, in: full)
        guard let sourceData = source.data, let destination = context.data else { throw WebPError.bitmap }
        let src = sourceData.assumingMemoryBound(to: UInt8.self)
        let dst = destination.assumingMemoryBound(to: UInt8.self)
        for annotation in document.annotations where annotation.tool == .mosaic {
            let r = annotation.rect.intersection(full).integral.intersection(full)
            guard !r.isNull, !r.isEmpty else { continue }
            for y in stride(from: Int(r.minY), to: Int(r.maxY), by: style.blockSize) {
                for x in stride(from: Int(r.minX), to: Int(r.maxX), by: style.blockSize) {
                    let endX = min(Int(r.maxX), x + style.blockSize), endY = min(Int(r.maxY), y + style.blockSize)
                    var sums = [Int](repeating: 0, count: 4)
                    for py in y..<endY { for px in x..<endX {
                        let offset = (py * width + px) * 4
                        for channel in 0..<4 { sums[channel] += Int(src[offset + channel]) }
                    }}
                    let count = (endX - x) * (endY - y)
                    for py in y..<endY { for px in x..<endX {
                        let offset = (py * width + px) * 4
                        for channel in 0..<4 { dst[offset + channel] = UInt8((sums[channel] + count / 2) / count) }
                    }}
                }
            }
        }
    }
    private static func draw(_ annotation: Annotation, document: AnnotationDocument, style: AnnotationStyle, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        switch annotation.tool {
        case .selection, .mosaic, .spotlight: break
        case .rectangle:
            let path = CGPath(roundedRect: annotation.rect, cornerWidth: style.radius, cornerHeight: style.radius, transform: nil)
            context.addPath(path); context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(style.lineWidth + style.edge * 2); context.strokePath()
            context.addPath(path); context.setStrokeColor(red.cgColor)
            context.setLineWidth(style.lineWidth); context.strokePath()
        case .arrow:
            let a = annotation.start, b = annotation.end
            let angle = atan2(b.y - a.y, b.x - a.x)
            let line = style.lineWidth * 1.5
            let length = max(line * 4, style.fontSize * 0.9)
            let back = CGPoint(x: b.x - cos(angle) * length, y: b.y - sin(angle) * length)
            let head = CGMutablePath()
            head.move(to: b)
            head.addLine(to: CGPoint(x: back.x - sin(angle) * length * 0.45, y: back.y + cos(angle) * length * 0.45))
            head.addLine(to: CGPoint(x: back.x + sin(angle) * length * 0.45, y: back.y - cos(angle) * length * 0.45))
            head.closeSubpath()
            context.setLineCap(.round); context.setLineJoin(.round)
            // 白い下地を先にまとめて描いてから朱を載せ、矢じりの付け根に白線を残さない。
            for outer in [true, false] {
                let color = outer ? NSColor.white.cgColor : red.cgColor
                context.setStrokeColor(color); context.setFillColor(color)
                context.setLineWidth(line + (outer ? style.edge * 2 : 0))
                context.move(to: a); context.addLine(to: back); context.strokePath()
                context.addPath(head)
                if outer { context.setLineWidth(style.edge * 2); context.drawPath(using: .fillStroke) }
                else { context.fillPath() }
            }
        case .text:
            let rect = annotation.rect
            context.setFillColor(UITheme.redFace.cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: style.radius, cornerHeight: style.radius, transform: nil)); context.fillPath()
            (annotation.text as NSString).draw(at: CGPoint(x: rect.minX + style.horizontalPadding, y: rect.minY + style.verticalPadding),
                withAttributes: [.font: NSFont.systemFont(ofSize: style.fontSize, weight: .bold), .foregroundColor: NSColor.white])
        case .number:
            let number = document.number(for: annotation.id) ?? document.nextNumber
            let rect = style.numberRect(at: annotation.start, number: number)
            context.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: CGColor(gray: 0, alpha: 0.35))
            let path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
            // 線はパスの中心に出る。2倍幅の白線の上から元の朱面を塗り、外側へedgeだけ残す。
            context.setFillColor(UITheme.redFace.cgColor); context.setStrokeColor(NSColor.white.cgColor); context.setLineWidth(style.edge * 2)
            context.addPath(path)
            context.drawPath(using: .fillStroke)
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.addPath(path); context.fillPath()
            let string = String(number) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: style.fontSize, weight: .bold), .foregroundColor: NSColor.white]
            let size = string.size(withAttributes: attributes)
            string.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
    }
}
