import Foundation
import CoreGraphics

public struct ToolbarHint: Equatable, Sendable {
    public let text: String
    public let isError: Bool
    public let keys: [String]
    public init(_ text: String = "", isError: Bool = false, keys: [String] = []) {
        self.text = text; self.isError = isError; self.keys = keys
    }
}

public enum AnnotationColorControls: Equatable, Sendable {
    case none, ink, highlighter
}

public enum AnnotationToolbarPresentation {
    public static let height: CGFloat = 75
    public static let minimumWidth: CGFloat = 1040
    public static let aiDisabled = "AIで隠すは、設定ファイルで ai = true にすると使えます"

    public static func showsSizeControls(tool: AnnotationTool, selectedTools: [AnnotationTool]) -> Bool {
        colorControls(tool: tool, selectedTools: selectedTools) != .none
    }

    public static func colorControls(tool: AnnotationTool, selectedTools: [AnnotationTool]) -> AnnotationColorControls {
        if tool == .highlighter { return .highlighter }
        if tool.usesInkColor { return .ink }
        guard tool == .selection else { return .none }
        if selectedTools.contains(where: \.usesInkColor) { return .ink }
        return selectedTools.contains(.highlighter) ? .highlighter : .none
    }

    public static func hint(tool: AnnotationTool, nextNumber: Int, editingText: Bool = false,
                            findingPrivacy: Bool = false,
                            message: ToolbarHint? = nil, saving: Bool = false) -> ToolbarHint {
        if saving { return ToolbarHint("書き出し中…") }
        if let message { return message }
        if editingText { return ToolbarHint("⏎で確定 ・ ⇧⏎で改行", keys: ["⇧⏎", "⏎"]) }
        // 探索の状態はAIボタンに出す。手引きの行には重ねない。
        if findingPrivacy { return ToolbarHint() }
        switch tool {
        case .crop: return ToolbarHint("ドラッグした範囲を新しい画像にする ・ ⌘Zで戻す", keys: ["⌘Z"])
        case .text: return ToolbarHint("クリックで文字 ・ 指す点からドラッグで引き出し線")
        case .number: return ToolbarHint("クリックで\(nextNumber) ・ 指す点からドラッグで引き出し線")
        default: return ToolbarHint()
        }
    }
}

public enum VideoToolbarPresentation {
    public static let height: CGFloat = 75
    public static func hint(document: VideoEditDocument, discardArmed: Bool = false, message: ToolbarHint? = nil,
                            copiesStills: Bool = true, zoomTool: Bool = false, selection: VideoRange? = nil) -> ToolbarHint {
        if let message { return message }
        if zoomTool, let selection {
            // 時間軸で選んだ範囲があれば、矩形を描くとその範囲に置く。
            return ToolbarHint(String(format: "選んだ%.1f秒に、プレビューで寄せる範囲をドラッグ ・ Z Escで戻る", selection.duration), keys: ["Z", "Esc"])
        }
        if zoomTool { return ToolbarHint("プレビューで寄せる範囲をドラッグ ・ 枠の縁でリサイズ ・ ⌥ドラッグで移動 ・ Z Escで戻る", keys: ["⌥", "Z", "Esc"]) }
        let edited = document.isTrimmed || !document.stills.isEmpty || !document.zooms.isEmpty
        return ToolbarHint(document.completionText(copiesStills: copiesStills), keys: edited ? [] : ["⏎"])
    }
    public static func length(document: VideoEditDocument) -> String {
        if document.transitionDuration > 0 {
            return String(format: "残す %.1f秒 + つなぎ %.1f秒 / %.1f秒", document.keptDuration, document.transitionDuration, document.duration)
        }
        return String(format: "残す %.1f秒 / %.1f秒", document.keptDuration, document.duration)
    }
}

/// フォントの実測値はApp側から渡す。台の内側2pt、項目間2pt、外側6ptを共通に保つ。
public struct OverlayToolbarLayout: Equatable, Sendable {
    public let items: [CGRect]
    public let outputTray: CGRect
    public let targetTray: CGRect
    public let tab: CGRect
    /// 解像度。Tabの右で台に入れず、音と対象の台を右へ送る。
    public let resolution: CGRect?
    /// 動画の音。解像度の右で台に入れず、対象の台を右へ送る。
    public let audio: CGRect?
    /// 動画の容量。音の右で台に入れず、対象の台を右へ送る。
    public let compression: CGRect?
    public let width: CGFloat

    /// `outputCount`は先頭から出力の台へ入れる項目の数。残りの末尾1つを除いた項目が対象の台へ入る。
    public init(itemWidths: [CGFloat], tabWidth: CGFloat, resolutionWidth: CGFloat? = nil, audioWidth: CGFloat? = nil,
                compressionWidth: CGFloat? = nil, outputCount: Int = 2) {
        precondition(itemWidths.count >= outputCount + 4)
        let lastIndex = itemWidths.count - 1
        var frames: [CGRect] = []
        var x: CGFloat = 8
        for index in 0..<outputCount {
            frames.append(CGRect(x: x, y: 6, width: itemWidths[index], height: 28))
            x += itemWidths[index] + (index < outputCount - 1 ? 2 : 0)
        }
        outputTray = CGRect(x: 6, y: 4, width: x + 2 - 6, height: 32)
        tab = CGRect(x: outputTray.maxX + 6, y: 11.5, width: tabWidth, height: 17)
        var resolutionFrame: CGRect?
        if let resolutionWidth { resolutionFrame = CGRect(x: tab.maxX + 10, y: 6, width: resolutionWidth, height: 28) }
        resolution = resolutionFrame
        var audioFrame: CGRect?
        if let audioWidth { audioFrame = CGRect(x: (resolutionFrame?.maxX ?? tab.maxX) + 10, y: 6, width: audioWidth, height: 28) }
        audio = audioFrame
        var compressionFrame: CGRect?
        if let compressionWidth {
            compressionFrame = CGRect(x: (audioFrame?.maxX ?? resolutionFrame?.maxX ?? tab.maxX) + 10, y: 6, width: compressionWidth, height: 28)
        }
        compression = compressionFrame
        let targetX = (compressionFrame?.maxX ?? audioFrame?.maxX ?? resolutionFrame?.maxX ?? tab.maxX) + 10
        x = targetX + 2
        for index in outputCount..<lastIndex {
            frames.append(CGRect(x: x, y: 6, width: itemWidths[index], height: 28))
            x += itemWidths[index] + (index < lastIndex - 1 ? 2 : 0)
        }
        targetTray = CGRect(x: targetX, y: 4, width: x + 2 - targetX, height: 32)
        frames.append(CGRect(x: targetTray.maxX + 10, y: 6, width: itemWidths[lastIndex], height: 28))
        items = frames
        width = frames[lastIndex].maxX + 6
    }
}
