import Foundation
import Testing
@testable import UtsushieCore

@Test func elementSelectionClipsChildrenButKeepsParentsOutsideInnerScroller() throws {
    let selection = ElementSelection(nodes: [
        .init(rect: CGRect(x: 10, y: 20, width: 90, height: 200), label: "子"),
        .init(rect: CGRect(x: 0, y: 50, width: 150, height: 100), label: "スクロール", clipsChildren: true),
        .init(rect: CGRect(x: 0, y: 0, width: 300, height: 250), label: "ページ", clipsChildren: true),
    ], point: CGPoint(x: 30, y: 60), visibleBounds: CGRect(x: 0, y: 0, width: 400, height: 300))
    #expect(selection.candidates.map(\.rect) == [
        CGRect(x: 10, y: 50, width: 90, height: 100),
        CGRect(x: 0, y: 50, width: 150, height: 100),
        CGRect(x: 0, y: 0, width: 300, height: 250),
    ])
}

@Test func elementSelectionClipsIframeToOuterWebAreaWithoutSelectingBrowserChrome() {
    let bounds = CGRect(x: -1500, y: -200, width: 1000, height: 700)
    let leaf = CGRect(x: -1300, y: -100, width: 400, height: 300)
    let viewport = CGRect(x: -1400, y: -150, width: 300, height: 250)
    let selection = ElementSelection(nodes: [
        .init(rect: leaf, label: "文字"),
        .init(rect: bounds, label: "内側", clipsChildren: true),
        .init(rect: viewport, label: "外側", clipsChildren: true, isCandidate: false),
    ], point: CGPoint(x: -1200, y: 0), visibleBounds: bounds)
    #expect(selection.candidates.map(\.rect) == [leaf.intersection(viewport), viewport])
    #expect(selection.candidates.map(\.label) == ["文字", "内側"])
}

@Test func elementSelectionSkipsDuplicateAndNonEnclosingParentsAndBoundsNavigation() throws {
    let small = CGRect(x: 20, y: 20, width: 40, height: 40)
    let large = CGRect(x: 0, y: 0, width: 100, height: 100)
    var selection = ElementSelection(nodes: [
        .init(rect: small, label: "子"), .init(rect: small, label: "同じ枠"),
        .init(rect: CGRect(x: 30, y: 10, width: 60, height: 60), label: "ARIAで別位置"),
        .init(rect: large, label: "親", clipsChildren: true),
    ], point: CGPoint(x: 40, y: 40), visibleBounds: large)
    #expect(selection.candidates.map(\.label) == ["子", "親"])
    selection.selectChild()
    #expect(selection.selected?.rect == small)
    selection.selectParent(); selection.selectParent()
    #expect(selection.selected?.rect == large)
    #expect(!selection.canSelectParent)
    selection.selectChild(); selection.selectChild()
    #expect(selection.selected?.rect == small)
}

@Test func elementSelectionRejectsInvalidClipAndPointsOutsideVisibleContent() {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    #expect(ElementSelection(nodes: [.init(rect: bounds, label: "要素")], point: CGPoint(x: 200, y: 30), visibleBounds: bounds).selected == nil)
    #expect(ElementSelection(nodes: [.init(rect: bounds, label: "要素"), .init(rect: nil, label: "不明な可視範囲", clipsChildren: true)], point: CGPoint(x: 30, y: 30), visibleBounds: bounds).selected == nil)
    #expect(!ElementSelection.matches(.null, .null))
    #expect(!ElementSelection.isValid(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)))
    #expect(ElementSelection.matches(bounds, bounds.offsetBy(dx: 0.25, dy: -0.25)))
    #expect(!ElementSelection.matches(bounds, bounds.offsetBy(dx: 2, dy: 0)))
}

@Test func elementModeKeepsExistingCaptureShortcutsAndDragBehavior() {
    var state = CaptureState()
    #expect(state.key(14, hasLast: false) == .none)
    #expect(state.target == .element)
    _ = state.pointerDown(at: .zero, last: nil)
    #expect(state.target == .element)
    #expect(state.pointerUp(at: .zero, hasWindow: false) == .none)
    _ = state.key(48, hasLast: false)
    #expect(state.output == .video && state.target == .element)
    _ = state.pointerDown(at: .zero, last: nil)
    state.pointerDragged(to: CGPoint(x: 40, y: 30))
    #expect(state.target == .element && state.cursor == .arrow)
    #expect(state.gesture.areaPreview == nil)
    #expect(state.pointerUp(at: .zero, hasWindow: true) == .none)
    _ = state.pointerDown(at: .zero, last: nil, selectingDisplay: true)
    #expect(state.target == .element)
    #expect(state.pointerUp(at: CGPoint(x: 40, y: 30), hasWindow: true) == .none)
    _ = state.pointerDown(at: .zero, last: CGRect(x: -10, y: -10, width: 100, height: 100), movingLast: true)
    #expect(state.pointerUp(at: .zero, hasWindow: true) == .captureWindow)
    state.modifiersChanged(shift: true)
    #expect(!state.highlightsDisplay)
    #expect(state.key(8, hasLast: false) == .captureChrome)
    _ = state.key(14, hasLast: true)
    #expect(state.key(36, hasLast: true) == .captureLast)
    _ = state.key(14, hasLast: true)
    _ = state.key(14, hasLast: true)
    #expect(state.target == .area)
    #expect(state.cursor == .crosshair)
    _ = state.pointerDown(at: .zero, last: nil)
    state.pointerDragged(to: CGPoint(x: 40, y: 30))
    #expect(state.pointerUp(at: CGPoint(x: 40, y: 30)) == .captureArea(CGRect(x: 0, y: 0, width: 40, height: 30)))
}

@Test func elementToolbarFitsAddedTargetBeforeEscape() {
    let widths: [CGFloat] = [40, 56, 87, 63, 90, 80, 91]
    let layout = OverlayToolbarLayout(itemWidths: widths, tabWidth: 28)
    #expect(layout.items.map(\.width) == widths)
    #expect(layout.targetTray.contains(layout.items[5]))
    #expect(layout.items[6].minX - layout.targetTray.maxX == 10)
    #expect(layout.width - layout.items[6].maxX == 6)
}

@Test func elementSelectionStopsBeforeParentHiddenByAnotherWindow() {
    let child = CGRect(x: 10, y: 10, width: 30, height: 30)
    let page = CGRect(x: 0, y: 0, width: 300, height: 200)
    let nodes: [CaptureElementNode] = [.init(rect: child, label: "子"), .init(rect: page, label: "ページ", clipsChildren: true)]
    let selection = ElementSelection(nodes: nodes, point: CGPoint(x: 20, y: 20), visibleBounds: page,
        occludingBounds: [CGRect(x: 100, y: 0, width: 200, height: 200)])
    #expect(selection.candidates.map(\.rect) == [child])
    #expect(ElementSelection(nodes: nodes, point: CGPoint(x: 20, y: 20), visibleBounds: page, occludingBounds: [child]).selected == nil)
    let visible = CGRect(x: 0, y: 0, width: 200, height: 100)
    let clipped = ElementSelection(nodes: nodes, point: CGPoint(x: 20, y: 20), visibleBounds: visible)
    #expect(clipped.candidates.last?.rect == visible)
}
