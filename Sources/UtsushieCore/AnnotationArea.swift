import Foundation

extension AnnotationStyle {
    /// パスの外側へ出るインクと縁の幅。スポットは穴の外側だけに帯を描く。
    public func areaInset(for tool: AnnotationTool) -> Double {
        switch tool {
        case .rectangle: lineWidth / 2 + edge
        case .spotlight: lineWidth + edge * 2
        default: 0
        }
    }
}

extension AnnotationGeometry {
    public static func areaDrawingRect(tool: AnnotationTool, imageSize: CGSize, size: AnnotationSize = .normal) -> CGRect {
        let inset = AnnotationStyle(imageSize: imageSize, size: size).areaInset(for: tool)
        // 線幅より小さな画像でも負の寸法を作らず、作成可能な面積をゼロへ畳む。
        let x = min(inset, imageSize.width / 2), y = min(inset, imageSize.height / 2)
        return CGRect(x: x, y: y, width: max(0, imageSize.width - x * 2), height: max(0, imageSize.height - y * 2))
    }

    static func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: max(rect.minX, min(rect.maxX, point.x)), y: max(rect.minY, min(rect.maxY, point.y)))
    }

    static func keepsAreaInside(_ annotation: Annotation, imageSize: CGSize) -> Bool {
        annotation.tool == .spotlight || annotation.tool == .rectangle
            && containsCenter(of: annotation.rect, in: CGRect(origin: .zero, size: imageSize))
    }

    /// 作成と角のリサイズは点を制限する。反対の点を移動させる平行移動はしない。
    static func clampingAreaPoints(_ annotation: Annotation, square: Bool, imageSize: CGSize) -> Annotation {
        guard keepsAreaInside(annotation, imageSize: imageSize) else { return annotation }
        let area = areaDrawingRect(tool: annotation.tool, imageSize: imageSize, size: annotation.size)
        var result = annotation
        result.start = clamped(annotation.start, to: area)
        result.end = clamped(annotation.end, to: area)
        if square {
            let localAnchor = CGPoint(x: result.start.x - area.minX, y: result.start.y - area.minY)
            let localPoint = CGPoint(x: annotation.end.x - area.minX, y: annotation.end.y - area.minY)
            let endpoint = squareConstrained(localPoint, from: localAnchor, imageSize: area.size)
            result.end = CGPoint(x: endpoint.x + area.minX, y: endpoint.y + area.minY)
        }
        return result
    }

    public static func creationStart(_ point: CGPoint, tool: AnnotationTool, imageSize: CGSize, size: AnnotationSize = .normal) -> CGPoint {
        guard tool == .spotlight || tool == .rectangle && contains(point, in: CGRect(origin: .zero, size: imageSize)) else { return point }
        return clamped(point, to: areaDrawingRect(tool: tool, imageSize: imageSize, size: size))
    }

    public static func creating(_ annotation: Annotation, to point: CGPoint, shift: Bool, imageSize: CGSize) -> Annotation {
        var result = annotation
        if [.rectangle, .spotlight].contains(annotation.tool) {
            result.end = shift ? squareConstrained(point, from: annotation.start) : point
            return clampingAreaPoints(result, square: shift, imageSize: imageSize)
        }
        result.end = creationPoint(point, from: annotation.start, tool: annotation.tool, shift: shift, imageSize: imageSize)
        return result
    }

    /// 移動・貼り付け・太さの変更は寸法を保って押し戻す。収まらない寸法だけ縮める。
    static func placingArea(_ annotation: Annotation, imageSize: CGSize) -> Annotation {
        let area = areaDrawingRect(tool: annotation.tool, imageSize: imageSize, size: annotation.size)
        let rect = annotation.rect
        let width = min(rect.width, area.width), height = min(rect.height, area.height)
        let x = max(area.minX, min(area.maxX - width, rect.minX))
        let y = max(area.minY, min(area.maxY - height, rect.minY))
        var result = annotation
        result.start = CGPoint(x: annotation.start.x <= annotation.end.x ? x : x + width,
                               y: annotation.start.y <= annotation.end.y ? y : y + height)
        result.end = CGPoint(x: annotation.start.x <= annotation.end.x ? x + width : x,
                             y: annotation.start.y <= annotation.end.y ? y + height : y)
        return result
    }
}
