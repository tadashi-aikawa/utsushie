import AppKit
import ApplicationServices
import os
import Testing
import UtsushieCore
@testable import Utsushie

/// 戻らないAX呼び出しが1回あっても、キューを作り直して以後の問い合わせを塞がない。
@MainActor @Test func elementReaderRecoversFromStalledRead() async {
    let gate = DispatchSemaphore(value: 0)
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let reader = AccessibilityElementReader(stallLimit: .milliseconds(100)) { query, _ in
        if calls.withLock({ $0 += 1; return $0 }) == 1 { gate.wait() }
        return ElementSelection(nodes: [CaptureElementNode(rect: CGRect(x: 0, y: 0, width: 10, height: 10), label: "ボタン")],
                                point: query.point, visibleBounds: query.visibleBounds)
    }
    defer { gate.signal() }
    let query = AccessibilityElementReader.Query(point: CGPoint(x: 5, y: 5), windowID: 1, processID: 1,
                                                 windowBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
    #expect(await reader.selection(for: query).selected == nil)
    #expect(await reader.selection(for: query).selected?.label == "ボタン")
}

/// 読み取りが戻らなくても、取り消した問い合わせは見張りを待たずに返る。
@MainActor @Test func elementReaderReturnsCancelledReadImmediately() async throws {
    let gate = DispatchSemaphore(value: 0)
    let started = DispatchSemaphore(value: 0)
    let reader = AccessibilityElementReader(stallLimit: .seconds(30)) { _, _ in
        started.signal(); gate.wait()
        return ElementSelection()
    }
    defer { gate.signal() }
    let query = AccessibilityElementReader.Query(point: CGPoint(x: 5, y: 5), windowID: 1, processID: 1,
                                                 windowBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
    let stalled = Task { await reader.selection(for: query) }
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { started.wait(); continuation.resume() }
    }
    let clock = ContinuousClock()
    let start = clock.now
    stalled.cancel()
    #expect(await stalled.value.selected == nil)
    // 見張りの30秒より十分短ければよい。並列実行の混雑で揺れる数百msは許す。
    #expect(start.duration(to: clock.now) < .seconds(5))
}

/// 時間切れにした要求は、見捨てたキューが後で動き出してもAXを読み始めない。
@MainActor @Test func elementReaderSkipsTimedOutRequestOnAbandonedQueue() async throws {
    let gate = DispatchSemaphore(value: 0)
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let readsAfterRelease = OSAllocatedUnfairLock(initialState: [Bool]())
    let reader = AccessibilityElementReader(stallLimit: .milliseconds(100)) { _, request in
        if calls.withLock({ $0 += 1; return $0 }) == 1 { gate.wait(); return ElementSelection() }
        readsAfterRelease.withLock { $0.append(request.isCancelled) }
        return ElementSelection()
    }
    let query = AccessibilityElementReader.Query(point: CGPoint(x: 5, y: 5), windowID: 1, processID: 1,
                                                 windowBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
    async let first = reader.selection(for: query)
    async let queued = reader.selection(for: query)
    _ = await (first, queued)
    gate.signal()
    for _ in 0..<100 where readsAfterRelease.withLock({ $0.isEmpty }) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(readsAfterRelease.withLock { $0 } == [true])
}

/// 取り消した問い合わせの読み取りが戻らなくても、見張りがキューを作り直す。
@MainActor @Test func elementReaderDetectsStallOfCancelledRead() async throws {
    let gate = DispatchSemaphore(value: 0)
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let reader = AccessibilityElementReader(stallLimit: .milliseconds(100)) { query, request in
        if calls.withLock({ $0 += 1; return $0 }) == 1 { gate.wait() }
        guard !request.isCancelled else { return ElementSelection() }
        return ElementSelection(nodes: [CaptureElementNode(rect: CGRect(x: 0, y: 0, width: 10, height: 10), label: "ボタン")],
                                point: query.point, visibleBounds: query.visibleBounds)
    }
    defer { gate.signal() }
    let query = AccessibilityElementReader.Query(point: CGPoint(x: 5, y: 5), windowID: 1, processID: 1,
                                                 windowBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
    let stalled = Task { await reader.selection(for: query) }
    try await Task.sleep(for: .milliseconds(20))
    stalled.cancel()
    #expect(await stalled.value.selected == nil)
    try await Task.sleep(for: .milliseconds(300))
    #expect(await reader.selection(for: query).selected?.label == "ボタン")
}

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
    #expect(overlay.state.cursor == .arrow)
    #expect(overlay.cursor === NSCursor.arrow)
    let help = overlay.elementHint
    try key(36) // 取得前に押しても前回範囲は撮らない。
    #expect(captures.isEmpty)
    try await Task.sleep(for: .milliseconds(250))
    let firstHighlight = try #require(overlay.highlighted?.rect)
    #expect(overlay.elementHint == help)
    // 読み取りを待つ間もカーソルと操作案内は変えない。
    for step in 1...10 {
        CGWarpMouseCursorPosition(CGPoint(x: point.x + CGFloat(step), y: point.y))
        overlay.mouseMoved()
        #expect(overlay.cursor === NSCursor.arrow)
        #expect(overlay.elementHint == help)
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(overlay.cursor === NSCursor.arrow)
    try await Task.sleep(for: .milliseconds(250))
    #expect(overlay.cursor === NSCursor.arrow)
    #expect(overlay.elementHint == help)
    CGWarpMouseCursorPosition(point)
    overlay.mouseMoved()
    try await Task.sleep(for: .milliseconds(250))
    overlay.mouseDown()
    CGWarpMouseCursorPosition(CGPoint(x: point.x + 30, y: point.y))
    overlay.mouseDragged()
    #expect(overlay.state.target == .element && overlay.selection == nil)
    overlay.mouseUp()
    try await Task.sleep(for: .milliseconds(250))
    #expect(captures.isEmpty)
    CGWarpMouseCursorPosition(point)
    overlay.mouseMoved()
    try await Task.sleep(for: .milliseconds(250))
    // 移動のたびに全画面を暗くせず、次の結果まで前の枠を表示だけ残す。
    let nextPoint = CGPoint(x: bounds.minX + 310, y: point.y)
    CGWarpMouseCursorPosition(nextPoint)
    overlay.mouseMoved()
    #expect(overlay.highlighted?.rect == firstHighlight)
    try key(36)
    #expect(overlay.elementHint == help)
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
