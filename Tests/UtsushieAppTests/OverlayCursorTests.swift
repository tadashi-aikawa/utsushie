import AppKit
import Testing
@testable import Utsushie

@MainActor @Test func overlayTracksInactiveMouseEntryAndUsesSupportedCursorUpdateScope() throws {
    let view = OverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
    view.updateTrackingAreas()
    let movement = try #require(view.trackingAreas.first { $0.options.contains(.mouseMoved) })
    #expect(movement.options.contains(.activeAlways))
    #expect(movement.options.contains(.mouseEnteredAndExited))
    #expect(movement.options.contains(.enabledDuringMouseDrag))
    #expect(movement.options.contains(.inVisibleRect))
    let cursor = try #require(view.trackingAreas.first { $0.options.contains(.cursorUpdate) })
    // activeAlwaysでは通知されないため、カーソル更新の範囲はキーウィンドウにする。
    #expect(cursor.options.contains(.activeInKeyWindow))
    #expect(!cursor.options.contains(.activeAlways))
    #expect(cursor.options.contains(.inVisibleRect))
    // tracking area再構築後も、非アクティブ時の移動とカーソル更新を両方保つ。
    view.updateTrackingAreas()
    #expect(view.trackingAreas.filter { $0.options.contains(.mouseMoved) }.count == 1)
    #expect(view.trackingAreas.filter { $0.options.contains(.cursorUpdate) }.count == 1)
}
