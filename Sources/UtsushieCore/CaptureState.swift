import Foundation
import CoreGraphics

public enum CaptureOutput: String, Sendable { case image, video }
public enum CaptureTarget: String, Sendable { case area, last, chrome, element }
public enum CaptureCursor: Equatable, Sendable { case crosshair, arrow, openHand, closedHand, resize(LastFrameEdges) }
public enum CaptureAction: Equatable, Sendable { case none, cancel, captureLast, captureChrome }
public struct CaptureState: Sendable {
    public private(set) var output: CaptureOutput = .image
    public private(set) var target: CaptureTarget = .area
    public private(set) var gesture = SelectionGesture()
    /// 設定の既定から始め、Aで変えた音はその回の選択だけに使う。
    public private(set) var audio: VideoAudio
    /// 出力ごとの既定を反転する。その回の選択を開き直すと戻る。
    public private(set) var resolutionInverted = false
    private var shiftPressed = false
    private var optionPressed = false
    public var cursor: CaptureCursor { target == .element ? .arrow : .crosshair }
    /// ⌥で前回枠をつかめる場所だけ、移動・リサイズのカーソルにする。⇧の画面撮影が優先。
    public func cursor(at point: CGPoint, last: CGRect?) -> CaptureCursor {
        guard target != .element else { return .arrow }
        let grip: LastFrameGrip?
        if gesture.isActive { grip = gesture.lastGrip }
        else if optionPressed, !shiftPressed, let last { grip = LastFrameGrip.at(point, in: last) }
        else { grip = nil }
        switch grip {
        case .move: return gesture.isActive ? .closedHand : .openHand
        case let .resize(edges): return .resize(edges)
        case nil: return .crosshair
        }
    }
    public var highlightsWindow: Bool { !gesture.isDragging && !shiftPressed }
    public var highlightsDisplay: Bool { target != .element && !gesture.isDragging && shiftPressed }
    public init(audio: VideoAudio = .none) { self.audio = audio }
    /// 動画のときだけ受けるキー。画像のAは他のアプリへ渡す。
    public func handles(_ code: UInt16) -> Bool {
        [UInt16(53), 48, 8, 14, 15, 36, 76].contains(code) || code == 0 && output == .video
    }
    public func effectiveDownscale(config: UtsushieConfig) -> Bool {
        (output == .video ? config.video.downscale : config.downscale) != resolutionInverted
    }
    /// 録画と編集カードに同じ実効値を渡す。2xは設定のfpsによらず60fps。
    public func effectiveVideoConfig(_ defaults: VideoConfig) -> VideoConfig {
        var result = defaults
        result.downscale = defaults.downscale != resolutionInverted
        result.fps = result.downscale ? defaults.fps : 60
        return result
    }
    /// 文字やIMEの変換結果に依存しない物理keyCodeで判断する。
    public mutating func key(_ code: UInt16, hasLast: Bool) -> CaptureAction {
        // 音と解像度の切り替えは範囲の選び方を変えないため、ドラッグ中でも続ける。
        if code == 15 {
            resolutionInverted.toggle()
            return .none
        }
        if code == 0 {
            if output == .video { audio = audio.next }
            return .none
        }
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
    public mutating func modifiersChanged(shift: Bool, option: Bool = false) { shiftPressed = shift; optionPressed = option }
    public mutating func pointerDown(at point: CGPoint, last: CGRect?, movingLast: Bool = false,
                                     displayFrames: [CGRect] = [], selectingDisplay: Bool = false) -> PointerAction {
        if target == .element {
            gesture.begin(at: point, last: nil, constrainToDisplay: false)
            return .none
        }
        selectArea()
        gesture.begin(at: point, last: last, movingLast: movingLast, displayFrames: displayFrames,
                      constrainToDisplay: output == .video, selectingDisplay: selectingDisplay)
        return .none
    }
    public mutating func pointerDragged(to point: CGPoint) {
        gesture.update(to: point)
        if target == .element {
            // 一度閾値を超えたら、戻ってもクリックにしない。
            if gesture.isDragging { gesture.cancel() }
            return
        }
        if gesture.isDragging { selectArea() }
    }
    public mutating func pointerUp(at point: CGPoint, hasWindow: Bool = false) -> PointerAction {
        let action = gesture.finish(at: point, hasWindow: hasWindow)
        if target == .element { return action == .captureWindow ? action : .none }
        if case .captureArea = action { selectArea() }
        return action
    }
    public mutating func cancelGesture() { gesture.cancel() }
}
