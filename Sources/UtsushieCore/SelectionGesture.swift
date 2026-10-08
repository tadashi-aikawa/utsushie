import Foundation
import CoreGraphics

public enum PointerAction: Equatable, Sendable {
    case none, captureWindow
    case captureArea(CGRect), moveLast(CGRect)
}

public struct SelectionGesture: Sendable {
    // 4pt以内はクリック時の手ぶれとみなす。整数化すると微小な移動でも1pxの
    // 矩形になり得るため、座標を丸める前の距離で判定する。Retina倍率に依存しない。
    public static let dragThreshold: CGFloat = 4
    private var start: CGPoint?
    private var originalLast: CGRect?
    public private(set) var isDragging = false
    public private(set) var areaPreview: CGRect?
    public private(set) var lastPreview: CGRect?
    public var isSelectingArea: Bool { isDragging && originalLast == nil }

    public init() {}
    public mutating func begin(at point: CGPoint, last: CGRect?, movingLast: Bool = false) {
        cancel()
        start = point
        originalLast = movingLast ? last.flatMap { $0.contains(point) ? $0 : nil } : nil
    }
    public mutating func update(to point: CGPoint) {
        guard let start else { return }
        // 一度4ptを超えたら、押した点へ戻ってもウィンドウのクリックには戻さない。
        isDragging = isDragging || isDrag(from: start, to: point)
        guard isDragging else { return }
        if let originalLast {
            lastPreview = originalLast.offsetBy(dx: (point.x - start.x).rounded(), dy: (point.y - start.y).rounded())
        } else {
            areaPreview = CaptureGeometry.selection(from: start, to: point)
        }
    }
    public mutating func finish(at point: CGPoint, hasWindow: Bool = false) -> PointerAction {
        guard start != nil else { return .none }
        defer { cancel() }
        update(to: point)
        guard isDragging else { return hasWindow ? .captureWindow : .none }
        if let lastPreview { return .moveLast(lastPreview) }
        if let areaPreview, areaPreview.width >= 1, areaPreview.height >= 1 { return .captureArea(areaPreview) }
        return .none
    }
    public mutating func cancel() {
        start = nil; originalLast = nil; isDragging = false; areaPreview = nil; lastPreview = nil
    }
    private func isDrag(from start: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - start.x, point.y - start.y) > Self.dragThreshold
    }
}
