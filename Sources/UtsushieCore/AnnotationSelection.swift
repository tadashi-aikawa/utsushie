import Foundation
import CoreGraphics

extension AnnotationDocument {
    public mutating func remove(_ ids: Set<UUID>) { annotations.removeAll { ids.contains($0.id) } }

    /// 色が混在していても、ドキュメント順で最初の対象を基準にする。
    public func cycledInkColor(_ ids: Set<UUID>, direction: ColorCycleDirection, defaultColor: InkColor) -> InkColor {
        let first = annotations.first { ids.contains($0.id) && $0.tool.usesInkColor }
        return (first?.inkColor ?? defaultColor).cycled(direction)
    }

    public func cycledHighlighterColor(_ ids: Set<UUID>, direction: ColorCycleDirection, defaultColor: HighlighterColor) -> HighlighterColor {
        let first = annotations.first { ids.contains($0.id) && $0.tool == .highlighter }
        return (first?.highlighterColor ?? defaultColor).cycled(direction)
    }

    public func settingInk(_ ids: Set<UUID>, color: InkColor) -> AnnotationDocument {
        var result = self
        for index in result.annotations.indices where ids.contains(result.annotations[index].id) && result.annotations[index].tool.usesInkColor {
            result.annotations[index].inkColor = color
        }
        return result
    }

    /// 混在する選択でも、蛍光ペン以外の注釈と指定しない軸は保つ。
    public func settingHighlighter(_ ids: Set<UUID>, color: HighlighterColor? = nil, darkBackground: Bool? = nil) -> AnnotationDocument {
        var result = self
        for index in result.annotations.indices where ids.contains(result.annotations[index].id) && result.annotations[index].tool == .highlighter {
            if let color { result.annotations[index].highlighterColor = color }
            if let darkBackground { result.annotations[index].darkBackground = darkBackground }
        }
        return result
    }

    /// 選択は包含でなく交差。細い線は外接矩形の空白部分を選ばない。
    public func intersecting(_ rect: CGRect, style: AnnotationStyle) -> Set<UUID> {
        Set(annotations.filter { annotation in
            let style = style.forAnnotation(annotation)
            if let leader = leaderSegment(for: annotation, style: style),
               AnnotationGeometry.segmentIntersects(rect.insetBy(dx: -style.lineWidth / 2 - style.edge,
                                                                dy: -style.lineWidth / 2 - style.edge),
                                                    from: leader.target, to: leader.labelEdge) { return true }
            if [.line, .arrow, .highlighter].contains(annotation.tool) {
                let points = annotation.tool == .highlighter ? annotation.points : [annotation.start, annotation.end]
                let radius = annotation.tool == .highlighter ? style.highlighterWidth / 2 : style.lineWidth * 0.75 + style.edge
                if zip(points, points.dropFirst()).contains(where: {
                    AnnotationGeometry.segmentIntersects(rect.insetBy(dx: -radius, dy: -radius), from: $0, to: $1)
                }) { return true }
                if annotation.tool == .arrow {
                    let head = AnnotationGeometry.arrowHead(annotation, style: style)
                    let selection = CGPath(rect: rect, transform: nil)
                    return !head.intersection(selection, using: .winding).isEmpty
                }
                return false
            }
            return AnnotationGeometry.inkBounds(of: annotation, bounds: bounds(of: annotation, style: style), style: style).intersects(rect)
        }.map(\.id))
    }

    /// 全体へ同じ移動量を適用し、画像内に留める道具との相対位置も保つ。
    public func moving(_ ids: Set<UUID>, by delta: CGPoint, imageSize: CGSize) -> AnnotationDocument {
        let style = self.style(imageSize: imageSize)
        var movement = delta
        for annotation in annotations where ids.contains(annotation.id) {
            let proposed = annotation.translated(by: delta)
            let placed = AnnotationGeometry.placed(proposed, bounds: bounds(of: proposed, style: style), imageSize: imageSize, basis: styleBasis)
            let allowed = CGPoint(x: placed.start.x - annotation.start.x, y: placed.start.y - annotation.start.y)
            if delta.x > 0 { movement.x = min(movement.x, max(0, allowed.x)) }
            if delta.x < 0 { movement.x = max(movement.x, min(0, allowed.x)) }
            if delta.y > 0 { movement.y = min(movement.y, max(0, allowed.y)) }
            if delta.y < 0 { movement.y = max(movement.y, min(0, allowed.y)) }
        }
        // トリミングで画像より大きくなった蛍光ペンは、外接矩形が重なっても線が画像から外れ得る。
        movement = AnnotationGeometry.visibleHighlighterMovement(movement, highlighters: annotations.filter { ids.contains($0.id) },
                                                                 image: CGRect(origin: .zero, size: imageSize), style: style)
        var result = self
        result.annotations = annotations.map { annotation in
            guard ids.contains(annotation.id) else { return annotation }
            let moved = annotation.translated(by: movement)
            return AnnotationGeometry.placed(moved, bounds: bounds(of: moved, style: style), imageSize: imageSize, basis: styleBasis)
        }
        return result
    }
}

