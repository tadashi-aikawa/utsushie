import AppKit
import Testing
@testable import Utsushie

@MainActor @Test func captureUIWindowClassesAreExplicitlyExcluded() throws {
    _ = NSApplication.shared
    let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
    let windows: [NSWindow] = [
        CapturePanel(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false),
        RecordingBorderPanel(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false),
        ThumbnailPanel(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false),
        AnnotationEditorWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false),
        VideoEditorWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false),
        NSWindow(contentRect: rect, styleMask: .titled, backing: .buffered, defer: false)
    ]
    for window in windows { window.isReleasedWhenClosed = false }
    defer { windows.forEach { $0.close() } }
    let excluded = CaptureWindowExclusion.windows()
    for window in windows.prefix(3) { #expect(excluded.contains { $0 === window }) }
    for window in windows.suffix(3) { #expect(!excluded.contains { $0 === window }) }
    let policy = CaptureWindowExclusion.policy(for: excluded)
    for window in windows.prefix(3) {
        #expect(policy.excludes(windowID: try #require(UInt32(exactly: window.windowNumber))))
    }
}

@MainActor @Test func newCardWaitsForExclusionAndHiddenCardNeverReappears() async throws {
    _ = NSApplication.shared
    let artifact = SharedArtifact(url: URL(fileURLWithPath: "/tmp/utsushie-window-test.webp"),
                                  kind: .webP, width: 100, height: 100, byteCount: 0)
    let card = ThumbnailCard(artifact: artifact, image: nil, copied: false, seconds: 5, finalizing: false)
    defer { card.close() }
    var continuation: CheckedContinuation<Bool, Never>?
    card.prepareToShow = { Task { await withCheckedContinuation { continuation = $0 } } }
    card.show(claimKeyboard: false)
    #expect(!card.panel.isVisible && card.timer == nil)
    for _ in 0..<100 where continuation == nil { await Task.yield() }
    let ready = try #require(continuation)
    ready.resume(returning: true)
    for _ in 0..<100 where !card.panel.isVisible { await Task.yield() }
    #expect(card.panel.isVisible && card.timer != nil)
    card.hide()
    continuation = nil
    card.show(claimKeyboard: false)
    for _ in 0..<100 where continuation == nil { await Task.yield() }
    let pending = try #require(continuation)
    card.hide()
    pending.resume(returning: true)
    for _ in 0..<100 { await Task.yield() }
    #expect(!card.panel.isVisible && card.timer == nil)
}

@MainActor @Test func cardStaysHiddenWhenExclusionFails() async {
    _ = NSApplication.shared
    let artifact = SharedArtifact(url: URL(fileURLWithPath: "/tmp/utsushie-window-test.webp"),
                                  kind: .webP, width: 100, height: 100, byteCount: 0)
    let card = ThumbnailCard(artifact: artifact, image: nil, copied: false, seconds: 5, finalizing: false)
    defer { card.close() }
    card.prepareToShow = { Task { false } }
    card.show(claimKeyboard: false)
    for _ in 0..<100 { await Task.yield() }
    #expect(!card.panel.isVisible && card.timer == nil)
}
