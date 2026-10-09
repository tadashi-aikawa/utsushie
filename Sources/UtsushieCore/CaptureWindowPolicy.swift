import CoreGraphics

/// 撮影用UIだけを窓番号で除外する。未登録の自アプリの窓は撮影できる。
public struct CaptureWindowPolicy: Sendable {
    public let ownProcessID: Int32
    public let excludedWindowIDs: Set<UInt32>

    public init(ownProcessID: Int32, excludedWindowIDs: Set<UInt32>) {
        self.ownProcessID = ownProcessID
        self.excludedWindowIDs = excludedWindowIDs
    }

    public func excludes(windowID: UInt32) -> Bool {
        excludedWindowIDs.contains(windowID)
    }

    public func canSelect(windowID: UInt32, processID: Int32?, layer: Int, alpha: Double) -> Bool {
        guard alpha > 0, !excludes(windowID: windowID) else { return false }
        // 編集パネル・シート・メニューも選べるよう、自アプリは通常層に限定しない。
        // 他アプリのDock・メニューバーなどは従来どおり対象外にする。
        return layer == 0 || processID == ownProcessID
    }

    public static func matchesHostedStatusWindow(frame: CGRect, layer: Int, bundleIdentifier: String?,
                                                 statusFrame: CGRect, statusBarLayer: Int) -> Bool {
        // macOS 26ではNSStatusBarWindowが仮想番号を返し、実窓はControl Centerが持つ。
        // 実測では実窓の枠がAppKitの枠から1pt内側。範囲・所有者・層をすべて照合する。
        guard bundleIdentifier == "com.apple.controlcenter", layer == statusBarLayer,
              statusFrame.width > 2, statusFrame.height > 2 else { return false }
        return frame == statusFrame || frame == statusFrame.insetBy(dx: 1, dy: 1)
    }
}
