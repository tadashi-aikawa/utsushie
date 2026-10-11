import AppKit
import ApplicationServices
import Testing
import UtsushieCore
@testable import Utsushie

/// 検証専用ChromeのPIDを明示したときだけ、実AXと撮影パネルの併用を検証する。
/// 普段のテストは利用者のChromeを探したり操作したりしない。
@MainActor @Test func chromeElementLiveProbeWithCapturePanel() async throws {
    guard let rawPID = ProcessInfo.processInfo.environment["UTSUSHIE_CHROME_PROBE_PID"], let pid = Int32(rawPID) else { return }
    let zoom = Double(ProcessInfo.processInfo.environment["UTSUSHIE_CHROME_PROBE_ZOOM"] ?? "1") ?? 1
    #expect(AXIsProcessTrusted())
    func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
    func rect(_ element: AXUIElement) throws -> CGRect {
        let p = try #require(attr(element, kAXPositionAttribute)), s = try #require(attr(element, kAXSizeAttribute))
        try #require(CFGetTypeID(p) == AXValueGetTypeID() && CFGetTypeID(s) == AXValueGetTypeID())
        var point = CGPoint.zero, size = CGSize.zero
        try #require(AXValueGetValue(p as! AXValue, .cgPoint, &point))
        try #require(AXValueGetValue(s as! AXValue, .cgSize, &size))
        return CGRect(origin: point, size: size)
    }
    let app = AXUIElementCreateApplication(pid)
    let windows = try #require(attr(app, kAXWindowsAttribute) as? [AXUIElement])
    let window = try #require(windows.first { attr($0, kAXMainAttribute) as? Bool == true } ?? windows.first)
    let windowRect = try rect(window)
    var queue = [window], index = 0
    var web: AXUIElement?
    while index < queue.count && index < 200 {
        let element = queue[index]; index += 1
        if attr(element, kAXRoleAttribute) as? String == "AXWebArea" { web = element; break }
        queue += attr(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    let page = try #require(web)
    try #require(attr(page, kAXTitleAttribute) as? String == "UTSUSHIE AX probe 01a12a28")
    let viewport = try rect(page)
    let list = try #require(CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]])
    let cgWindow = try #require(list.first { item in
        guard item[kCGWindowOwnerPID as String] as? Int32 == pid,
              let b = item[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: b as CFDictionary) else { return false }
        return ElementSelection.matches(bounds, windowRect, tolerance: 1)
    })
    let id = try #require(cgWindow[kCGWindowNumber as String] as? UInt32)
    let reader = AccessibilityElementReader()
    func query(_ x: CGFloat, _ y: CGFloat) -> AccessibilityElementReader.Query {
        .init(point: CGPoint(x: viewport.minX + x * zoom, y: viewport.minY + y * zoom), windowID: id, processID: pid, windowBounds: windowRect)
    }
    if ProcessInfo.processInfo.environment["UTSUSHIE_CHROME_PROBE_SCROLLED"] == "1" {
        // fixtureの#scrollで100 CSS pxスクロールした、上端が切れたカード。
        let afterScroll = await reader.selection(for: query(90, 25))
        let clippedCard = CGRect(x: viewport.minX + 40 * zoom, y: viewport.minY, width: 360 * zoom, height: 100 * zoom)
        #expect(afterScroll.candidates.contains { ElementSelection.matches($0.rect, clippedCard) })
        let image = try await CaptureService().image(for: .region(ScreenGeometry.appKit(clippedCard)), downscale: true, excluding: [])
        #expect(image.width == Int(360 * zoom) && image.height == Int(100 * zoom))
        if let output = ProcessInfo.processInfo.environment["UTSUSHIE_CHROME_PROBE_IMAGE"] {
            try WebPEncoder.encode(image, quality: 85, lossless: false).write(to: URL(fileURLWithPath: output))
        }
        return
    }
    // 文字の上はChromeの遅延ヒットテストで文字→ボタンへ変わりうる。ボタンのpaddingを使う。
    let button = await reader.selection(for: query(62, 65))
    let expectedCard = CGRect(x: viewport.minX + 40 * zoom, y: viewport.minY + 40 * zoom, width: 360 * zoom, height: 160 * zoom)
    #expect(button.selected?.label == "ボタン")
    #expect(button.candidates.contains { ElementSelection.matches($0.rect, expectedCard) })
    let toolbar = await reader.selection(for: .init(point: CGPoint(x: windowRect.midX, y: windowRect.minY + 55),
        windowID: id, processID: pid, windowBounds: windowRect))
    #expect(toolbar.selected != nil)

    let panel = CapturePanel(contentRect: ScreenGeometry.appKit(windowRect), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false; panel.backgroundColor = NSColor.black.withAlphaComponent(0.4)
    panel.ignoresMouseEvents = false; panel.level = .screenSaver
    panel.orderFrontRegardless(); panel.makeKey()
    defer { panel.close() }
    try await Task.sleep(for: .milliseconds(100))
    let withOverlay = await reader.selection(for: query(62, 65))
    #expect(withOverlay.candidates == button.candidates)
    let image = try await CaptureService().image(for: .region(ScreenGeometry.appKit(expectedCard)), downscale: true, excluding: [panel])
    #expect(image.width == Int(360 * zoom) && image.height == Int(160 * zoom))
    if let output = ProcessInfo.processInfo.environment["UTSUSHIE_CHROME_PROBE_IMAGE"] {
        try WebPEncoder.encode(image, quality: 85, lossless: false).write(to: URL(fileURLWithPath: output))
    }
    panel.close()

    // AppKitのlocal monitorまで通す。合成イベントは検証プロセスに直接渡し、Chromeへキーを送らない。
    let originalPoint = NSEvent.mouseLocation
    let pointer = query(62, 65).point
    CGWarpMouseCursorPosition(pointer)
    let overlay = OverlayController()
    defer {
        overlay.close()
        CGWarpMouseCursorPosition(CGPoint(x: originalPoint.x, y: ScreenGeometry.primaryHeight - originalPoint.y))
    }
    overlay.show(last: nil)
    func key(_ code: UInt16) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: code == 125 || code == 126 ? [.function] : [], timestamp: 0,
            windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code))
        NSApp.sendEvent(event)
    }
    try key(14)
    #expect(overlay.state.target == .element)
    try await Task.sleep(for: .milliseconds(200))
    #expect(overlay.highlighted != nil)
    let firstRect = overlay.highlighted?.rect
    try key(126)
    #expect(overlay.highlighted?.rect == ScreenGeometry.appKit(expectedCard))
    try key(125)
    #expect(overlay.highlighted?.rect == firstRect)
    try key(126)
    var captured: CGRect?
    overlay.onCapture = { request, remembered, output in
        captured = request.rect
        #expect(!remembered && output == .image)
    }
    CGWarpMouseCursorPosition(CGPoint(x: pointer.x + 1, y: pointer.y + 1))
    overlay.mouseMoved()
    #expect(overlay.highlighted?.rect == ScreenGeometry.appKit(expectedCard))
    overlay.mouseDown(); overlay.mouseUp()
    try await Task.sleep(for: .milliseconds(200))
    #expect(captured == ScreenGeometry.appKit(expectedCard))
    try key(14)
    #expect(overlay.state.target == .area)
    try key(14)
    try await Task.sleep(for: .milliseconds(200))
    try key(126)
    CGWarpMouseCursorPosition(query(90, 125).point)
    overlay.mouseMoved()
    try key(125)
    try await Task.sleep(for: .milliseconds(200))
    let movedPoint = query(90, 125).point
    #expect(overlay.highlighted?.rect.contains(CGPoint(x: movedPoint.x, y: ScreenGeometry.primaryHeight - movedPoint.y)) == true)
    captured = nil
    overlay.mouseDown(); overlay.mouseUp()
    try key(53)
    try await Task.sleep(for: .milliseconds(100))
    #expect(!overlay.isVisible)
    #expect(captured == nil)

}
