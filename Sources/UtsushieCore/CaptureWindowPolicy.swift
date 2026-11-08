/// 撮影用UIだけをウィンドウ番号で除外する。未登録の自アプリのウィンドウは撮影できる。
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

    /// 前もって取ったウィンドウの一覧は、今の撮影用UIがすべて載っているときだけ使える。閉じたウィンドウが残っていても除外は崩れない。
    public func canReuse(listedWindowIDs: Set<UInt32>) -> Bool {
        excludedWindowIDs.isSubset(of: listedWindowIDs)
    }

    /// スクロール撮影で外すDock本体のウィンドウか。`dockLayer`はDockのウィンドウのレイヤー。
    /// - 理由: 自動非表示のDockが範囲の下端に出ると、横幅いっぱいではないので固定のフッターにならず、継ぎ目ごとに写り込むため
    /// - レイヤー: Dockは壁紙のウィンドウも持つので、アプリだけでなくレイヤーでも絞る
    public static func isDock(bundleIdentifier: String?, layer: Int, dockLayer: Int) -> Bool {
        bundleIdentifier == "com.apple.dock" && layer == dockLayer
    }

    public func canSelect(windowID: UInt32, processID: Int32?, layer: Int, alpha: Double) -> Bool {
        guard alpha > 0, !excludes(windowID: windowID) else { return false }
        // 編集パネル・シート・メニューも選べるよう、自アプリは通常レイヤーに限定しない。
        // 他アプリのDock・メニューバーなどは従来どおり対象外にする。
        return layer == 0 || processID == ownProcessID
    }
}
