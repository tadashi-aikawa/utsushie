import Testing
import CoreGraphics
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

@Test(arguments: [0, 3, 8, 101])
func ownEditorSheetPopoverAndMenuCanBeSelectedAtAnyLayer(_ layer: Int) {
    let policy = CaptureWindowPolicy(ownProcessID: 42, excludedWindowIDs: [10])
    #expect(policy.canSelect(windowID: 100, processID: 42, layer: layer, alpha: 1))
    #expect(!policy.canSelect(windowID: 100, processID: 42, layer: layer, alpha: 0))
    #expect(!policy.canSelect(windowID: 10, processID: 42, layer: layer, alpha: 1))
}

@Test func hostedRecordingStatusMatchesItsOwnFrameOnly() {
    // macOS 26の使い捨てNSStatusItemとSCShareableContentから得た実枠。
    let status = CGRect(x: 1056, y: 0, width: 38, height: 39)
    let hosted = CGRect(x: 1057, y: 1, width: 36, height: 37)
    func matches(_ frame: CGRect, layer: Int = 25, bundle: String? = "com.apple.controlcenter") -> Bool {
        CaptureWindowPolicy.matchesHostedStatusWindow(frame: frame, layer: layer, bundleIdentifier: bundle,
                                                      statusFrame: status, statusBarLayer: 25)
    }
    #expect(matches(hosted))
    #expect(matches(status))
    #expect(!matches(hosted.offsetBy(dx: 36, dy: 0)))
    #expect(!matches(CGRect(x: 0, y: 0, width: 1800, height: 39)))
    #expect(!matches(hosted, layer: 24))
    #expect(!matches(hosted, bundle: "com.apple.systemuiserver"))
    #expect(!matches(hosted, bundle: nil))
    #expect(!CaptureWindowPolicy.matchesHostedStatusWindow(frame: .zero, layer: 25,
        bundleIdentifier: "com.apple.controlcenter", statusFrame: .zero, statusBarLayer: 25))
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
