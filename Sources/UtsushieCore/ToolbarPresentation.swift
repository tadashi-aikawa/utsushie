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

public enum AnnotationToolbarPresentation {
    public static let height: CGFloat = 75
    public static let minimumWidth: CGFloat = 1040
    public static let aiDisabled = "AIで隠すは、設定ファイルで ai = true にすると使えます"

    public static func hint(tool: AnnotationTool, nextNumber: Int, editingText: Bool = false,
                            findingPrivacy: Bool = false,
                            message: ToolbarHint? = nil, saving: Bool = false) -> ToolbarHint {
        if saving { return ToolbarHint("書き出し中…") }
        if let message { return message }
        if editingText { return ToolbarHint("⏎で確定 ・ ⇧⏎で改行", keys: ["⇧⏎", "⏎"]) }
        // 探索の状態はAIボタンに出す。手引きの行には重ねない。
        if findingPrivacy { return ToolbarHint() }
        switch tool {
        case .text: return ToolbarHint("クリックで文字 ・ 指す点からドラッグで引き出し線")
        case .number: return ToolbarHint("クリックで\(nextNumber) ・ 指す点からドラッグで引き出し線")
        default: return ToolbarHint()
        }
    }
}

public enum VideoToolbarPresentation {
    public static let height: CGFloat = 75
    public static func hint(document: VideoEditDocument, discardArmed: Bool = false, message: ToolbarHint? = nil) -> ToolbarHint {
        if let message { return message }
        return ToolbarHint(document.completionText, keys: document.isTrimmed || !document.stills.isEmpty ? [] : ["⏎"])
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
    public let width: CGFloat

    public init(itemWidths: [CGFloat], tabWidth: CGFloat) {
        precondition(itemWidths.count == 6)
        var frames: [CGRect] = []
        var x: CGFloat = 8
        for index in 0..<2 {
            frames.append(CGRect(x: x, y: 6, width: itemWidths[index], height: 28))
            x += itemWidths[index] + (index == 0 ? 2 : 0)
        }
        outputTray = CGRect(x: 6, y: 4, width: x + 2 - 6, height: 32)
        tab = CGRect(x: outputTray.maxX + 6, y: 11.5, width: tabWidth, height: 17)
        let targetX = tab.maxX + 10
        x = targetX + 2
        for index in 2..<5 {
            frames.append(CGRect(x: x, y: 6, width: itemWidths[index], height: 28))
            x += itemWidths[index] + (index < 4 ? 2 : 0)
        }
        targetTray = CGRect(x: targetX, y: 4, width: x + 2 - targetX, height: 32)
        frames.append(CGRect(x: targetTray.maxX + 10, y: 6, width: itemWidths[5], height: 28))
        items = frames
        width = frames[5].maxX + 6
    }
}