extension AnnotationGeometry {
    public static func axisConstrained(_ delta: CGPoint) -> CGPoint {
        abs(delta.x) >= abs(delta.y) ? CGPoint(x: delta.x, y: 0) : CGPoint(x: 0, y: delta.y)
    }

    /// 同値は水平。軸を決めてから画像内へ制限し、端でも直線を保つ。
    public static func highlighterEndpoint(_ point: CGPoint, from anchor: CGPoint, imageSize: CGSize) -> CGPoint {
        let delta = axisConstrained(CGPoint(x: point.x - anchor.x, y: point.y - anchor.y))
        return clamped(CGPoint(x: anchor.x + delta.x, y: anchor.y + delta.y), to: imageSize)
    }

    public static func angleConstrained(_ point: CGPoint, from anchor: CGPoint) -> CGPoint {
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: anchor.x + cos(angle) * length, y: anchor.y + sin(angle) * length)
    }

    public static func squareConstrained(_ point: CGPoint, from anchor: CGPoint, imageSize: CGSize? = nil) -> CGPoint {
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        var length = max(abs(dx), abs(dy))
        if let imageSize {
            length = min(length, dx < 0 ? anchor.x : imageSize.width - anchor.x,
                         dy < 0 ? anchor.y : imageSize.height - anchor.y)
        }
        return CGPoint(x: anchor.x + (dx < 0 ? -length : length), y: anchor.y + (dy < 0 ? -length : length))
    }

    public static func creationPoint(_ point: CGPoint, from anchor: CGPoint, tool: AnnotationTool,
                                     shift: Bool, imageSize: CGSize, size: AnnotationSize = .normal, basis: Double? = nil) -> CGPoint {
        if [.rectangle, .spotlight].contains(tool) {
            return creating(Annotation(tool: tool, start: anchor, size: size), to: point, shift: shift, imageSize: imageSize, basis: basis).end
        }
        if tool == .highlighter && shift { return highlighterEndpoint(point, from: anchor, imageSize: imageSize) }
        let point = tool.allowsMargin ? point : clamped(point, to: imageSize)
        guard shift else { return point }
        if [.arrow, .line].contains(tool) { return angleConstrained(point, from: anchor) }
        if [.rectangle, .spotlight, .mosaic].contains(tool) {
            return squareEndpoint(point, from: anchor, tool: tool, imageSize: imageSize)
        }
        return point
    }

    public static func resized(_ annotation: Annotation, handle: AnnotationResizeHandle, to point: CGPoint,
                               shift: Bool, imageSize: CGSize, basis: Double? = nil) -> Annotation {
        if [.rectangle, .spotlight].contains(annotation.tool) {
            var result = resized(annotation, handle: handle, to: point)
            let corner = [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(handle)
            if shift && corner { result.end = squareConstrained(point, from: result.start) }
            return clampingAreaPoints(result, square: shift && corner, imageSize: imageSize, basis: basis)
        }
        var point = handle == .leaderTarget || !annotation.tool.allowsMargin ? clamped(point, to: imageSize) : point
        if shift {
            switch handle {
            case .arrowStart: point = angleConstrained(point, from: annotation.end)
            case .arrowEnd: point = angleConstrained(point, from: annotation.start)
            case .topLeft, .topRight, .bottomRight, .bottomLeft:
                let anchor = resized(annotation, handle: handle, to: point).start
                point = squareEndpoint(point, from: anchor, tool: annotation.tool, imageSize: imageSize)
            default: break
            }
        }
        return resized(annotation, handle: handle, to: point)
    }

    private static func squareEndpoint(_ point: CGPoint, from anchor: CGPoint, tool: AnnotationTool, imageSize: CGSize) -> CGPoint {
        let endpoint = squareConstrained(point, from: anchor, imageSize: tool.allowsMargin ? nil : imageSize)
        return endpoint
    }

    public static func segmentIntersects(_ rect: CGRect, from a: CGPoint, to b: CGPoint) -> Bool {
        var lower = 0.0, upper = 1.0
        for (start, delta, minimum, maximum) in [(a.x, b.x - a.x, rect.minX, rect.maxX),
                                                (a.y, b.y - a.y, rect.minY, rect.maxY)] {
            if abs(delta) < 1e-12 {
                if start < minimum || start > maximum { return false }
            } else {
                let t1 = (minimum - start) / delta, t2 = (maximum - start) / delta
                lower = max(lower, min(t1, t2)); upper = min(upper, max(t1, t2))
                if lower > upper { return false }
            }
        }
        return true
    }

    static func arrowHead(_ annotation: Annotation, style: AnnotationStyle) -> CGPath {
        let style = style.forAnnotation(annotation)
        let a = annotation.start, b = annotation.end
        let angle = atan2(b.y - a.y, b.x - a.x)
        let length = max(style.lineWidth * 6, style.fontSize * 0.9)
        let back = CGPoint(x: b.x - cos(angle) * length, y: b.y - sin(angle) * length)
        let path = CGMutablePath()
        path.move(to: b)
        path.addLine(to: CGPoint(x: back.x - sin(angle) * length * 0.45, y: back.y + cos(angle) * length * 0.45))
        path.addLine(to: CGPoint(x: back.x + sin(angle) * length * 0.45, y: back.y - cos(angle) * length * 0.45))
        path.closeSubpath()
        return path
    }
}
