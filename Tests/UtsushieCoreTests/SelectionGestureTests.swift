import Foundation
import CoreGraphics
import Testing
@testable import UtsushieCore

@Test(arguments: [CGPoint(x: 0, y: 0), CGPoint(x: 0.1, y: 0.1), CGPoint(x: 4, y: 0), CGPoint(x: 0, y: -4)], [false, true])
func smallMovementCapturesWindowOnlyOnRelease(_ delta: CGPoint, _ hasWindow: Bool) {
    var state = CaptureState()
    let start = CGPoint(x: 100.2, y: 100.2)
    let end = CGPoint(x: start.x + delta.x, y: start.y + delta.y)
    #expect(state.pointerDown(at: start, last: nil) == .none)
    state.pointerDragged(to: end)
    #expect(state.gesture.areaPreview == nil)
    #expect(state.highlightsWindow)
    #expect(state.pointerUp(at: end, hasWindow: hasWindow) == (hasWindow ? .captureWindow : .none))
    #expect(state.pointerUp(at: end, hasWindow: true) == .none)
}

@Test func diagonalMovementUsesPointDistance() {
    var state = CaptureState()
    _ = state.pointerDown(at: .zero, last: nil)
    #expect(state.pointerUp(at: CGPoint(x: 3, y: 4)) == .captureArea(CGRect(x: 0, y: 0, width: 3, height: 4)))
}

@Test(arguments: [false, true], [false, true])
func clickMovementKeepsPreviousAreaVisible(_ video: Bool, _ option: Bool) {
    var state = CaptureState()
    if video { _ = state.key(48, hasLast: true) }
    let last = CGRect(x: 100, y: 100, width: 400, height: 300)
    #expect(!state.gesture.isSelectingArea)
    _ = state.pointerDown(at: CGPoint(x: 150, y: 150), last: last, movingLast: option)
    state.pointerDragged(to: CGPoint(x: 154, y: 150))
    #expect(!state.gesture.isSelectingArea)
    #expect(state.gesture.lastPreview == nil)
    #expect(state.pointerUp(at: CGPoint(x: 154, y: 150), hasWindow: true) == .captureWindow)
    #expect(!state.gesture.isSelectingArea)
}

@Test(arguments: [false, true])
func newAreaDragHidesPreviousAreaUntilRelease(_ video: Bool) {
    var state = CaptureState()
    if video { _ = state.key(48, hasLast: true) }
    let last = CGRect(x: 100, y: 100, width: 400, height: 300)
    let start = CGPoint(x: 150, y: 150)
    _ = state.pointerDown(at: start, last: last)
    state.pointerDragged(to: CGPoint(x: 154.01, y: 150))
    #expect(state.gesture.isSelectingArea)
    state.pointerDragged(to: start)
    #expect(state.gesture.isSelectingArea)
    #expect(state.pointerUp(at: start, hasWindow: true) == .none)
    #expect(!state.gesture.isSelectingArea)

    _ = state.pointerDown(at: start, last: last)
    state.pointerDragged(to: CGPoint(x: 170, y: 190))
    #expect(state.gesture.isSelectingArea)
    #expect(state.key(53, hasLast: true) == .cancel)
    #expect(!state.gesture.isSelectingArea)
}

@Test(arguments: [false, true])
func optionDragKeepsMovingPreviousAreaVisible(_ video: Bool) {
    var state = CaptureState()
    if video { _ = state.key(48, hasLast: true) }
    let last = CGRect(x: 100, y: 100, width: 400, height: 300)
    _ = state.pointerDown(at: CGPoint(x: 150, y: 150), last: last, movingLast: true)
    state.pointerDragged(to: CGPoint(x: 170, y: 190))
    #expect(!state.gesture.isSelectingArea)
    #expect(state.gesture.lastPreview == last.offsetBy(dx: 20, dy: 40))
    #expect(state.pointerUp(at: CGPoint(x: 170, y: 190)) == .moveLast(last.offsetBy(dx: 20, dy: 40)))
    #expect(!state.gesture.isSelectingArea)

    _ = state.pointerDown(at: .zero, last: last, movingLast: true)
    state.pointerDragged(to: CGPoint(x: 20, y: 40))
    #expect(state.gesture.isSelectingArea)
    #expect(state.gesture.lastPreview == nil)
}

@Test func areaDragCapturesOnlyOnRelease() {
    var state = CaptureState()
    _ = state.pointerDown(at: CGPoint(x: 100, y: 100), last: nil)
    state.pointerDragged(to: CGPoint(x: 80, y: 60))
    #expect(!state.highlightsWindow)
    #expect(state.gesture.areaPreview == CGRect(x: 80, y: 60, width: 20, height: 40))
    #expect(state.pointerUp(at: CGPoint(x: 80, y: 60)) == .captureArea(CGRect(x: 80, y: 60, width: 20, height: 40)))
    #expect(state.gesture.areaPreview == nil)
    #expect(state.highlightsWindow)
}

@Test(arguments: [false, true], [false, true])
func clickInsidePreviousAreaCapturesWindowWithoutMovingIt(_ video: Bool, _ option: Bool) {
    var state = CaptureState()
    if video { _ = state.key(48, hasLast: true) }
    let last = CGRect(x: 100, y: 100, width: 400, height: 300)
    _ = state.pointerDown(at: CGPoint(x: 150, y: 150), last: last, movingLast: option)
    state.pointerDragged(to: CGPoint(x: 152, y: 152))
    #expect(state.gesture.lastPreview == nil)
    #expect(state.pointerUp(at: CGPoint(x: 152, y: 152), hasWindow: true) == .captureWindow)
    #expect(state.gesture.lastPreview == nil)
}

