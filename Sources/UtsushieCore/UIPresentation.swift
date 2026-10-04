import Foundation
import CoreGraphics

public struct HUDItem: Equatable, Sendable {
    public let title: String
    public let key: String?
    public let selected: Bool
    public let recording: Bool
    public let enabled: Bool
}

public enum OverlayPresentation {
    public static func items(output: CaptureOutput, target: CaptureTarget, hasLast: Bool) -> [HUDItem] {
        [HUDItem(title: "画像", key: nil, selected: output == .image, recording: false, enabled: true),
         HUDItem(title: "動画", key: nil, selected: output == .video, recording: output == .video, enabled: true),
         HUDItem(title: "範囲", key: "ドラッグ", selected: target == .area, recording: false, enabled: true),
         HUDItem(title: "前回", key: "⏎", selected: target == .last, recording: false, enabled: hasLast),
         HUDItem(title: "Chrome", key: "C", selected: target == .chrome, recording: false, enabled: true),
         HUDItem(title: "やめる", key: "Esc", selected: false, recording: false, enabled: true)]
    }
    /// AppKit座標。上端に置けない札は範囲内へ戻し、画面の左右へも収める。
    public static func dimensionLabel(selection: CGRect, screen: CGRect, size: CGSize) -> CGRect {
        let width = min(size.width, max(0, screen.width - 8))
        let outside = selection.maxY + 10
        let y = outside + size.height <= screen.maxY - 4 ? outside : selection.maxY - size.height - 8
        return CGRect(x: min(max(selection.minX, screen.minX + 4), screen.maxX - width - 4),
                      y: max(screen.minY + 4, y), width: width, height: size.height)
    }
    public static func dimensions(points: CGSize, scale: Double, output: CaptureOutput, downscale: Bool) -> String {
        let size = output == .video ? VideoGeometry.size(points: points, scale: scale, downscale: downscale)
            : CaptureGeometry.outputSize(points: points, scale: scale, downscale: downscale)
        return "\(size.width)×\(size.height)"
    }
}

public enum CardAction: Int, CaseIterable, Sendable { case annotate, save, reveal, close }
public enum CardPresentation {
    /// 最新を右下へ置き、上端を超える前に左の列へ折り返す。
    public static func stackOrigin(index: Int, visible: CGRect, cardSize: CGSize = CGSize(width: 264, height: 216)) -> CGPoint {
        let stride = cardSize.height + 12
        let rows = max(1, Int(((visible.height - 36 + 12) / stride).rounded(.down)))
        return CGPoint(x: visible.maxX - 18 - cardSize.width - CGFloat(index / rows) * (cardSize.width + 12),
                       y: visible.minY + 18 + CGFloat(index % rows) * stride)
    }
    // カードは左上原点。4ボタンとも同じ幅で、描画と当たり判定に同じ矩形を使う。
    public static func button(_ action: CardAction) -> CGRect {
        CGRect(x: 12 + Double(action.rawValue) * 61.5, y: 186, width: 55.5, height: 24)
    }
    public static func action(at point: CGPoint) -> CardAction? {
        CardAction.allCases.first { button($0).contains(point) }
    }
    public static func status(copied: Bool, finalizing: Bool) -> String {
        finalizing ? "書き出し中" : copied ? "コピー済み" : "保存のみ"
    }
    public static func info(format: String, width: Int, height: Int, bytes: Int) -> String {
        let capacity = bytes <= 0 ? "—" : bytes >= 1_048_576 ? String(format: "%.1f MB", Double(bytes) / 1_048_576)
            : "\(max(1, Int((Double(bytes) / 1024).rounded()))) KB"
        return "\(format) · \(width)×\(height) · \(capacity)"
    }
}

public enum RecordingPresentation {
    public static func title(phase: RecordingPhase, elapsed: Double) -> String {
        switch phase {
        case .idle: ""
        case .starting: "準備中"
        case .recording: "■ \(MediaFormatting.elapsed(elapsed))"
        case .finalizing: "書き出し中"
        }
    }
    public static func stopsOnClick(phase: RecordingPhase) -> Bool { phase == .recording }
}

public enum HotkeyPresentation {
    public static func label(_ hotkey: Hotkey) -> String {
        var label = ""
        for (bit, mark) in [(UInt32(4096), "⌃"), (2048, "⌥"), (512, "⇧"), (256, "⌘")] {
            if hotkey.modifiers & bit != 0 { label += mark }
        }
        let keys: [UInt32: String] = [0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V", 11:"B",
            12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2", 20:"3", 21:"4", 22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"-", 28:"8", 29:"0",
            30:"]", 31:"O", 32:"U", 33:"[", 34:"I", 35:"P", 36:"⏎", 37:"L", 38:"J", 39:"'", 40:"K", 41:";", 42:"\\", 43:",", 44:"/", 45:"N", 46:"M", 47:".", 48:"Tab", 49:"Space", 50:"`", 51:"⌫", 53:"Esc",
            65:".", 67:"*", 69:"+", 71:"Clear", 75:"/", 76:"⏎", 78:"-", 81:"=", 82:"0", 83:"1", 84:"2", 85:"3", 86:"4", 87:"5", 88:"6", 89:"7", 91:"8", 92:"9",
            96:"F5", 97:"F6", 98:"F7", 99:"F3", 100:"F8", 101:"F9", 103:"F11", 109:"F10", 111:"F12", 118:"F4", 120:"F2", 122:"F1", 123:"←", 124:"→", 125:"↓", 126:"↑"]
        return label + (keys[hotkey.keyCode] ?? "キー\(hotkey.keyCode)")
    }
}
