import Foundation
import CoreGraphics

public enum PointerAction: Equatable, Sendable {
    case none, captureWindow
    case captureArea(CGRect), moveLast(CGRect)
    case captureDisplay(CGRect)
}

public struct SelectionGesture: Sendable {
    // 4pt以内はクリック時の手ぶれとみなす。整数化すると微小な移動でも1pxの
    // 矩形になり得るため、座標を丸める前の距離で判定する。Retina倍率に依存しない。
    public static let dragThreshold: CGFloat = 4
    private var start: CGPoint?
    private var originalLast: CGRect?
    private var displayBounds: CGRect?
    private var clickAction: PointerAction = .none
    public private(set) var isDragging = false
    public private(set) var areaPreview: CGRect?
    public private(set) var lastPreview: CGRect?
    public var isSelectingArea: Bool { isDragging && originalLast == nil }

    public init() {}
    public mutating func begin(at point: CGPoint, last: CGRect?, movingLast: Bool = false,
                               displayFrames: [CGRect] = [], constrainToDisplay: Bool = true, selectingDisplay: Bool = false) {
        cancel()
        start = point
        originalLast = movingLast && !selectingDisplay ? last.flatMap { $0.contains(point) ? $0 : nil } : nil
        let anchor = originalLast.map { CGPoint(x: $0.midX, y: $0.midY) } ?? point
        displayBounds = constrainToDisplay ? displayFrames.first { $0.contains(anchor) } : nil
        // クリック対象はmouseDownで固定する。⇧を途中で変えても撮影対象は変えない。
        clickAction = selectingDisplay
            ? displayFrames.first { $0.contains(point) }.map(PointerAction.captureDisplay) ?? .none
            : .captureWindow
    }
    public mutating func update(to point: CGPoint) {
        guard let start else { return }
        // 一度4ptを超えたら、押した点へ戻ってもウィンドウのクリックには戻さない。
        isDragging = isDragging || isDrag(from: start, to: point)
        guard isDragging else { return }
        if let originalLast {
            var moved = originalLast.offsetBy(dx: (point.x - start.x).rounded(), dy: (point.y - start.y).rounded())
            if let bounds = displayBounds {
                // 枠の寸法は保つ。画面より大きい前回枠は移動で収められないため変えない。
                guard originalLast.width <= bounds.width, originalLast.height <= bounds.height else {
                    lastPreview = originalLast
                    return
                }
                moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
                moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
            }
            lastPreview = moved
        } else {
            let endpoint = displayBounds.map { bounds in
                CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                        y: min(max(point.y, bounds.minY), bounds.maxY))
            } ?? point
            let selection = CaptureGeometry.selection(from: start, to: endpoint)
            // integralの切り上げでも画面外へ出さない。
            areaPreview = displayBounds.map { selection.intersection($0) } ?? selection
        }
    }
    public mutating func finish(at point: CGPoint, hasWindow: Bool = false) -> PointerAction {
        guard start != nil else { return .none }
        defer { cancel() }
        update(to: point)
        guard isDragging else { return clickAction == .captureWindow ? (hasWindow ? .captureWindow : .none) : clickAction }
        if let lastPreview { return .moveLast(lastPreview) }
        if let areaPreview, areaPreview.width >= 1, areaPreview.height >= 1 { return .captureArea(areaPreview) }
        return .none
    }
    public mutating func cancel() {
        start = nil; originalLast = nil; displayBounds = nil; isDragging = false; areaPreview = nil; lastPreview = nil
        clickAction = .none
    }
    private func isDrag(from start: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - start.x, point.y - start.y) > Self.dragThreshold
    }
}
