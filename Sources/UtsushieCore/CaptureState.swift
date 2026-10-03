import Foundation
import CoreGraphics

public enum CaptureOutput: String, Sendable { case image, video }
public enum CaptureTarget: String, Sendable { case area, last, window, chrome }
public enum CaptureAction: Equatable, Sendable { case none, cancel, captureLast, captureChrome }
public struct CaptureState: Sendable {
    public private(set) var output: CaptureOutput = .image
    public private(set) var target: CaptureTarget = .area
    public private(set) var gesture = SelectionGesture()
    public init() {}
    /// 文字やIMEの変換結果に依存しない物理keyCodeで判断する。
    public mutating func key(_ code: UInt16, hasLast: Bool) -> CaptureAction {
        // キー操作で選択ジェスチャーを終える。Esc後のmouseUpは撮影へ遷移しない。
        gesture.cancel()
        switch code {
        case 53: return .cancel
        case 48:
            output = output == .image ? .video : .image
            return .none
        case 13: target = .window; return .none
        case 8:
            target = .chrome; return .captureChrome
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
    public mutating func pointerDown(at point: CGPoint, last: CGRect?) -> PointerAction {
        gesture.cancel()
        // Wのクリック撮影は範囲選択のクリック取り消しから除外する。
        if target == .window { return .captureWindow }
        selectArea()
        gesture.begin(at: point, last: last)
        return .none
    }
    public mutating func pointerDragged(to point: CGPoint) { gesture.update(to: point) }
    public mutating func pointerUp(at point: CGPoint) -> PointerAction {
        gesture.finish(at: point)
    }
    public mutating func cancelGesture() { gesture.cancel() }
}
