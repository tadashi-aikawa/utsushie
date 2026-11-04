import CoreGraphics
import Foundation

/// 元録画の秒数の区間で、元録画の左上原点のピクセル座標の矩形へ寄せる。出力の寸法は変えない。
public struct VideoZoom: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var range: VideoRange
    /// 出力と同じ縦横比の、元録画のピクセル座標の矩形。
    public var rect: CGRect
    /// 寄るときと戻るときの補間の秒数。区間ごとに持ち、0〜2秒を0.1秒刻みに丸める。
    public private(set) var ease: Double
    public init(range: VideoRange, rect: CGRect, ease: Double = VideoZoom.defaultEase, id: UUID = UUID()) {
        self.range = range; self.rect = rect; self.ease = Self.clampedEase(ease); self.id = id
    }
    public mutating func setEase(_ seconds: Double) { ease = Self.clampedEase(seconds) }

    /// 補間の秒数の既定。
    public static let defaultEase = 0.3
    public static let maximumEase = 2.0
    public static func clampedEase(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return defaultEase }
        return (min(maximumEase, max(0, seconds)) * 10).rounded() / 10
    }
    /// 置くときの区間の長さの目安。
    public static let initialDuration = 2.0
    /// 置く・伸縮するときの最短の区間。
    public static let minimumDuration = 0.1
    /// 寄せすぎて画素が荒れないよう、矩形の幅を元録画の1/8までに留める。
    public static let maximumScale = 8.0

    /// 実際の補間の長さ。区間が短いときは半分ずつに縮める。
    public var ramp: Double { min(ease, max(0, range.duration) / 2) }
    public func scale(size: CGSize) -> Double { rect.width > 0 ? Double(size.width / rect.width) : 1 }

    /// 区間の中で寄っている割合。ease-in-outで0から1へ寄り、1から0へ戻る。区間外は0。補間が0秒なら区間の中は常に1。
    public func progress(at time: Double) -> Double {
        guard range.contains(time) else { return 0 }
        guard ramp > 0 else { return 1 }
        let linear: Double
        if time < range.start + ramp { linear = (time - range.start) / ramp }
        else if time > range.end - ramp { linear = (range.end - time) / ramp }
        else { linear = 1 }
        let t = min(1, max(0, linear))
        return t * t * (3 - 2 * t)
    }

    /// 表示する元録画の範囲。寄っていなければnil。
    public func crop(at time: Double, size: CGSize) -> CGRect? {
        let value = progress(at: time)
        guard value > 0 else { return nil }
        return Self.interpolated(from: CGRect(origin: .zero, size: size), to: rect, value)
    }

    public static func interpolated(from a: CGRect, to b: CGRect, _ t: Double) -> CGRect {
        let t = CGFloat(t)
        return CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                      width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    /// 押した点を角に固定し、今の点の向きへ出力と同じ縦横比で広げる。幅と高さのうち比に対して大きいほうへ合わせる。
    /// 元録画の外へ出る分は起点を動かさずにカーソル側で止める。最小寸法が起点から収まらないときだけ内側へ押し戻す。
    /// 元録画全体になるなら寄る意味がないのでnil。
    /// limitsScaleがfalseなら最小の幅を当てず、カーソルに沿った大きさを返す。ドラッグ中の枠に使い、跳ねて見せない。
    public static func anchored(from anchor: CGPoint, to point: CGPoint, size: CGSize, limitsScale: Bool = true) -> CGRect? {
        guard size.width > 0, size.height > 0, anchor.x.isFinite, anchor.y.isFinite, point.x.isFinite, point.y.isFinite else { return nil }
        let aspect = size.width / size.height
        let origin = CGPoint(x: min(size.width, max(0, anchor.x)), y: min(size.height, max(0, anchor.y)))
        let dx = point.x - origin.x, dy = point.y - origin.y
        let right = dx >= 0, down = dy >= 0
        let available = min(right ? size.width - origin.x : origin.x, (down ? size.height - origin.y : origin.y) * aspect)
        let follow = min(max(abs(dx), abs(dy) * aspect), available)
        let width = limitsScale ? max(follow, size.width / CGFloat(maximumScale)) : follow
        guard width > 0, width < size.width else { return nil }
        let height = width / aspect
        let x = min(size.width - width, max(0, right ? origin.x : origin.x - width))
        let y = min(size.height - height, max(0, down ? origin.y : origin.y - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 寸法を保って矩形を動かす。元録画の端で止める。deltaは元録画のピクセル。
    public static func moved(_ rect: CGRect, by delta: CGPoint, size: CGSize) -> CGRect {
        guard delta.x.isFinite, delta.y.isFinite else { return rect }
        let x = min(max(0, size.width - rect.width), max(0, rect.minX + delta.x))
        let y = min(max(0, size.height - rect.height), max(0, rect.minY + delta.y))
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// プレビューのmouseDownで決める操作。範囲選択の前回枠と同じく、⌥は押した時点だけで決め、途中の修飾変更では切り替えない。
    /// resizeの辺は表示(AppKitの左下原点)の向き。元録画の座標へは`flippedVertically`で直す。
    public enum Grab: Equatable, Sendable { case move, resize(LastFrameEdges), draw, none }
    /// gripは表示上の矩形に対する`LastFrameGrip.at`の結果。insideMovableは動かせる矩形の中か。
    /// ツール中は境界の内外6ptの縁を常にリサイズにし、⌥でも移動を優先しない。ツール外は⌥の移動だけ。
    public static func grab(tool: Bool, option: Bool, grip: LastFrameGrip?, insideMovable: Bool, insideVideo: Bool) -> Grab {
        if tool, case let .resize(edges) = grip { return .resize(edges) }
        guard insideVideo else { return .none }
        if option, insideMovable { return .move }
        return tool ? .draw : .none
    }
    /// ツール中は縁でリサイズの向き、⌥を押している間だけ矩形の中で開いた手。つかんだ後はその操作のカーソルを保つ。
    public static func cursor(tool: Bool, option: Bool, grip: LastFrameGrip?, insideMovable: Bool, insideVideo: Bool,
                              active: Grab = .none) -> CaptureCursor {
        switch active {
        case .move: return .closedHand
        case let .resize(edges): return .resize(edges)
        case .draw: return .crosshair
        case .none: break
        }
        if tool, case let .resize(edges) = grip { return .resize(edges) }
        if insideVideo, option, insideMovable { return .openHand }
        return tool && insideVideo ? .crosshair : .arrow
    }

    /// つかんだ辺を動かし、出力の縦横比を保ってリサイズする。edgesとrectは元録画の左上原点の座標。
    /// 角は反対の角、辺は反対の辺を固定し、辺では他方の軸の中心を保つ。比に対して大きいほうの軸へ合わせ、裏返さない。
    /// 幅は元録画の1/8から、固定した側から元録画の端までに制限する。中心を保つ軸がはみ出す分は内側へ押し戻す。
    public static func resized(_ rect: CGRect, edges: LastFrameEdges, by delta: CGPoint, size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0, delta.x.isFinite, delta.y.isFinite else { return rect }
        let aspect = size.width / size.height, minimum = size.width / CGFloat(maximumScale)
        let hasX = edges.contains(.minX) || edges.contains(.maxX), hasY = edges.contains(.minY) || edges.contains(.maxY)
        guard hasX || hasY else { return rect }
        let right = !edges.contains(.minX), down = !edges.contains(.minY)
        let fixedX = right ? rect.minX : rect.maxX, fixedY = down ? rect.minY : rect.maxY
        let wantedX = hasX ? rect.width + (right ? delta.x : -delta.x) : -CGFloat.infinity
        let wantedY = hasY ? (rect.height + (down ? delta.y : -delta.y)) * aspect : -CGFloat.infinity
        var limit = min(size.width, size.height * aspect)
        if hasX { limit = min(limit, right ? size.width - fixedX : fixedX) }
        if hasY { limit = min(limit, (down ? size.height - fixedY : fixedY) * aspect) }
        let width = min(max(max(wantedX, wantedY), minimum), max(limit, minimum))
        let height = width / aspect
        let x = hasX ? (right ? fixedX : fixedX - width) : rect.midX - width / 2
        let y = hasY ? (down ? fixedY : fixedY - height) : rect.midY - height / 2
        return CGRect(x: min(size.width - width, max(0, x)), y: min(size.height - height, max(0, y)), width: width, height: height)
    }

    /// 矩形を、中心を保って出力と同じ縦横比へ広げ、元録画の中へ収める。区間へ持つ前の正規化に使う。
    /// 広げた結果が元録画全体なら寄る意味がないのでnil。
    public static func fitted(_ drag: CGRect, size: CGSize) -> CGRect? {
        let drag = drag.standardized
        guard size.width > 0, size.height > 0, drag.width.isFinite, drag.height.isFinite,
              drag.width > 0 || drag.height > 0 else { return nil }
        let aspect = size.width / size.height
        var width = max(drag.width, drag.height * aspect, size.width / CGFloat(maximumScale))
        width = min(size.width, width)
        let height = width / aspect
        guard width < size.width else { return nil }
        let x = min(size.width - width, max(0, drag.midX - width / 2))
        let y = min(size.height - height, max(0, drag.midY - height / 2))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

extension LastFrameEdges {
    /// 表示(AppKitの左下原点)の辺を、元録画の左上原点の辺へ直す。上下だけが入れ替わる。
    public var flippedVertically: LastFrameEdges {
        var result = intersection([.minX, .maxX])
        if contains(.minY) { result.insert(.maxY) }
        if contains(.maxY) { result.insert(.minY) }
        return result
    }
}

/// 書き出しで1枚のコマを描く区間。cropがnilなら元のコマをそのまま使う。
public struct VideoZoomPiece: Equatable, Sendable {
    public var source: VideoRange
    public var crop: CGRect?
    public init(source: VideoRange, crop: CGRect?) { self.source = source; self.crop = crop }
}

/// 出力の時間単位へ丸めた、1枚のコマを描く区間。endは次のコマのstartと同じ。
public struct VideoZoomOutputPiece: Equatable, Sendable {
    public var start: Int64
    public var end: Int64
    public var crop: CGRect?
    public init(start: Int64, end: Int64, crop: CGRect?) { self.start = start; self.end = end; self.crop = crop }
}

extension Array where Element == VideoZoom {
    public func zoom(at time: Double) -> VideoZoom? { first { $0.range.contains(time) } }
    public func crop(at time: Double, size: CGSize) -> CGRect? { zoom(at: time)?.crop(at: time, size: size) }

    /// 元録画の区間を、寄り方が変わらない区間ごとに分ける。補間中はfpsのコマ間隔を超えないよう同じコマを複数回描く。
    public func pieces(source: VideoRange, fps: Int, size: CGSize) -> [VideoZoomPiece] {
        guard source.duration > 0 else { return [] }
        let interval = 1 / Double(Swift.max(1, fps))
        var points = [source.start, source.end]
        for zoom in self {
            for point in [zoom.range.start, zoom.range.start + zoom.ramp, zoom.range.end - zoom.ramp, zoom.range.end]
            where point > source.start && point < source.end { points.append(point) }
        }
        points = Set(points).sorted()
        var result: [VideoZoomPiece] = []
        for (a, b) in zip(points, points.dropFirst()) where b > a {
            let middle = (a + b) / 2
            var parts = [VideoRange(a, b)]
            if let zoom = zoom(at: middle), middle < zoom.range.start + zoom.ramp || middle >= zoom.range.end - zoom.ramp {
                let count = Swift.max(1, Int(((b - a) / interval - 1e-9).rounded(.up)))
                parts = (0..<count).map { index in
                    VideoRange(a + (b - a) * Double(index) / Double(count), index == count - 1 ? b : a + (b - a) * Double(index + 1) / Double(count))
                }
            }
            for part in parts {
                let crop = crop(at: part.start, size: size)
                // 寄り方が同じ隣の区間はまとめ、変化のない所で余分なコマを足さない。
                if let last = result.last, last.crop == crop, last.source.end == part.start {
                    result[result.count - 1].source.end = part.end
                } else { result.append(VideoZoomPiece(source: part, crop: crop)) }
            }
        }
        return result
    }
}
