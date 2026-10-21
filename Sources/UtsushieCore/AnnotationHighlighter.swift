import CoreGraphics

/// 蛍光ペンは、平らなペン先の縦の帯を点列に沿って動かした跡で塗る。
/// 描画・当たり判定・見え方の判定は、どれも区間ごとの帯の跡(凸多角形)を使う。
public extension AnnotationStyle {
    /// ペン先の帯の幅。高さは線の太さ。
    var highlighterTipWidth: Double { highlighterWidth * 0.3 }
    var highlighterTip: CGSize { CGSize(width: highlighterTipWidth, height: highlighterWidth) }
}

extension AnnotationGeometry {
    /// 区間ごとに、両端の帯を包む凸多角形。動いていない線は塗らない。
    public static func highlighterTrace(_ points: [CGPoint], tip: CGSize) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        _ = highlighterTraceContains(points, tip: tip) { result.append($0); return false }
        return result
    }
    /// 区間の跡を1つずつ作り、条件を満たした所で打ち切る。判定で全区間を作らないため。
    private static func highlighterTraceContains(_ points: [CGPoint], tip: CGSize, where match: ([CGPoint]) -> Bool) -> Bool {
        func bar(_ p: CGPoint) -> [CGPoint] {
            let left = p.x - tip.width / 2, right = p.x + tip.width / 2, top = p.y - tip.height / 2, bottom = p.y + tip.height / 2
            return [CGPoint(x: left, y: top), CGPoint(x: right, y: top), CGPoint(x: right, y: bottom), CGPoint(x: left, y: bottom)]
        }
        var previous: CGPoint?
        for p in points {
            guard let a = previous else { previous = p; continue }
            if a == p { continue }
            if match(convexHull(bar(a) + bar(p))) { return true }
            previous = p
        }
        return false
    }

    /// 見え方の判定に使う跡。1px以上かかるかを測るため、帯を各辺1pxずつ縮める。
    static func highlighterVisibleTrace(_ annotation: Annotation, style: AnnotationStyle) -> [[CGPoint]] {
        highlighterTrace(annotation.points, tip: visibleTip(annotation, style: style))
    }
    private static func visibleTip(_ annotation: Annotation, style: AnnotationStyle) -> CGSize {
        let tip = style.forAnnotation(annotation).highlighterTip
        return CGSize(width: max(0, tip.width - 2), height: max(0, tip.height - 2))
    }

    /// 蛍光ペンが画像に1px以上かかるか。
    static func highlighterShows(_ annotation: Annotation, in image: CGRect, style: AnnotationStyle) -> Bool {
        highlighterTraceContains(annotation.points, tip: visibleTip(annotation, style: style)) { convexPolygon($0, overlaps: image) }
    }

    /// 当たり判定。帯を許容幅だけ広げた跡に点が入るか。
    static func highlighterContains(_ point: CGPoint, annotation: Annotation, style: AnnotationStyle, tolerance: Double) -> Bool {
        let tip = style.forAnnotation(annotation).highlighterTip
        let wide = CGSize(width: tip.width + tolerance * 2, height: tip.height + tolerance * 2)
        return highlighterTraceContains(annotation.points, tip: wide) { convexPolygon($0, overlaps: CGRect(origin: point, size: .zero)) }
    }

    /// 矩形選択。帯の跡が矩形と重なるか。
    static func highlighterIntersects(_ rect: CGRect, annotation: Annotation, style: AnnotationStyle) -> Bool {
        highlighterTraceContains(annotation.points, tip: style.forAnnotation(annotation).highlighterTip) { convexPolygon($0, overlaps: rect) }
    }

    /// 凸多角形と矩形の重なり。面積の無い多角形は辺の線分だけで測り、延長線上を含めない。
    static func convexPolygon(_ polygon: [CGPoint], overlaps image: CGRect) -> Bool {
        guard let first = polygon.first else { return false }
        let edges = Array(zip(polygon, polygon.dropFirst() + [first]))
        if edges.contains(where: { segmentIntersects(image, from: $0, to: $1) }) { return true }
        let area = edges.reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }
        guard abs(area) > 1e-9 else { return false }
        // 辺が交わらなければ、画像が多角形の中に丸ごと入っているときだけ重なる。
        let corner = CGPoint(x: image.minX, y: image.minY)
        let crosses = edges.map { a, b in (b.x - a.x) * (corner.y - a.y) - (b.y - a.y) * (corner.x - a.x) }
        return crosses.allSatisfy { $0 >= 0 } || crosses.allSatisfy { $0 <= 0 }
    }

    /// 単調連鎖法の凸包。どの区間も同じ向きに回るので、nonzeroで塗ると重なりは1回だけ塗られる。
    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}
