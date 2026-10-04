import Foundation

/// 元画像のピクセル座標とキャンバスの表示ptを結ぶ。注釈の履歴や書き出しには含めない。
public struct AnnotationViewport: Equatable, Sendable {
    public let scale: Double
    public let origin: CGPoint
    public init(scale: Double, origin: CGPoint) { self.scale = scale; self.origin = origin }
    public static func fit(content: CGRect, in view: CGRect, workbench: Double = 120) -> AnnotationViewport {
        let scale = min(1, max(1, view.width - workbench * 2) / content.width, max(1, view.height - workbench * 2) / content.height)
        return AnnotationViewport(scale: scale, origin: CGPoint(x: view.midX - content.midX * scale, y: view.midY - content.midY * scale))
    }
    public func imagePoint(at viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: (viewPoint.x - origin.x) / scale, y: (viewPoint.y - origin.y) / scale)
    }
    public func viewPoint(at imagePoint: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + imagePoint.x * scale, y: origin.y + imagePoint.y * scale)
    }
    public func zoomed(to requestedScale: Double, around anchor: CGPoint) -> AnnotationViewport {
        guard requestedScale.isFinite, requestedScale > 0 else { return self }
        let next = max(0.01, min(16, requestedScale))
        let point = imagePoint(at: anchor)
        return AnnotationViewport(scale: next, origin: CGPoint(x: anchor.x - point.x * next, y: anchor.y - point.y * next))
    }
    public func translated(by delta: CGPoint) -> AnnotationViewport {
        AnnotationViewport(scale: scale, origin: CGPoint(x: origin.x + delta.x, y: origin.y + delta.y))
    }
    public var percentage: String {
        let value = scale * 100
        return value < 10 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value)
    }
}
