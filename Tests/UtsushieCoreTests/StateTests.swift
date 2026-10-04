import Foundation
import Testing
@testable import UtsushieCore

@Test func initialStateHasNoDelay() {
    let state = CaptureState()
    #expect(state.target == .area)
    #expect(state.output == .image)
    #expect(state.highlightsWindow)
}
@Test func enterAndHotkeyRequirePreviousArea() {
    var state = CaptureState()
    #expect(state.key(36, hasLast: false) == .none)
    #expect(state.repeatCapture(hasLast: false) == .none)
    #expect(state.key(36, hasLast: true) == .captureLast)
    #expect(state.target == .last)
    #expect(state.repeatCapture(hasLast: true) == .captureLast)
}
@Test func targetAndOutputAreIndependent() {
    var state = CaptureState()
    #expect(state.key(13, hasLast: false) == .none)
    #expect(state.target == .area)
    #expect(state.key(48, hasLast: false) == .none)
    #expect(state.target == .area)
    #expect(state.output == .video)
    #expect(state.key(36, hasLast: true) == .captureLast)
    #expect(state.target == .last)
    #expect(state.key(8, hasLast: true) == .captureChrome)
    #expect(state.target == .chrome)
    #expect(state.key(48, hasLast: true) == .none)
    #expect(state.key(8, hasLast: true) == .captureChrome)
    #expect(state.target == .chrome)
    state.fallbackToArea()
    #expect(state.target == .area)
    #expect(state.key(53, hasLast: true) == .cancel)
}
@Test func unknownPhysicalKeyDoesNothing() {
    var state = CaptureState()
    #expect(state.key(123, hasLast: true) == .none)
    #expect(state.target == .area)
}
@Test func selectionCursorFollowsTargetAcrossImageVideoAndFallback() {
    var state = CaptureState()
    #expect(state.cursor == .crosshair)
    #expect(state.key(48, hasLast: false) == .none)
    #expect(state.output == .video)
    #expect(state.cursor == .crosshair)
    #expect(state.key(13, hasLast: false) == .none)
    #expect(state.cursor == .crosshair)
    #expect(state.key(48, hasLast: false) == .none)
    #expect(state.output == .image)
    #expect(state.cursor == .crosshair)
    state.fallbackToArea()
    #expect(state.cursor == .crosshair)
    #expect(state.key(13, hasLast: false) == .none)
    #expect(state.repeatCapture(hasLast: true) == .captureLast)
    #expect(state.cursor == .crosshair)
    #expect(state.key(8, hasLast: true) == .captureChrome)
    state.fallbackToArea()
    #expect(state.cursor == .crosshair)
    #expect(state.pointerDown(at: .zero, last: nil) == .none)
    state.pointerDragged(to: CGPoint(x: 20, y: 30))
    #expect(state.cursor == .crosshair)
}
@Test func fileNameUsesLocalTimeAndSerial() {
    let date = Date(timeIntervalSince1970: 0)
    #expect(CaptureFileNaming.name(date: date, timeZone: TimeZone(secondsFromGMT: 9 * 3600)!) == "utsushie-19700101-090000.webp")
    #expect(CaptureFileNaming.name(date: date, sequence: 2, timeZone: TimeZone(secondsFromGMT: 0)!) == "utsushie-19700101-000000-2.webp")
    #expect(CaptureFileNaming.name(date: date, extension: "mp4", timeZone: TimeZone(secondsFromGMT: 0)!) == "utsushie-19700101-000000.mp4")
}
