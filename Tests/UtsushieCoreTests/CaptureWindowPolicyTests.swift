import Testing
@testable import UtsushieCore

@Test func captureExcludesOnlyNamedOwnWindows() {
    let policy = CaptureWindowPolicy(ownProcessID: 42, excludedWindowIDs: [10, 11, 12, 13])
    for id: UInt32 in [10, 11, 12, 13] {
        #expect(policy.excludes(windowID: id))
        #expect(!policy.canSelect(windowID: id, processID: 42, layer: 0, alpha: 1))
        #expect(!policy.canSelect(windowID: id, processID: 42, layer: 25, alpha: 1))
    }
    // 編集窓・一覧・今後追加する窓を許可する。ホワイトリストにはしない。
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

@Test func emptyBlacklistIncludesAllOwnWindows() {
    let policy = CaptureWindowPolicy(ownProcessID: 42, excludedWindowIDs: [])
    #expect(!policy.excludes(windowID: 100))
    #expect(policy.canSelect(windowID: 100, processID: 42, layer: 3, alpha: 1))
}
