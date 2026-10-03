import Foundation
import CoreGraphics

public struct DisplayGeometry: Equatable, Sendable {
    public var id: UInt32
    /// AppKitのグローバル座標。原点は主ディスプレイ左下。
    public var frame: CGRect
    public var scale: Double
    public init(id: UInt32, frame: CGRect, scale: Double) {
        self.id = id; self.frame = frame; self.scale = scale
    }
}

public enum CaptureGeometry {
    /// CG/AXは主ディスプレイ左上原点。画面全体のmaxYで反転すると上方の副画面で誤る。
    public static func flip(_ rect: CGRect, primaryHeight: Double) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
    public static func selection(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).integral
    }
    public static func localSource(_ rect: CGRect, display: DisplayGeometry) -> CGRect {
        CGRect(x: rect.minX - display.frame.minX, y: display.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
    /// ディスプレイの隙間を含む範囲は有効。出力の隙間は黒にする。
    /// 一部が画面外になった前回範囲は無効。単一画面containsでは跨ぎを失う。
    public static func isVisible(_ rect: CGRect, displays: [DisplayGeometry]) -> Bool {
        guard rect.width >= 1, rect.height >= 1, rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return false }
        return [rect.minX, rect.maxX].allSatisfy { x in [rect.minY, rect.maxY].allSatisfy { y in
            displays.contains { $0.frame.minX <= x && x <= $0.frame.maxX && $0.frame.minY <= y && y <= $0.frame.maxY }
        }}
    }
    public static func outputSize(points: CGSize, scale: Double, downscale: Bool) -> (width: Int, height: Int) {
        let factor = downscale ? 1 : scale
        return (max(1, Int((points.width * factor).rounded())), max(1, Int((points.height * factor).rounded())))
    }
    /// 混在DPIの跨ぎ撮影では最大倍率に統一。低DPI側は拡大する。1xなら全画面で点=px。
    public static func scale(for rect: CGRect, displays: [DisplayGeometry], downscale: Bool) -> Double {
        downscale ? 1 : displays.filter { $0.frame.intersects(rect) }.map(\.scale).max() ?? 1
    }
}
