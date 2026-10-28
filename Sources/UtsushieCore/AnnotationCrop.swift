import Foundation
import CoreGraphics

/// 元画像を切り詰めずに保ち、範囲だけを履歴へ入れる。⌘Zで元の画像と注釈へ戻せる。
public struct AnnotationCrop: Equatable, Sendable {
    /// 元画像の左上原点のピクセル座標。整数へ揃える。
    public var rect: CGRect
    public init(rect: CGRect) { self.rect = rect }
}

extension AnnotationDocument {
    /// 今の画像の座標で範囲を受け、その範囲を新しい画像にする。範囲が1px未満なら何もしない。
    /// 完全に外れた注釈だけ消す。またがる注釈は残し、今の配置の規則で新しい画像へ合わせる。
    public func cropping(to rect: CGRect, imageSize: CGSize) -> AnnotationDocument? {
        let image = CGRect(origin: .zero, size: imageSize)
        let local = rect.standardized.integral.intersection(image)
        guard !local.isNull, local.width >= 1, local.height >= 1, local != image else { return nil }
        let style = self.style()
        let kept = intersecting(local, style: style)
        let size = local.size
        let delta = CGPoint(x: -local.minX, y: -local.minY)
        var result = self
        result.crop = AnnotationCrop(rect: local.offsetBy(dx: crop?.rect.minX ?? 0, dy: crop?.rect.minY ?? 0))
        // 番号は残った注釈で振り直る。札の幅を測る前に一覧を入れ替える。
        result.annotations = annotations.filter { kept.contains($0.id) }.map { annotation in
            var moved = annotation.translated(by: delta)
            moved.leaderTarget = annotation.leaderTarget.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
            return moved
        }.filter {
            // 矩形選択の判定は角の外も含む。蛍光ペンは線が新しい画像に見えるものだけ残す。
            $0.tool != .highlighter || AnnotationGeometry.highlighterShows($0, in: CGRect(origin: .zero, size: size), style: style)
        }
        let placing = result
        result.annotations = placing.annotations.map { annotation in
            var moved = annotation
            switch moved.tool {
            case .mosaic:
                // 押し戻すと隠していた場所から外れる。はみ出た分を切る。
                moved.start = AnnotationGeometry.clamped(moved.start, to: size)
                moved.end = AnnotationGeometry.clamped(moved.end, to: size)
            case .rectangle, .spotlight:
                moved = AnnotationGeometry.clampingAreaPoints(moved, square: false, imageSize: size, scale: scale)
            case .highlighter:
                // 点を端へ寄せると縁に沿った線になる。分けると重なりで色が二重になる。点は残し、描画で画像の中へ切る。
                break
            default:
                moved = AnnotationGeometry.placed(moved, bounds: placing.bounds(of: moved, style: style), imageSize: size, scale: scale)
            }
            return moved
        }
        return result
    }
}

extension AnnotationGeometry {

    /// 折れ線の上で、始点から全長の半分だけ進んだ点。
    static func pointAtHalfLength(_ points: [CGPoint]) -> CGPoint {
        let segments = Array(zip(points, points.dropFirst()))
        var remaining = segments.reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } / 2
        for (a, b) in segments {
            let length = hypot(b.x - a.x, b.y - a.y)
            if length > 0, remaining <= length {
                return CGPoint(x: a.x + (b.x - a.x) * remaining / length, y: a.y + (b.y - a.y) * remaining / length)
            }
            remaining -= length
        }
        return points.first ?? .zero
    }

    /// 蛍光ペンが画像に見える所まで移動量を縮める。今見えていない線は制限しない。
    static func visibleHighlighterMovement(_ delta: CGPoint, highlighters: [Annotation], image: CGRect, style: AnnotationStyle) -> CGPoint {
        let stays = highlightersStayVisible(highlighters, image: image, style: style)
        func shows(_ scale: Double) -> Bool { stays(CGPoint(x: delta.x * scale, y: delta.y * scale)) }
        guard !shows(1) else { return delta }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if shows(middle) { low = middle } else { high = middle }
        }
        return CGPoint(x: delta.x * low, y: delta.y * low)
    }

    /// 移動量を受け、今見えている蛍光ペンがその移動の後も見えるかを返す。今見えていない線は制限しない。
    static func highlightersStayVisible(_ highlighters: [Annotation], image: CGRect, style: AnnotationStyle) -> (CGPoint) -> Bool {
        // 跡は一度だけ作り、線を動かす代わりに画像を逆向きへずらして測る。
        let traces = highlighters.filter { $0.tool == .highlighter && highlighterShows($0, in: image, style: style) }
            .map { highlighterVisibleTrace($0, style: style) }
        return { delta in
            let moved = image.offsetBy(dx: -delta.x, dy: -delta.y)
            return traces.allSatisfy { $0.contains { convexPolygon($0, overlaps: moved) } }
        }
    }
}
