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
    /// 線幅を含む蛍光ペンが画像に1px以上かかるか。描画と同じく、平らな端の帯と丸い継ぎ目で測る。
    static func highlighterShows(_ annotation: Annotation, in image: CGRect, style: AnnotationStyle) -> Bool {
        let radius = max(0, style.forAnnotation(annotation).highlighterWidth / 2 - 1)
        // 同じ位置の点は向きを持たないので除く。描き始めには重なった点ができる。
        var points: [CGPoint] = []
        for p in annotation.points where points.last.map({ hypot(p.x - $0.x, p.y - $0.y) > 1e-9 }) ?? true { points.append(p) }
        guard points.count >= 2 else { return false }
        let units = zip(points, points.dropFirst()).map { a, b in
            let length = hypot(b.x - a.x, b.y - a.y)
            return CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
        }
        func offset(_ p: CGPoint, _ d: CGPoint, _ amount: Double) -> CGPoint { CGPoint(x: p.x + d.x * amount, y: p.y + d.y * amount) }
        for index in units.indices {
            var a = points[index], b = points[index + 1]
            let unit = units[index]
            // 線の両端は、1px以上かかるかを幅と同じく1px内側で測る。
            let trim = min(1, hypot(b.x - a.x, b.y - a.y) / 2)
            if index == 0 { a = offset(a, unit, trim) }
            if index == units.count - 1 { b = offset(b, unit, -trim) }
            let normal = CGPoint(x: -unit.y, y: unit.x)
            let band = [offset(a, normal, radius), offset(b, normal, radius), offset(b, normal, -radius), offset(a, normal, -radius)]
            if convexPolygon(band, overlaps: image) { return true }
        }
        // 継ぎ目は、曲がった外側に丸く足される扇形だけ。まっすぐ続く点では何も足さない。
        for index in 1..<points.count - 1 {
            let u1 = units[index - 1], u2 = units[index]
            let cross = u1.x * u2.y - u1.y * u2.x, dot = u1.x * u2.x + u1.y * u2.y
            if abs(cross) < 1e-9, dot > 0 { continue }
            let side = cross > 0 ? -1.0 : 1.0
            // 外側の向きを中心に、両方の帯の縁を結ぶ扇形。曲がりが急なほど開き、折り返しで半円になる。
            let edge = CGPoint(x: -u1.y * side, y: u1.x * side)
            let length = hypot(u1.x - u2.x, u1.y - u2.y)
            let outward = CGPoint(x: (u1.x - u2.x) / length, y: (u1.y - u2.y) / length)
            if sector(at: points[index], radius: radius, outward: outward, cosHalfAngle: edge.x * outward.x + edge.y * outward.y,
                      edges: [edge, CGPoint(x: -u2.y * side, y: u2.x * side)], overlaps: image) { return true }
        }
        return false
    }
    /// 180°以下の扇形と矩形の重なりを、角の包含・半径の辺・弧と矩形の辺の交点で解く。
    private static func sector(at center: CGPoint, radius: Double, outward: CGPoint, cosHalfAngle: Double, edges: [CGPoint],
                               overlaps image: CGRect) -> Bool {
        guard radius > 0 else { return false }
        func inAngle(_ p: CGPoint) -> Bool {
            let dx = p.x - center.x, dy = p.y - center.y, length = hypot(dx, dy)
            return length == 0 || (dx * outward.x + dy * outward.y) / length >= cosHalfAngle - 1e-9
        }
        let corners = [CGPoint(x: image.minX, y: image.minY), CGPoint(x: image.maxX, y: image.minY),
                       CGPoint(x: image.maxX, y: image.maxY), CGPoint(x: image.minX, y: image.maxY)]
        // 矩形の角が扇形の中にある。矩形が扇形に丸ごと入る場合も含む。
        if corners.contains(where: { hypot($0.x - center.x, $0.y - center.y) <= radius && inAngle($0) }) { return true }
        // 半径の辺が矩形を通る。扇形の中心や弧の両端が矩形の中にある場合も含む。
        if edges.contains(where: { segmentIntersects(image, from: center, to: CGPoint(x: center.x + $0.x * radius, y: center.y + $0.y * radius)) }) {
            return true
        }
        // 弧が矩形の辺と交わる。
        for (a, b) in zip(corners, corners.dropFirst() + [corners[0]]) {
            let d = CGPoint(x: b.x - a.x, y: b.y - a.y), f = CGPoint(x: a.x - center.x, y: a.y - center.y)
            let qa = d.x * d.x + d.y * d.y, qb = 2 * (f.x * d.x + f.y * d.y), qc = f.x * f.x + f.y * f.y - radius * radius
            let discriminant = qb * qb - 4 * qa * qc
            guard qa > 0, discriminant >= 0 else { continue }
            for t in [(-qb - discriminant.squareRoot()) / (2 * qa), (-qb + discriminant.squareRoot()) / (2 * qa)] where t >= 0 && t <= 1 {
                if inAngle(CGPoint(x: a.x + d.x * t, y: a.y + d.y * t)) { return true }
            }
        }
        return false
    }
    /// 凸多角形と矩形の重なり。面積の無い多角形は辺の線分だけで測り、延長線上を含めない。
    private static func convexPolygon(_ polygon: [CGPoint], overlaps image: CGRect) -> Bool {
        let edges = Array(zip(polygon, polygon.dropFirst() + [polygon[0]]))
        if edges.contains(where: { segmentIntersects(image, from: $0, to: $1) }) { return true }
        let area = edges.reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }
        guard abs(area) > 1e-9 else { return false }
        // 辺が交わらなければ、画像が多角形の中に丸ごと入っているときだけ重なる。
        let corner = CGPoint(x: image.minX, y: image.minY)
        let crosses = edges.map { a, b in (b.x - a.x) * (corner.y - a.y) - (b.y - a.y) * (corner.x - a.x) }
        return crosses.allSatisfy { $0 >= 0 } || crosses.allSatisfy { $0 <= 0 }
    }

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
        let highlighters = highlighters.filter { $0.tool == .highlighter && highlighterShows($0, in: image, style: style) }
        func shows(_ scale: Double) -> Bool {
            highlighters.allSatisfy { highlighterShows($0.translated(by: CGPoint(x: delta.x * scale, y: delta.y * scale)), in: image, style: style) }
        }
        guard !shows(1) else { return delta }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if shows(middle) { low = middle } else { high = middle }
        }
        return CGPoint(x: delta.x * low, y: delta.y * low)
    }
}
