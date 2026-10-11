import Foundation
import CoreGraphics

public enum CaptureOutput: String, Sendable { case image, video }
public enum CaptureTarget: String, Sendable { case area, last, chrome, element }
public enum CaptureCursor: Equatable, Sendable { case crosshair, arrow }
public enum CaptureAction: Equatable, Sendable { case none, cancel, captureLast, captureChrome }
public struct CaptureState: Sendable {
    public private(set) var output: CaptureOutput = .image
    public private(set) var target: CaptureTarget = .area
    public private(set) var gesture = SelectionGesture()
    private var shiftPressed = false
    public var cursor: CaptureCursor { .crosshair }
    public var highlightsWindow: Bool { !gesture.isDragging && !shiftPressed }
    public var highlightsDisplay: Bool { !gesture.isDragging && shiftPressed }
    public init() {}
    /// 文字やIMEの変換結果に依存しない物理keyCodeで判断する。
    public mutating func key(_ code: UInt16, hasLast: Bool) -> CaptureAction {
        guard [UInt16(53), 48, 8, 14, 36, 76].contains(code) else { return .none }
        // キー操作で選択ジェスチャーを終える。Esc後のmouseUpは撮影へ遷移しない。
        gesture.cancel()
        switch code {
        case 53: return .cancel
        case 48:
            output = output == .image ? .video : .image
            return .none
        case 8:
            target = .chrome; return .captureChrome
        case 14:
            target = target == .element ? .area : .element
            return .none
        case 36, 76: return repeatCapture(hasLast: hasLast)
        default: return .none
        }
    }
    public mutating func repeatCapture(hasLast: Bool) -> CaptureAction {
        guard hasLast else { return .none }
        target = .last
        return .captureLast
    }
    public mutating func fallbackToArea() { target = .area }
    public mutating func selectArea() { target = .area }
    public mutating func modifiersChanged(shift: Bool) { shiftPressed = shift }
    public mutating func pointerDown(at point: CGPoint, last: CGRect?, movingLast: Bool = false,
                                     displayFrames: [CGRect] = [], selectingDisplay: Bool = false) -> PointerAction {
        if target != .element || movingLast || selectingDisplay { selectArea() }
        gesture.begin(at: point, last: last, movingLast: movingLast, displayFrames: displayFrames,
                      constrainToDisplay: output == .video, selectingDisplay: selectingDisplay)
        return .none
    }
    public mutating func pointerDragged(to point: CGPoint) {
        gesture.update(to: point)
        if gesture.isDragging { selectArea() }
    }
    public mutating func pointerUp(at point: CGPoint, hasWindow: Bool = false) -> PointerAction {
        let action = gesture.finish(at: point, hasWindow: hasWindow)
        if case .captureArea = action { selectArea() }
        return action
    }
    public mutating func cancelGesture() { gesture.cancel() }
}
