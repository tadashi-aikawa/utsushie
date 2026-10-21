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

    /// 前もって取った窓の一覧は、今の撮影用UIがすべて載っているときだけ使える。閉じた窓が残っていても除外は崩れない。
    public func canReuse(listedWindowIDs: Set<UInt32>) -> Bool {
        excludedWindowIDs.isSubset(of: listedWindowIDs)
    }

    public func canSelect(windowID: UInt32, processID: Int32?, layer: Int, alpha: Double) -> Bool {
        guard alpha > 0, !excludes(windowID: windowID) else { return false }
        // 編集パネル・シート・メニューも選べるよう、自アプリは通常層に限定しない。
        // 他アプリのDock・メニューバーなどは従来どおり対象外にする。
        return layer == 0 || processID == ownProcessID
    }
}
