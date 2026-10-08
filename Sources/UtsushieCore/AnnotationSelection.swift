import Foundation
import CoreGraphics

extension AnnotationDocument {
    public mutating func remove(_ ids: Set<UUID>) { annotations.removeAll { ids.contains($0.id) } }

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
        let style = AnnotationStyle(imageSize: imageSize)
        var movement = delta
        for annotation in annotations where ids.contains(annotation.id) {
            let proposed = annotation.translated(by: delta)
            let placed = AnnotationGeometry.placed(proposed, bounds: bounds(of: proposed, style: style), imageSize: imageSize)
            let allowed = CGPoint(x: placed.start.x - annotation.start.x, y: placed.start.y - annotation.start.y)
            if delta.x > 0 { movement.x = min(movement.x, max(0, allowed.x)) }
            if delta.x < 0 { movement.x = max(movement.x, min(0, allowed.x)) }
            if delta.y > 0 { movement.y = min(movement.y, max(0, allowed.y)) }
            if delta.y < 0 { movement.y = max(movement.y, min(0, allowed.y)) }
        }
        return AnnotationDocument(annotations: annotations.map { ids.contains($0.id) ? $0.translated(by: movement) : $0 })
    }
}

extension AnnotationGeometry {
    public static func axisConstrained(_ delta: CGPoint) -> CGPoint {
        abs(delta.x) >= abs(delta.y) ? CGPoint(x: delta.x, y: 0) : CGPoint(x: 0, y: delta.y)
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
                                     shift: Bool, imageSize: CGSize) -> CGPoint {
        let point = tool.allowsMargin ? point : clamped(point, to: imageSize)
        guard shift else { return point }
        if [.arrow, .line].contains(tool) { return angleConstrained(point, from: anchor) }
        if [.rectangle, .spotlight, .mosaic].contains(tool) {
            return squareEndpoint(point, from: anchor, tool: tool, imageSize: imageSize)
        }
        return point
    }

    public static func resized(_ annotation: Annotation, handle: AnnotationResizeHandle, to point: CGPoint,
                               shift: Bool, imageSize: CGSize) -> Annotation {
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
        let rect = Annotation(tool: tool, start: anchor, end: endpoint).rect
        let side = min(imageSize.width, imageSize.height)
        // 中心が内側の枠は画像内へ収める。片辺だけ切って正方形を崩さない。
        guard tool == .rectangle, rect.width > side,
              containsCenter(of: rect, in: CGRect(origin: .zero, size: imageSize)) else { return endpoint }
        return CGPoint(x: anchor.x + (endpoint.x < anchor.x ? -side : side),
                       y: anchor.y + (endpoint.y < anchor.y ? -side : side))
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
