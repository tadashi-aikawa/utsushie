import Foundation
import CoreGraphics

public enum PointerAction: Equatable, Sendable {
    case none, captureWindow
    case captureArea(CGRect), moveLast(CGRect)
    case captureDisplay(CGRect)
}

/// 前回枠の辺。AppKitの座標なのでminYが下。
public struct LastFrameEdges: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let minX = Self(rawValue: 1 << 0)
    public static let maxX = Self(rawValue: 1 << 1)
    public static let minY = Self(rawValue: 1 << 2)
    public static let maxY = Self(rawValue: 1 << 3)
}

/// ⌥を押して前回枠のどこをつかむか。境界の帯はリサイズ、内側は移動。
public enum LastFrameGrip: Equatable, Sendable {
    case move
    case resize(LastFrameEdges)
    /// 境界は内外6ptの帯。小さい枠では内側の帯を辺の1/4へ縮め、移動できる面を残す。
    public static let tolerance: CGFloat = 6
    /// リサイズで縮める下限。裏返さない。
    public static let minimumSize: CGFloat = 8

    public static func at(_ point: CGPoint, in frame: CGRect) -> LastFrameGrip? {
        guard frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return nil }
        var edges: LastFrameEdges = []
        switch side(point.x, frame.minX, frame.maxX) {
        case .some(true): edges.insert(.minX)
        case .some(false): edges.insert(.maxX)
        case nil: break
        }
        switch side(point.y, frame.minY, frame.maxY) {
        case .some(true): edges.insert(.minY)
        case .some(false): edges.insert(.maxY)
        case nil: break
        }
        if !edges.isEmpty { return .resize(edges) }
        return frame.contains(point) ? .move : nil
    }
    /// trueは小さい側の辺、falseは大きい側の辺。両方の帯に入る細い枠では近いほう。
    private static func side(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> Bool? {
        let inner = min(tolerance, (high - low) / 4)
        let toLow = value - low, toHigh = high - value
        let nearLow = toLow >= -tolerance && toLow <= inner
        let nearHigh = toHigh >= -tolerance && toHigh <= inner
        if nearLow && nearHigh { return abs(toLow) <= abs(toHigh) }
        return nearLow ? true : nearHigh ? false : nil
    }
    /// つかんだ辺だけ動かす。画面の制限は動かす辺だけに掛け、最後に下限を守る。
    /// 下限より細い枠は今の寸法を下限にする。動かさない辺を越えて画面の外へ広げない。
    public static func resized(_ frame: CGRect, edges: LastFrameEdges, by delta: CGPoint, bounds: CGRect?) -> CGRect {
        var minX = frame.minX, maxX = frame.maxX, minY = frame.minY, maxY = frame.maxY
        let width = min(minimumSize, frame.width), height = min(minimumSize, frame.height)
        if edges.contains(.minX) { minX = min(max(frame.minX + delta.x, bounds?.minX ?? -.infinity), maxX - width) }
        if edges.contains(.maxX) { maxX = max(min(frame.maxX + delta.x, bounds?.maxX ?? .infinity), minX + width) }
        if edges.contains(.minY) { minY = min(max(frame.minY + delta.y, bounds?.minY ?? -.infinity), maxY - height) }
        if edges.contains(.maxY) { maxY = max(min(frame.maxY + delta.y, bounds?.maxY ?? .infinity), minY + height) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
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
    /// mouseDownで決めた前回枠のつかみ方。途中で⌥を離しても変えない。
    public private(set) var lastGrip: LastFrameGrip?
    public private(set) var areaPreview: CGRect?
    public private(set) var lastPreview: CGRect?
    public var isSelectingArea: Bool { isDragging && originalLast == nil }
    /// mouseDownからmouseUp・取り消しまで。閾値を超える前も含む。
    public var isActive: Bool { start != nil }

    public init() {}
    public mutating func begin(at point: CGPoint, last: CGRect?, movingLast: Bool = false,
                               displayFrames: [CGRect] = [], constrainToDisplay: Bool = true, selectingDisplay: Bool = false) {
        cancel()
        start = point
        if movingLast, !selectingDisplay, let last, let grip = LastFrameGrip.at(point, in: last) {
            originalLast = last; lastGrip = grip
        }
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
        if let originalLast, case let .resize(edges) = lastGrip {
            let delta = CGPoint(x: (point.x - start.x).rounded(), y: (point.y - start.y).rounded())
            lastPreview = LastFrameGrip.resized(originalLast, edges: edges, by: delta, bounds: displayBounds)
        } else if let originalLast {
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
        start = nil; originalLast = nil; lastGrip = nil; displayBounds = nil; isDragging = false; areaPreview = nil; lastPreview = nil
        clickAction = .none
    }
    private func isDrag(from start: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - start.x, point.y - start.y) > Self.dragThreshold
    }
}
