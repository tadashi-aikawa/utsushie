import CoreGraphics
import Foundation

/// 撮った画像を最前面に浮かべるウィンドウの寸法・位置・拡大縮小・不透明度。座標はAppKitの画面座標。
public enum ImagePinGeometry {
    /// 拡大縮小で短辺をこれより小さくしない。×とドラッグする領域を残すため。
    public static let minimumSide: Double = 48
    public static let maximumZoom: Double = 8
    public static let minimumOpacity: Double = 0.2
    /// 見える範囲の縁に残す余白。
    public static let margin: Double = 8
    /// 画像の外側の台紙の幅。台紙と枠で囲うと元の画面に枠線を足しただけに見えたので、置かずに影で浮かせる。
    public static let mat: Double = 0
    /// 画像の外の透明な余白。影と押しピンの頭をパネルの中に描くため。
    /// 影の範囲は半透明なのでクリックを下へ通さない。完全に透明な所のクリックは下へ通る。
    /// 遠くへ落とす影はぼかし28pt・下へ10ptまで、押しピンの頭は画像の上端から約26pt上まで出る。
    /// 出てくるときのピンは2.4倍から縮むので、頭は上端から約67pt上まで出る。
    public static let shadowMargin: Double = 80

    /// 画像の枠から、台紙と影を含むパネルの枠へ。
    public static func panelFrame(image: CGRect) -> CGRect {
        image.insetBy(dx: -(mat + shadowMargin), dy: -(mat + shadowMargin))
    }
    /// パネルの枠から、画像の枠へ。
    public static func imageFrame(panel: CGRect) -> CGRect {
        panel.insetBy(dx: mat + shadowMargin, dy: mat + shadowMargin)
    }

    /// 撮影時の見た目の寸法。倍率が分からない画像は1xとして扱う。
    public static func pointSize(pixels: CGSize, scale: Double?) -> CGSize {
        let scale = max(1, scale ?? 1)
        return CGSize(width: max(1, pixels.width / scale), height: max(1, pixels.height / scale))
    }

    /// 撮った範囲があればその中心に、なければ画面の中央に置く。見える範囲へ収まらなければ縦横比を保って縮める。
    /// 寸法が撮った範囲と同じなら、範囲にぴったり重なる。
    public static func initialFrame(size: CGSize, anchor: CGRect?, visible: CGRect) -> CGRect {
        let area = visible.insetBy(dx: margin, dy: margin)
        let fit = min(1, area.width / size.width, area.height / size.height)
        let fitted = CGSize(width: size.width * fit, height: size.height * fit)
        let center = anchor.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: visible.midX, y: visible.midY)
        let frame = CGRect(x: center.x - fitted.width / 2, y: center.y - fitted.height / 2, width: fitted.width, height: fitted.height)
        return clamped(frame, into: area)
    }

    /// 見える範囲の中へ押し戻す。範囲より大きい軸は範囲の端へ揃える。
    public static func clamped(_ frame: CGRect, into area: CGRect) -> CGRect {
        var result = frame
        result.origin.x = frame.width >= area.width ? area.minX : min(max(frame.minX, area.minX), area.maxX - frame.width)
        result.origin.y = frame.height >= area.height ? area.maxY - frame.height : min(max(frame.minY, area.minY), area.maxY - frame.height)
        return result
    }

    /// 元の寸法に対する倍率の範囲。小さい画像は元より縮めず、大きい画像も短辺48ptまでは縮められる。
    public static func zoomRange(natural: CGSize) -> ClosedRange<Double> {
        let lower = min(1, minimumSide / max(1, min(natural.width, natural.height)))
        return lower...maximumZoom
    }

    /// `point`を固定して倍率を`factor`倍にする。縦横比は元の寸法のまま。
    public static func zoomed(_ frame: CGRect, by factor: Double, around point: CGPoint, natural: CGSize) -> CGRect {
        guard factor.isFinite, factor > 0, frame.width > 0, frame.height > 0 else { return frame }
        let range = zoomRange(natural: natural)
        let current = frame.width / natural.width
        let zoom = min(max(current * factor, range.lowerBound), range.upperBound)
        let size = CGSize(width: natural.width * zoom, height: natural.height * zoom)
        let u = (point.x - frame.minX) / frame.width, v = (point.y - frame.minY) / frame.height
        return CGRect(x: point.x - size.width * u, y: point.y - size.height * v, width: size.width, height: size.height)
    }

    /// 倍率を100%へ戻す。今の中心を保ち、撮影時の見た目の寸法にする。
    public static func actualSize(_ frame: CGRect, natural: CGSize) -> CGRect {
        CGRect(x: frame.midX - natural.width / 2, y: frame.midY - natural.height / 2, width: natural.width, height: natural.height)
    }

    /// 縦のスクロール量から拡大縮小の倍率を決める。上へ回すと大きくなる。
    public static func zoomFactor(scrollDelta: Double, precise: Bool) -> Double {
        exp(scrollDelta * (precise ? 0.01 : 0.1))
    }

    /// 縦のスクロール量で不透明度を変える。上へ回すと濃くなる。
    public static func opacity(_ current: Double, scrollDelta: Double, precise: Bool) -> Double {
        let step = scrollDelta * (precise ? 0.005 : 0.05)
        return min(1, max(minimumOpacity, current + step))
    }

    /// 左上原点のビュー座標で、右上の×の矩形。
    public static func closeButton(in size: CGSize) -> CGRect {
        let side = min(22, max(14, min(size.width, size.height) / 3))
        let inset = min(8, max(3, min(size.width, size.height) / 8))
        return CGRect(x: size.width - inset - side, y: inset, width: side, height: side)
    }

    /// 変えた直後に左下へ出す値のバッジ。
    public static func zoomLabel(frame: CGRect, natural: CGSize) -> String {
        "\(Int((frame.width / natural.width * 100).rounded()))%"
    }
    public static func opacityLabel(_ opacity: Double) -> String {
        "不透明度 \(Int((opacity * 100).rounded()))%"
    }
}

