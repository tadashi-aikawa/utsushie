import AppKit
import ApplicationServices
import Testing
import UtsushieCore
@testable import Utsushie

/// Tests/Fixtures/NativeElements.swiftをコンパイルした実行ファイルを指定して検証する。
@MainActor @Test func nativeAccessibilityElementProbe() async throws {
    guard let executable = ProcessInfo.processInfo.environment["UTSUSHIE_NATIVE_AX_PROBE"] else { return }
    try #require(AXIsProcessTrusted())
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    try await Task.sleep(for: .seconds(1))
    let windows = try #require(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])
    let window = try #require(windows.first {
        $0[kCGWindowOwnerPID as String] as? Int32 == process.processIdentifier &&
        $0[kCGWindowLayer as String] as? Int == 0
    })
    let rawBounds = try #require(window[kCGWindowBounds as String] as? [String: Any])
    let bounds = try #require(CGRect(dictionaryRepresentation: rawBounds as CFDictionary))
    let id = try #require(window[kCGWindowNumber as String] as? UInt32)
    let point = CGPoint(x: bounds.minX + 130, y: bounds.maxY - 120)
    let query = AccessibilityElementReader.Query(point: point, windowID: id,
        processID: process.processIdentifier, windowBounds: bounds)
    let selection = await AccessibilityElementReader().selection(for: query)
    #expect(selection.selected?.label == "ボタン")
    let selected = try #require(selection.selected)
    #expect(selected.rect.contains(point))
    #expect(query.windowBounds.contains(selected.rect))
    let mismatch = AccessibilityElementReader.Query(point: point, windowID: query.windowID,
        processID: query.processID, windowBounds: query.windowBounds.offsetBy(dx: 50, dy: 0))
    #expect(await AccessibilityElementReader().selection(for: mismatch).selected == nil)

    let originalPoint = NSEvent.mouseLocation
    CGWarpMouseCursorPosition(point)
    let overlay = OverlayController()
    defer {
        overlay.close()
        CGWarpMouseCursorPosition(CGPoint(x: originalPoint.x, y: ScreenGeometry.primaryHeight - originalPoint.y))
    }
    let last = CGRect(x: 5, y: 5, width: 20, height: 20)
    overlay.show(last: last)
    func key(_ code: UInt16) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        NSApp.sendEvent(event)
    }
    var captures: [(CGRect, Bool, CaptureOutput)] = []
    overlay.onCapture = { captures.append(($0.rect, $1, $2)) }
    try key(14)
    try key(36) // 取得前に押しても前回範囲は撮らない。
    #expect(captures.isEmpty)
    try await Task.sleep(for: .milliseconds(250))
    let firstHighlight = try #require(overlay.highlighted?.rect)
    // 移動のたびに全画面を暗くせず、次の結果まで前の枠を表示だけ残す。
    let nextPoint = CGPoint(x: bounds.minX + 310, y: point.y)
    CGWarpMouseCursorPosition(nextPoint)
    overlay.mouseMoved()
    #expect(overlay.highlighted?.rect == firstHighlight)
    try key(36)
    #expect(captures.isEmpty)
    overlay.mouseDown(); overlay.mouseUp()
    #expect(captures.isEmpty)
    try await Task.sleep(for: .milliseconds(250))
    #expect(captures.isEmpty)
    let nextHighlight = try #require(overlay.highlighted?.rect)
    #expect(nextHighlight != firstHighlight)
    #expect(nextHighlight.contains(CGPoint(x: nextPoint.x, y: ScreenGeometry.primaryHeight - nextPoint.y)))
    CGWarpMouseCursorPosition(CGPoint(x: nextPoint.x + 1, y: nextPoint.y))
    overlay.mouseMoved()
    #expect(overlay.highlighted?.rect == nextHighlight)
    try await Task.sleep(for: .milliseconds(250))
    #expect(overlay.highlighted?.rect == nextHighlight)
    CGWarpMouseCursorPosition(point)
    overlay.mouseMoved()
    try await Task.sleep(for: .milliseconds(250))
    try key(126)
    let parent = try #require(overlay.highlighted?.rect)
    try key(36)
    try await Task.sleep(for: .milliseconds(250))
    #expect(captures.count == 1)
    #expect(captures.last?.0 == parent && captures.last?.1 == false && captures.last?.2 == .image)
    try key(48)
    try await Task.sleep(for: .milliseconds(250))
    try key(126)
    let videoParent = try #require(overlay.highlighted?.rect)
    try key(76)
    try await Task.sleep(for: .milliseconds(250))
    #expect(captures.count == 2)
    #expect(captures.last?.0 == videoParent && captures.last?.1 == false && captures.last?.2 == .video)
    try key(14)
    try key(36)
    #expect(captures.last?.0 == last && captures.last?.1 == true)
}
