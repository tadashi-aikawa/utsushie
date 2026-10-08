import Foundation
import CoreGraphics

/// 編集画面だけのコピー。一般のクリップボードに残したWebPを壊さない。
public struct AnnotationClipboard: Sendable {
    private var copied: [Annotation] = []
    private var pasteCount = 0
    public init() {}

    public mutating func copy(_ ids: Set<UUID>, from document: AnnotationDocument) {
        guard !ids.isEmpty else { return }
        copied = document.annotations.filter { ids.contains($0.id) }
        pasteCount = 0
    }

    public mutating func paste(into document: inout AnnotationDocument, imageSize: CGSize) -> Set<UUID> {
        guard !copied.isEmpty else { return [] }
        pasteCount += 1
        return document.appendCopies(copied, offset: Double(pasteCount) * max(imageSize.width, imageSize.height) * 0.02, imageSize: imageSize)
    }
}

extension AnnotationDocument {
    public mutating func duplicate(_ ids: Set<UUID>, imageSize: CGSize) -> Set<UUID> {
        appendCopies(annotations.filter { ids.contains($0.id) }, offset: max(imageSize.width, imageSize.height) * 0.02, imageSize: imageSize)
    }

    fileprivate mutating func appendCopies(_ originals: [Annotation], offset: Double, imageSize: CGSize) -> Set<UUID> {
        let delta = CGPoint(x: offset, y: offset)
        let style = AnnotationStyle(imageSize: imageSize)
        var ids: Set<UUID> = []
        for original in originals {
            let moved = original.translated(by: delta)
            let target = original.leaderTarget.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
            var copy = Annotation(tool: moved.tool, start: moved.start, end: moved.end, text: moved.text,
                                  leaderTarget: target, points: moved.points,
                                  highlighterColor: moved.highlighterColor, darkBackground: moved.darkBackground)
            // 番号は新しいIDを追加した順で採番する。元の番号の文字列を複製しない。
            copy = AnnotationGeometry.placed(copy, bounds: bounds(of: copy, style: style), imageSize: imageSize)
            annotations.append(copy); ids.insert(copy.id)
        }
        return ids
    }
}
