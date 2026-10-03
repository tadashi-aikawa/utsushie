import Foundation
import CoreGraphics
import Testing
@testable import UtsushieCore

@Test(arguments: [CGPoint(x: 0, y: 0), CGPoint(x: 0.1, y: 0.1), CGPoint(x: 4, y: 0), CGPoint(x: 0, y: -4)])
func smallMovementCancelsAreaCapture(_ delta: CGPoint) {
    var state = CaptureState()
    let start = CGPoint(x: 100.2, y: 100.2)
    let end = CGPoint(x: start.x + delta.x, y: start.y + delta.y)
    #expect(state.pointerDown(at: start, last: nil) == .none)
    state.pointerDragged(to: end)
    #expect(state.gesture.areaPreview == nil)
    #expect(state.pointerUp(at: end) == .cancel)
    #expect(state.pointerUp(at: end) == .none)
}

@Test func diagonalMovementUsesPointDistance() {
    var state = CaptureState()
    _ = state.pointerDown(at: .zero, last: nil)
    #expect(state.pointerUp(at: CGPoint(x: 3, y: 4)) == .captureArea(CGRect(x: 0, y: 0, width: 3, height: 4)))
}

@Test func areaDragCapturesOnlyOnRelease() {
    var state = CaptureState()
    _ = state.pointerDown(at: CGPoint(x: 100, y: 100), last: nil)
    state.pointerDragged(to: CGPoint(x: 80, y: 60))
    #expect(state.gesture.areaPreview == CGRect(x: 80, y: 60, width: 20, height: 40))
    #expect(state.pointerUp(at: CGPoint(x: 80, y: 60)) == .captureArea(CGRect(x: 80, y: 60, width: 20, height: 40)))
    #expect(state.gesture.areaPreview == nil)
}

@Test func clickInsidePreviousAreaCancelsWithoutMovingIt() {
    var state = CaptureState()
    let last = CGRect(x: 100, y: 100, width: 400, height: 300)
    _ = state.pointerDown(at: CGPoint(x: 150, y: 150), last: last)
    state.pointerDragged(to: CGPoint(x: 152, y: 152))
    #expect(state.gesture.lastPreview == nil)
    #expect(state.pointerUp(at: CGPoint(x: 152, y: 152)) == .cancel)
}

@Test func draggingPreviousAreaCommitsPositionOnlyOnRelease() {
    var state = CaptureState()
    let last = CGRect(x: 100, y: 100, width: 400, height: 300)
    _ = state.pointerDown(at: CGPoint(x: 150, y: 150), last: last)
    state.pointerDragged(to: CGPoint(x: 160, y: 170))
    let moved = last.offsetBy(dx: 10, dy: 20)
    #expect(state.gesture.lastPreview == moved)
    #expect(state.gesture.areaPreview == nil)
    #expect(state.pointerUp(at: CGPoint(x: 160, y: 170)) == .moveLast(moved))
}

@Test(arguments: [false, true])
func escapeDuringDragPreventsLaterMouseUp(_ movingLast: Bool) {
    var state = CaptureState()
    let last = movingLast ? CGRect(x: 100, y: 100, width: 400, height: 300) : nil
    _ = state.pointerDown(at: CGPoint(x: 150, y: 150), last: last)
    state.pointerDragged(to: CGPoint(x: 170, y: 190))
    #expect(state.key(53, hasLast: movingLast) == .cancel)
    #expect(state.gesture.areaPreview == nil)
    #expect(state.gesture.lastPreview == nil)
    state.pointerDragged(to: CGPoint(x: 180, y: 200))
    #expect(state.pointerUp(at: CGPoint(x: 180, y: 200)) == .none)
}

@Test func windowClickStillCapturesImmediately() {
    var state = CaptureState()
    _ = state.key(13, hasLast: false)
    #expect(state.pointerDown(at: CGPoint(x: 100, y: 100), last: nil) == .captureWindow)
    #expect(state.pointerUp(at: CGPoint(x: 100, y: 100)) == .none)
}

@Test func videoClickCancelsAndDragRemainsUnavailable() {
    var state = CaptureState()
    _ = state.key(48, hasLast: false)
    _ = state.pointerDown(at: .zero, last: nil)
    #expect(state.pointerUp(at: .zero) == .cancel)
    _ = state.pointerDown(at: .zero, last: nil)
    #expect(state.pointerUp(at: CGPoint(x: 10, y: 10)) == .videoUnavailable)
}
