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
}
