import CoreGraphics
import Testing
@testable import UtsushieCore

@Test func captureExcludesOnlyNamedOwnWindows() {
    let policy = CaptureWindowPolicy(ownProcessID: 42, excludedWindowIDs: [10, 11, 12, 13])
    for id: UInt32 in [10, 11, 12, 13] {
        #expect(policy.excludes(windowID: id))
        #expect(!policy.canSelect(windowID: id, processID: 42, layer: 0, alpha: 1))
        #expect(!policy.canSelect(windowID: id, processID: 42, layer: 25, alpha: 1))
    }
    // 編集ウィンドウ・一覧・今後追加するウィンドウを許可する。ホワイトリストにはしない。
    #expect(!policy.excludes(windowID: 100))
    #expect(!policy.excludes(windowID: 101))
}

@Test func prefetchedWindowListIsReusedOnlyWhenItListsEveryCaptureUI() {
    let policy = CaptureWindowPolicy(ownProcessID: 42, excludedWindowIDs: [10, 11])
    #expect(policy.canReuse(listedWindowIDs: [10, 11, 200]))
    // 先読みの後に閉じたカードが一覧に残っていてもよい。
    #expect(policy.canReuse(listedWindowIDs: [9, 10, 11]))
    // 先読みの後に出た新しいカードが無ければ取り直す。
    #expect(!policy.canReuse(listedWindowIDs: [10, 200]))
    #expect(CaptureWindowPolicy(ownProcessID: 42, excludedWindowIDs: []).canReuse(listedWindowIDs: []))
}

@Test(arguments: [0, 3, 8, 101])
func ownEditorSheetPopoverAndMenuCanBeSelectedAtAnyLayer(_ layer: Int) {
    let policy = CaptureWindowPolicy(ownProcessID: 42, excludedWindowIDs: [10])
    #expect(policy.canSelect(windowID: 100, processID: 42, layer: layer, alpha: 1))
    #expect(!policy.canSelect(windowID: 100, processID: 42, layer: layer, alpha: 0))
    #expect(!policy.canSelect(windowID: 10, processID: 42, layer: layer, alpha: 1))
}

@Test func otherApplicationsKeepNormalWindowSelectionRules() {
    let policy = CaptureWindowPolicy(ownProcessID: 42, excludedWindowIDs: [10])
    #expect(policy.canSelect(windowID: 100, processID: 99, layer: 0, alpha: 1))
    #expect(!policy.canSelect(windowID: 100, processID: 99, layer: 3, alpha: 1))
    #expect(!policy.canSelect(windowID: 100, processID: 99, layer: 25, alpha: 1))
    #expect(!policy.canSelect(windowID: 100, processID: 99, layer: 0, alpha: 0))
}

@Test func scrollCaptureExcludesOnlyTheDockItself() {
    #expect(CaptureWindowPolicy.isDock(bundleIdentifier: "com.apple.dock", layer: 20, dockLayer: 20))
    // Dockが持つ壁紙のウィンドウは外さない。
    #expect(!CaptureWindowPolicy.isDock(bundleIdentifier: "com.apple.dock", layer: -2147483624, dockLayer: 20))
    #expect(!CaptureWindowPolicy.isDock(bundleIdentifier: "com.google.Chrome", layer: 20, dockLayer: 20))
    #expect(!CaptureWindowPolicy.isDock(bundleIdentifier: nil, layer: 20, dockLayer: 20))
}

@Test func scrollCaptureExcludesSmallOverlaysOfTheSameApp() {
    // 実測のChrome: 本体は0,39の1800×1130、URLの吹き出しは左端から1ptはみ出した367×22。
    let chrome = ListedWindow(id: 1, processID: 7, layer: 0, frame: CGRect(x: 0, y: 39, width: 1800, height: 1130))
    let bubble = ListedWindow(id: 2, processID: 7, layer: 0, frame: CGRect(x: -1, y: 1148, width: 367, height: 22))
    // 別アプリの小さいウィンドウ、同じアプリでも本体の外の小さいウィンドウ、本体に重ねた小さめのブラウザは外さない。
    let other = ListedWindow(id: 3, processID: 8, layer: 0, frame: CGRect(x: 100, y: 100, width: 300, height: 22))
    let outside = ListedWindow(id: 4, processID: 7, layer: 0, frame: CGRect(x: 0, y: 0, width: 1800, height: 39))
    let smallBrowser = ListedWindow(id: 5, processID: 7, layer: 0, frame: CGRect(x: 200, y: 200, width: 800, height: 600))
    let own = ListedWindow(id: 6, processID: 42, layer: 0, frame: CGRect(x: 10, y: 10, width: 100, height: 20))
    let ownParent = ListedWindow(id: 7, processID: 42, layer: 0, frame: CGRect(x: 0, y: 0, width: 500, height: 500))
    // 実測のシステム: 全画面の裏のウィンドウに重なるメニューバー(レイヤー24)と録画中の印は外さない。
    let systemBack = ListedWindow(id: 8, processID: 9, layer: 24, frame: CGRect(x: 0, y: 0, width: 1800, height: 1169))
    let menubar = ListedWindow(id: 9, processID: 9, layer: 24, frame: CGRect(x: 0, y: 0, width: 1800, height: 39))
    let indicator = ListedWindow(id: 10, processID: 9, layer: 2147483630, frame: CGRect(x: 1769, y: 3, width: 28, height: 28))
    #expect(CaptureWindowPolicy.scrollOverlayIDs([chrome, bubble, other, outside, smallBrowser, own, ownParent, systemBack, menubar, indicator],
                                                 ownProcessID: 42) == [2])
}

@Test func emptyBlacklistIncludesAllOwnWindows() {
    let policy = CaptureWindowPolicy(ownProcessID: 42, excludedWindowIDs: [])
    #expect(!policy.excludes(windowID: 100))
    #expect(policy.canSelect(windowID: 100, processID: 42, layer: 3, alpha: 1))
}
