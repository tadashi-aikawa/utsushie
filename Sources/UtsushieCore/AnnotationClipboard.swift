import Foundation
import CoreGraphics

/// 編集画面だけのコピー。一般のクリップボードに残したWebPを壊さない。
public struct AnnotationClipboard: Sendable {
    private var copied: [Annotation] = []
    /// コピーした時点のトリミングの原点。元画像の座標。
    private var copiedOrigin = CGPoint.zero
    private var pasteCount = 0
    public init() {}

    public mutating func copy(_ ids: Set<UUID>, from document: AnnotationDocument) {
        guard !ids.isEmpty else { return }
        copied = document.annotations.filter { ids.contains($0.id) }
        copiedOrigin = document.crop?.rect.origin ?? .zero
        pasteCount = 0
    }

    public mutating func paste(into document: inout AnnotationDocument, imageSize: CGSize) -> Set<UUID> {
        guard !copied.isEmpty else { return [] }
        pasteCount += 1
        // コピーの後にトリミングしても、元画像の同じ場所へ写してからずらす。
        let origin = document.crop?.rect.origin ?? .zero
        let shift = CGPoint(x: copiedOrigin.x - origin.x, y: copiedOrigin.y - origin.y)
        let originals = copied.map { annotation in
            var moved = annotation.translated(by: shift)
            moved.leaderTarget = annotation.leaderTarget.map { CGPoint(x: $0.x + shift.x, y: $0.y + shift.y) }
            return moved
        }
        return document.appendCopies(originals, offset: Double(pasteCount) * document.style().pasteOffset, imageSize: imageSize)
    }
}

extension AnnotationDocument {
    public mutating func duplicate(_ ids: Set<UUID>, imageSize: CGSize) -> Set<UUID> {
        appendCopies(annotations.filter { ids.contains($0.id) }, offset: style().pasteOffset, imageSize: imageSize)
    }

    fileprivate mutating func appendCopies(_ originals: [Annotation], offset: Double, imageSize: CGSize) -> Set<UUID> {
        let delta = CGPoint(x: offset, y: offset)
        let style = self.style()
        var ids: Set<UUID> = []
        let image = CGRect(origin: .zero, size: imageSize)
        for var original in originals {
            // トリミングで切り落とした場所から貼る蛍光ペンは、線の長さの半分の点を画像の中央へ合わせる。
            // 外接矩形の中心は折れ線の上にあるとは限らない。
            if original.tool == .highlighter, !AnnotationGeometry.highlighterShows(original, in: image, style: style) {
                let middle = AnnotationGeometry.pointAtHalfLength(original.points)
                original = original.translated(by: CGPoint(x: image.midX - middle.x, y: image.midY - middle.y))
            }
            // 画像より大きい蛍光ペンは押し戻さないため、ずらしても線が画像に残る所までにする。
            let delta = AnnotationGeometry.visibleHighlighterMovement(delta, highlighters: [original], image: image, style: style)
            let moved = original.translated(by: delta)
            let target = original.leaderTarget.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
            var copy = Annotation(tool: moved.tool, start: moved.start, end: moved.end, text: moved.text,
                                  leaderTarget: target, points: moved.points,
                                  highlighterColor: moved.highlighterColor, darkBackground: moved.darkBackground, inkColor: moved.inkColor, size: moved.size)
            // 番号は新しいIDを追加した順で採番する。元の番号の文字列を複製しない。
            copy = AnnotationGeometry.placed(copy, bounds: bounds(of: copy, style: style), imageSize: imageSize, scale: scale)
            annotations.append(copy); ids.insert(copy.id)
        }
        return ids
    }
}