/// 浮かべた画像の出てき方。押しピンが手前から縮んで刺さり、刺さった瞬間から影が広がって画像が持ち上がる。
/// 画像は最初から影なしで出ているので、撮った範囲にぴったり重なっていれば初めは何も変わらないように見える。
public enum ImagePinEntrance {
    /// ピンが手前から刺さるまで。
    public static let approach: Double = 0.2
    /// 刺さった後に少し沈んで戻るまで。影と並んで進む。
    public static let settle: Double = 0.075
    /// 刺さった瞬間から、影が広がりきるまで。
    public static let lift: Double = 0.3
    public static var duration: Double { approach + lift }
    /// 手前にいるときのピンの大きさ。
    public static let startScale: Double = 2.4
    /// 刺さった瞬間に沈む大きさ。
    public static let impactScale: Double = 0.9
    /// 持ち上がる途中で画像が膨らむ大きさ。撮った範囲から一瞬ずれるが、近づいた感じを出す。
    public static let swell: Double = 1.015
    /// 膨らみきる位置。持ち上がる長さのうちの割合。
    static let swellPeak: Double = 0.45
    /// ピンが見えるようになるまで。
    static let fadeIn: Double = 0.05

    public struct Frame: Equatable, Sendable {
        /// ピンの大きさ。針の先を中心に掛ける。
        public var pinScale: Double
        public var pinOpacity: Double
        /// ピンがどれだけ画面に近いか。0は手前、1は刺さった所。ピンの影の遠さに使う。
        public var pinNear: Double
        /// 画像の影と外縁の進み具合。0は影なし、1は止まったときの影。
        public var lift: Double
        /// 画像の大きさ。中心を保って掛ける。
        public var imageScale: Double

        public static let rest = Frame(pinScale: 1, pinOpacity: 1, pinNear: 1, lift: 1, imageScale: 1)
    }

    /// 浮かべてから`time`秒後の見た目。範囲の外は止まったときの見た目にする。
    public static func frame(at time: Double) -> Frame {
        guard time.isFinite, time < duration else { return .rest }
        let t = max(0, time)
        var frame = Frame.rest
        guard t >= approach else {
            // 加速しながら近づき、画面に当たる。
            let near = easeIn(t / approach)
            frame.pinScale = startScale + (1 - startScale) * near
            frame.pinNear = near
            frame.pinOpacity = min(1, t / fadeIn)
            frame.lift = 0
            return frame
        }
        let after = t - approach
        let half = settle / 2
        if after < half {
            frame.pinScale = 1 + (impactScale - 1) * easeOut(after / half)
        } else if after < settle {
            frame.pinScale = impactScale + (1 - impactScale) * ((after - half) / half)
        }
        let rise = after / lift
        frame.lift = easeOut(rise)
        let grow = rise < swellPeak ? smoothstep(rise / swellPeak) : 1 - smoothstep((rise - swellPeak) / (1 - swellPeak))
        frame.imageScale = 1 + (swell - 1) * grow
        return frame
    }

    static func easeIn(_ x: Double) -> Double { let y = min(1, max(0, x)); return y * y * y }
    static func easeOut(_ x: Double) -> Double { let y = 1 - min(1, max(0, x)); return 1 - y * y * y }
    static func smoothstep(_ x: Double) -> Double { let y = min(1, max(0, x)); return y * y * (3 - 2 * y) }
}
