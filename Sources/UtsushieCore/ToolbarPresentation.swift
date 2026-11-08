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

/// 範囲選択のツールバー。AppKitの左下原点で、1段目の左に出力の台とTab・右端にやめる、2段目の左に切り替え・右端に対象の台を置く。
/// フォントの実測値はApp側から渡す。台の内側2pt、項目間2pt、外側6ptを共通に保つ。
public struct OverlayToolbarLayout: Equatable, Sendable {
    public static let height: CGFloat = 80
    /// 出力・対象・やめるの順。
    public let items: [CGRect]
    public let outputTray: CGRect
    public let targetTray: CGRect
    public let tab: CGRect
    /// 2段目の切り替え。解像度・音・容量の順に左から詰める。
    public let resolution: CGRect?
    public let audio: CGRect?
    public let compression: CGRect?
    public let width: CGFloat
    public var height: CGFloat { Self.height }

    /// `outputCount`は先頭から出力の台へ入れる項目の数。出力は最も広い項目の幅にそろえる。
    /// 残りの末尾1つを除いた項目が対象の台へ入り、末尾がやめる。
    /// `toggleSpace`は切り替えに確保する幅。最も長い切り替えの組を渡すと、Tab・R・A・Sで対象の台が動かない。
    public init(itemWidths: [CGFloat], tabWidth: CGFloat, resolutionWidth: CGFloat? = nil, audioWidth: CGFloat? = nil,
                compressionWidth: CGFloat? = nil, outputCount: Int = 2, toggleSpace: CGFloat = 0) {
        precondition(itemWidths.count >= outputCount + 4)
        let lastIndex = itemWidths.count - 1
        let top: CGFloat = 46, bottom: CGFloat = 6
        // 切り替えとの間、出力とやめるの間。切り替え同士の10ptより広く、余白だけでまとまりを分ける。
        let groupGap: CGFloat = 16
        var frames: [CGRect] = []
        let outputWidth = itemWidths[0..<outputCount].max() ?? 0
        var x: CGFloat = 8
        for index in 0..<outputCount {
            frames.append(CGRect(x: x, y: top, width: outputWidth, height: 28))
            x += outputWidth + (index < outputCount - 1 ? 2 : 0)
        }
        outputTray = CGRect(x: 6, y: top - 2, width: x + 2 - 6, height: 32)
        tab = CGRect(x: outputTray.maxX + 6, y: top + 5.5, width: tabWidth, height: 17)

        x = 8
        func toggle(_ width: CGFloat?) -> CGRect? {
            guard let width else { return nil }
            defer { x += width + 10 }
            return CGRect(x: x, y: bottom, width: width, height: 28)
        }
        resolution = toggle(resolutionWidth)
        audio = toggle(audioWidth)
        compression = toggle(compressionWidth)
        let togglesEnd = [resolution, audio, compression].compactMap { $0?.maxX }.max() ?? 8
        let togglesWidth = max(togglesEnd - 8, toggleSpace)

        let targetWidths = itemWidths[outputCount..<lastIndex]
        let targetTrayWidth = targetWidths.reduce(0, +) + CGFloat(targetWidths.count - 1) * 2 + 4
        let stopWidth = itemWidths[lastIndex]
        let topWidth = tab.maxX + groupGap + stopWidth + 6
        let bottomWidth = 8 + togglesWidth + groupGap + targetTrayWidth + 6
        width = max(topWidth, bottomWidth)

        // 対象の台は右端へそろえる。切り替えが短いときは、切り替えと対象の台のあいだが空く。
        let targetX = width - 6 - targetTrayWidth
        x = targetX + 2
        for index in outputCount..<lastIndex {
            frames.append(CGRect(x: x, y: bottom, width: itemWidths[index], height: 28))
            x += itemWidths[index] + (index < lastIndex - 1 ? 2 : 0)
        }
        targetTray = CGRect(x: targetX, y: bottom - 2, width: targetTrayWidth, height: 32)
        frames.append(CGRect(x: width - 6 - stopWidth, y: top, width: stopWidth, height: 28))
        items = frames
    }
}
