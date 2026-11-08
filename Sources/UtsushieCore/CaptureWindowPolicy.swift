import CoreGraphics

/// 外すかを決めるための、一覧に載ったウィンドウ。座標はCG/SCKの左上原点。
public struct ListedWindow: Sendable, Equatable {
    public let id: UInt32
    public let processID: Int32?
    public let layer: Int
    public let frame: CGRect
    public init(id: UInt32, processID: Int32?, layer: Int, frame: CGRect) {
        self.id = id; self.processID = processID; self.layer = layer; self.frame = frame
    }
}

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

    /// スクロール撮影で外す、ほかのアプリの小さい付属ウィンドウ。ChromeのURLの吹き出しやツールチップ。
    /// - 判定: 通常レイヤーで高さが`overlayHeight`未満で、同じアプリの通常レイヤーのより大きいウィンドウに面積の9割以上が重なる
    ///     - 理由: 吹き出しはページと別のウィンドウで、スクロールしても動かず、継ぎ目ごとに写り込むため
    ///     - 9割: Chromeの吹き出しは親のウィンドウの左端から1ptはみ出していたため
    ///     - 高さ: 同じアプリの小さいウィンドウを大きいウィンドウの上に重ねた場合に、撮りたいウィンドウを外さないため
    ///     - 通常レイヤー: メニューバーや録画中の印のような、システムが持つ小さいウィンドウを外さないため
    /// - 自アプリ: 撮影用UIの除外に任せ、ここでは外さない
    public static func scrollOverlayIDs(_ windows: [ListedWindow], ownProcessID: Int32) -> Set<UInt32> {
        func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
        let normal = windows.filter { $0.layer == 0 }
        var result = Set<UInt32>()
        for window in normal {
            guard let pid = window.processID, pid != ownProcessID,
                  window.frame.height < overlayHeight, area(window.frame) > 0 else { continue }
            let own = area(window.frame)
            if normal.contains(where: { parent in
                parent.id != window.id && parent.processID == pid && area(parent.frame) > own
                    && area(parent.frame.intersection(window.frame)) >= own * 0.9
            }) { result.insert(window.id) }
        }
        return result
    }
    /// 付属ウィンドウとみなす高さの上限。吹き出しは22pt、検索バーなども収まる。
    public static let overlayHeight: CGFloat = 64

    public func canSelect(windowID: UInt32, processID: Int32?, layer: Int, alpha: Double) -> Bool {
        guard alpha > 0, !excludes(windowID: windowID) else { return false }
        // 編集パネル・シート・メニューも選べるよう、自アプリは通常レイヤーに限定しない。
        // 他アプリのDock・メニューバーなどは従来どおり対象外にする。
        return layer == 0 || processID == ownProcessID
    }
}