@Test func draggingPreviousAreaCommitsPositionOnlyOnRelease() {
    var state = CaptureState()
    let last = CGRect(x: 100, y: 100, width: 400, height: 300)
    _ = state.pointerDown(at: CGPoint(x: 150, y: 150), last: last, movingLast: true)
    state.pointerDragged(to: CGPoint(x: 160, y: 170))
    let moved = last.offsetBy(dx: 10, dy: 20)
    #expect(state.gesture.lastPreview == moved)
    #expect(state.gesture.areaPreview == nil)
    #expect(!state.highlightsWindow)
    #expect(state.pointerUp(at: CGPoint(x: 160, y: 170)) == .moveLast(moved))
}

@Test(arguments: [false, true])
func escapeDuringDragPreventsLaterMouseUp(_ movingLast: Bool) {
    var state = CaptureState()
    let last = movingLast ? CGRect(x: 100, y: 100, width: 400, height: 300) : nil
    _ = state.pointerDown(at: CGPoint(x: 150, y: 150), last: last, movingLast: movingLast)
    state.pointerDragged(to: CGPoint(x: 170, y: 190))
    #expect(state.key(53, hasLast: movingLast) == .cancel)
    #expect(state.gesture.areaPreview == nil)
    #expect(state.gesture.lastPreview == nil)
    state.pointerDragged(to: CGPoint(x: 180, y: 200))
    #expect(state.pointerUp(at: CGPoint(x: 180, y: 200)) == .none)
}

@Test(arguments: [false, true])
func clickWithoutWindowKeepsSelectionOpen(_ video: Bool) {
    var state = CaptureState()
    if video { _ = state.key(48, hasLast: false) }
    #expect(state.pointerDown(at: .zero, last: nil) == .none)
    #expect(state.pointerUp(at: .zero, hasWindow: false) == .none)
    #expect(state.highlightsWindow)
    #expect(state.target == .area)
    #expect(state.pointerDown(at: .zero, last: nil) == .none)
    #expect(state.pointerUp(at: .zero, hasWindow: true) == .captureWindow)
}

@Test func videoClickCapturesWindowAndDragSelectsArea() {
    var state = CaptureState()
    _ = state.key(48, hasLast: false)
    _ = state.pointerDown(at: .zero, last: nil)
    #expect(state.pointerUp(at: .zero, hasWindow: true) == .captureWindow)
    _ = state.pointerDown(at: .zero, last: nil)
    #expect(state.pointerUp(at: CGPoint(x: 10, y: 10), hasWindow: true) == .captureArea(CGRect(x: 0, y: 0, width: 10, height: 10)))
}

@Test func crossingThresholdKeepsAreaGestureEvenAfterReturningToStart() {
    var state = CaptureState()
    _ = state.pointerDown(at: .zero, last: nil)
    state.pointerDragged(to: CGPoint(x: 4, y: 0))
    #expect(state.highlightsWindow)
    state.pointerDragged(to: CGPoint(x: 4.01, y: 0))
    #expect(!state.highlightsWindow)
    state.pointerDragged(to: CGPoint(x: 2, y: 2))
    #expect(!state.highlightsWindow)
    #expect(state.pointerUp(at: CGPoint(x: 2, y: 2), hasWindow: true) == .captureArea(CGRect(x: 0, y: 0, width: 2, height: 2)))
    #expect(state.highlightsWindow)
    _ = state.pointerDown(at: .zero, last: nil)
    state.pointerDragged(to: CGPoint(x: 5, y: 5))
    #expect(state.pointerUp(at: .zero, hasWindow: true) == .none)
}

@Test func windowKeyDoesNotChangeClickOrInterruptDrag() {
    var state = CaptureState()
    _ = state.pointerDown(at: .zero, last: nil)
    #expect(state.key(13, hasLast: false) == .none)
    #expect(state.pointerUp(at: .zero, hasWindow: true) == .captureWindow)
    _ = state.pointerDown(at: .zero, last: nil)
    state.pointerDragged(to: CGPoint(x: 10, y: 10))
    #expect(state.key(13, hasLast: false) == .none)
    #expect(!state.highlightsWindow)
    #expect(state.pointerUp(at: CGPoint(x: 10, y: 10), hasWindow: true) == .captureArea(CGRect(x: 0, y: 0, width: 10, height: 10)))
}

@Test(arguments: [false, true], [false, true])
func previousAreaMovesOnlyWithOptionForBothOutputs(_ video: Bool, _ option: Bool) {
    var state = CaptureState()
    if video { _ = state.key(48, hasLast: true) }
    let last = CGRect(x: 100, y: 100, width: 400, height: 300)
    _ = state.pointerDown(at: CGPoint(x: 150, y: 150), last: last, movingLast: option)
    state.pointerDragged(to: CGPoint(x: 170, y: 190))
    if option {
        #expect(state.gesture.areaPreview == nil)
        #expect(state.pointerUp(at: CGPoint(x: 170, y: 190)) == .moveLast(last.offsetBy(dx: 20, dy: 40)))
    } else {
        #expect(state.gesture.lastPreview == nil)
        #expect(state.pointerUp(at: CGPoint(x: 170, y: 190)) == .captureArea(CGRect(x: 150, y: 150, width: 20, height: 40)))
    }
    _ = state.pointerDown(at: .zero, last: last, movingLast: option)
    #expect(state.pointerUp(at: CGPoint(x: 20, y: 40)) == .captureArea(CGRect(x: 0, y: 0, width: 20, height: 40)))
}
