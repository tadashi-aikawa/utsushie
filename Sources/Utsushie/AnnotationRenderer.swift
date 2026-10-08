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
        let layout = document.exportLayout(imageSize: full.size)
        // モザイクの生バイト処理は元画像の寸法と行幅のまま行う。
        let source = try bitmap(width: width, height: height)
        source.draw(original, in: full)
        if document.annotations.contains(where: { $0.tool == .mosaic }) {
            try drawMosaics(original, document: document, context: source, style: style, full: full)
        }
        guard let base = source.makeImage() else { throw WebPError.bitmap }
        let context = try bitmap(width: Int(layout.bounds.width), height: Int(layout.bounds.height))
        if layout.bounds != full {
            context.setFillColor(UITheme.paper.cgColor)
            context.fill(CGRect(origin: .zero, size: layout.bounds.size))
        }
        let destination = CGRect(x: -layout.bounds.minX, y: layout.bounds.maxY - full.height, width: full.width, height: full.height)
        context.draw(base, in: destination)
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
            context.draw(overlay, in: destination)
        }
        context.translateBy(x: -layout.bounds.minX, y: layout.bounds.maxY); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        drawMarginBoundary(layout, context: context)
        context.saveGState()
        context.clip(to: full)
        for annotation in document.ordered where annotation.tool == .highlighter {
            draw(annotation, document: document, style: style, context: context)
        }
        context.restoreGState()
        drawSpotFrames(spots, style: style, context: context)
        for annotation in document.ordered where annotation.tool.layer <= AnnotationTool.arrow.layer && annotation.tool != .highlighter {
            draw(annotation, document: document, style: style, context: context)
        }
        // すべての線をすべての札より下へ置く。
        for annotation in document.ordered where [.text, .number].contains(annotation.tool) {
            drawLeader(annotation, document: document, style: style, context: context)
        }
        for annotation in document.ordered where annotation.tool.layer > AnnotationTool.arrow.layer {
            draw(annotation, document: document, style: style, context: context)
        }
        guard let image = context.makeImage() else { throw WebPError.bitmap }
        return image
    }
    private static func drawMarginBoundary(_ layout: AnnotationExportLayout, context: CGContext) {
        context.setFillColor(CGColor(gray: 0, alpha: 0.14))
        let size = layout.imageSize
        if layout.left > 0 { context.fill(CGRect(x: -1, y: 0, width: 1, height: size.height)) }
        if layout.right > 0 { context.fill(CGRect(x: size.width, y: 0, width: 1, height: size.height)) }
        if layout.top > 0 { context.fill(CGRect(x: 0, y: -1, width: size.width, height: 1)) }
        if layout.bottom > 0 { context.fill(CGRect(x: 0, y: size.height, width: size.width, height: 1)) }
    }
    private static func drawSpotFrames(_ spots: [Annotation], style: AnnotationStyle, context: CGContext) {
        guard !spots.isEmpty else { return }
        func union(expansion: Double) -> CGPath {
            spots.reduce(CGMutablePath() as CGPath) { result, spot in
                let radius = min(style.radius, min(spot.rect.width, spot.rect.height) / 2) + expansion
                let path = CGPath(roundedRect: spot.rect.insetBy(dx: -expansion, dy: -expansion), cornerWidth: radius, cornerHeight: radius, transform: nil)
                return result.union(path, using: .winding)
            }
        }
        // 白2px・朱3px・白2pxの帯を穴の外へ作る。和集合の差を塗り、隣の穴に線を残さない。
        let holes = union(expansion: 0)
        context.saveGState()
        context.setFillColor(NSColor.white.cgColor)
        context.addPath(union(expansion: style.lineWidth + style.edge * 2).subtracting(holes, using: .winding)); context.fillPath()
        context.setFillColor(red.cgColor)
        context.addPath(union(expansion: style.edge + style.lineWidth).subtracting(union(expansion: style.edge), using: .winding)); context.fillPath()
        context.restoreGState()
    }
    private static func drawLeader(_ annotation: Annotation, document: AnnotationDocument, style: AnnotationStyle, context: CGContext) {
        guard let segment = document.leaderSegment(for: annotation, style: style) else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        for outer in [true, false] {
            let color = outer ? NSColor.white.cgColor : red.cgColor
            context.setStrokeColor(color); context.setFillColor(color)
            context.setLineWidth(style.lineWidth + (outer ? style.edge * 2 : 0))
            context.move(to: segment.target); context.addLine(to: segment.labelEdge); context.strokePath()
            let radius = style.leaderDotDiameter / 2 + (outer ? style.edge : 0)
            context.fillEllipse(in: CGRect(x: segment.target.x - radius, y: segment.target.y - radius, width: radius * 2, height: radius * 2))
        }
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
        case .highlighter:
            guard let first = annotation.points.first else { return }
            // 太い線の端も元画像内で切る。余白へ蛍光色を描かない。
            context.setLineCap(.round); context.setLineJoin(.round)
            context.setBlendMode(annotation.darkBackground ? .screen : .multiply)
            context.setStrokeColor(UITheme.highlighter(annotation.highlighterColor).cgColor)
            context.setLineWidth(style.highlighterWidth)
            context.move(to: first)
            for point in annotation.points.dropFirst() { context.addLine(to: point) }
            context.strokePath()
        case .line:
            context.setLineCap(.round)
            for outer in [true, false] {
                context.setStrokeColor(outer ? NSColor.white.cgColor : red.cgColor)
                context.setLineWidth(style.lineWidth * 1.5 + (outer ? style.edge * 2 : 0))
                context.move(to: annotation.start); context.addLine(to: annotation.end); context.strokePath()
            }
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
            let path = CGPath(roundedRect: rect, cornerWidth: style.radius, cornerHeight: style.radius, transform: nil)
            context.setStrokeColor(NSColor.white.cgColor); context.setLineWidth(style.edge * 2)
            context.addPath(path); context.drawPath(using: .fillStroke)
            context.addPath(path); context.fillPath()
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
