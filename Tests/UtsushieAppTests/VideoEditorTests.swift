import AppKit
import Testing
import UtsushieCore
@testable import Utsushie

@MainActor
private final class VideoRunningApplication: NSRunningApplication, @unchecked Sendable {
    let identifier: pid_t
    init(_ identifier: pid_t) { self.identifier = identifier; super.init() }
    override var processIdentifier: pid_t { identifier }
    override var isTerminated: Bool { false }
}
@MainActor private func videoKey(_ editor: VideoEditorController, _ code: UInt16, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: editor.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: code))
}
@MainActor @Test func videoEditorUsesPhysicalKeysAndUndoThenClosesBeforeCompletion() throws {
    _ = NSApplication.shared
    let focus = AnnotationApplicationFocus(activate: {}, restore: { _ in })
    let editor = VideoEditorController(source: URL(fileURLWithPath: "/tmp/utsushie-test-missing.mp4"),
        document: VideoEditDocument(duration: 12), screen: nil, focus: focus)
    defer { editor.window.close() }
    var order: [String] = []
    var completed: VideoEditDocument?
    editor.onClose = { order.append("close") }
    editor.onComplete = { completed = $0; order.append("complete") }
    editor.window.orderFront(nil)
    #expect(editor.window.styleMask == [.titled, .closable, .resizable])
    #expect(editor.window.canBecomeKey && editor.window.canBecomeMain)
    #expect(editor.window.level == .normal)
    #expect(editor.window.accessibilitySubrole() == .standardWindow)
    editor.seek(to: 2)
    #expect(editor.handleKey(try videoKey(editor, 34, flags: .function)))
    editor.seek(to: 10)
    #expect(editor.handleKey(try videoKey(editor, 31)))
    #expect(editor.timeline.document.kept == [.init(2, 10)])
    editor.timeline.selection = .init(4, 6)
    editor.window.sendEvent(try videoKey(editor, 51))
    #expect(editor.timeline.document.kept == [.init(2, 4), .init(6, 10)])
    #expect(editor.window.performKeyEquivalent(with: try videoKey(editor, 6, flags: .command)))
    #expect(editor.timeline.document.kept == [.init(2, 10)])
    #expect(editor.window.performKeyEquivalent(with: try videoKey(editor, 6, flags: [.command, .shift])))
    #expect(editor.timeline.document.kept == [.init(2, 4), .init(6, 10)])
    #expect(!editor.handleKey(try videoKey(editor, 34, flags: .option)))
    #expect(editor.window.performKeyEquivalent(with: try videoKey(editor, 36, flags: .command)))
    #expect(order == ["close", "complete"])
    #expect(completed?.outputDuration == 6)
}
@MainActor @Test func videoDiscardRequiresTwoPressesAndIgnoresRepeat() throws {
    let editor = VideoEditorController(source: URL(fileURLWithPath: "/tmp/utsushie-test-missing.mp4"),
        document: VideoEditDocument(duration: 12), screen: nil, focus: .init(activate: {}, restore: { _ in }))
    defer { editor.window.close() }
    var closed = false
    editor.onClose = { closed = true }
    editor.seek(to: 2); editor.setStart()
    editor.toolbar.layoutSubtreeIfNeeded()
    let frame = editor.toolbar.discardButton.frame
    #expect(editor.handleKey(try videoKey(editor, 12)))
    #expect(!closed && editor.toolbar.discardButton.title == "もう一度" && editor.toolbar.discardButton.armed)
    editor.toolbar.layoutSubtreeIfNeeded()
    #expect(editor.toolbar.discardButton.frame == frame && editor.hintText == "完了で 10.0秒に切る")
    #expect(editor.handleKey(try videoKey(editor, 12, repeatKey: true)))
    #expect(!closed)
    #expect(editor.handleKey(try videoKey(editor, 12)))
    #expect(closed)
}

@MainActor @Test func videoBoundaryDragIsOneUndoStepAndUndoDuringDragCancelsPreview() throws {
    let editor = VideoEditorController(source: URL(fileURLWithPath: "/tmp/utsushie-test-missing.mp4"),
        document: VideoEditDocument(duration: 10), screen: nil, focus: .init(activate: {}, restore: { _ in }))
    defer { editor.window.close() }
    let root = try #require(editor.window.contentView)
    root.layoutSubtreeIfNeeded()
    let timeline = editor.timeline
    let width = timeline.bounds.width - 48
    func event(_ type: NSEvent.EventType, _ time: Double) throws -> NSEvent {
        let location = timeline.convert(CGPoint(x: 24 + width * time / 10, y: 95), to: nil)
        return try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: editor.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    timeline.mouseDown(with: try event(.leftMouseDown, 0))
    #expect(editor.boundaryPreviewTime == 0 && editor.position == 0)
    timeline.mouseDragged(with: try event(.leftMouseDragged, 1))
    timeline.mouseDragged(with: try event(.leftMouseDragged, 2))
    #expect(editor.boundaryPreviewTime == 2 && editor.position == 0)
    timeline.mouseUp(with: try event(.leftMouseUp, 2))
    #expect(editor.boundaryPreviewTime == nil)
    #expect(timeline.document.kept == [.init(2, 10)])
    editor.undo()
    #expect(timeline.document.kept == [.init(0, 10)])
    editor.redo()
    timeline.mouseDown(with: try event(.leftMouseDown, 2))
    timeline.mouseDragged(with: try event(.leftMouseDragged, 3))
    #expect(abs((timeline.document.kept.first?.start ?? 0) - 3) < 0.000001)
    editor.undo()
    timeline.mouseDragged(with: try event(.leftMouseDragged, 4))
    timeline.mouseUp(with: try event(.leftMouseUp, 4))
    #expect(timeline.document.kept == [.init(2, 10)])
    #expect(editor.boundaryPreviewTime == nil)
    editor.undo()
    #expect(timeline.document.kept == [.init(0, 10)])
}
@MainActor @Test func videoWindowActivatesOnShowAndLeavesRestorationToSystem() throws {
    _ = NSApplication.shared
    let previous = VideoRunningApplication(-2), current = VideoRunningApplication(ProcessInfo.processInfo.processIdentifier)
    var front: NSRunningApplication? = previous
    var requests = 0, restored = false
    var ordinaryRequests = 0
    weak var openingWindow: NSWindow?
    let focus = AnnotationApplicationFocus(isActive: { true }, frontmostApplication: { front },
        activate: { ordinaryRequests += 1 }, activateEditor: {
            requests += 1
            #expect(openingWindow?.isVisible == true)
            #expect(openingWindow?.firstResponder is VideoEditorTimeline)
        }, restore: { restored = $0 === previous })
    let editor = VideoEditorController(source: URL(fileURLWithPath: "/tmp/utsushie-test-missing.mp4"),
        document: VideoEditDocument(duration: 12), screen: nil, focus: focus)
    defer { editor.window.close() }
    openingWindow = editor.window
    editor.show()
    #expect(requests == 1 && ordinaryRequests == 0)
    #expect(editor.window.level == .normal && editor.window.accessibilitySubrole() == .standardWindow)
    #expect(editor.window.firstResponder === editor.timeline)
    // 通常ウィンドウでは、スクロール後のアクティベーションを再要求しない。
    let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0))
    editor.window.sendEvent(try #require(NSEvent(cgEvent: wheel)))
    #expect(requests == 1)
    front = current; editor.window.close(); #expect(!restored && ordinaryRequests == 0)
}

@MainActor @Test func videoToolbarUsesSharedTraysAndNavigationTargetsWholeRecording() throws {
    let editor = VideoEditorController(source: URL(fileURLWithPath: "/tmp/utsushie-test-missing.mp4"),
        document: VideoEditDocument(duration: 12, kept: [.init(2, 10)]), screen: nil,
        focus: .init(activate: {}, restore: { _ in }))
    defer { editor.window.close() }
    let root = try #require(editor.window.contentView)
    root.layoutSubtreeIfNeeded()
    let bar = editor.toolbar
    #expect(bar.frame.height == 75)
    #expect(bar.trays.map { $0.buttons.map(\.title) } == [["始め", "終わり", "切る"], ["ズーム"], ["撮る"]])
    #expect(bar.trays.last!.frame.maxX < bar.undoButton.frame.minX)
    #expect(bar.hintView.frame.maxX < bar.length.frame.minX)
    #expect(bar.captureButton.face != .primary && bar.finishButton.face == .primary)
    #expect(bar.length.stringValue == "残す 8.0秒 / 12.0秒")
    for (code, flags, expected) in [(UInt16(123), NSEvent.ModifierFlags.command, 0.0), (124, .command, 12),
                                  (115, [], 0), (119, .function, 12)] {
        editor.seek(to: 6)
        #expect(editor.handleKey(try videoKey(editor, code, flags: flags)))
        #expect(editor.position == expected)
    }
    editor.timeline.startButton.performClick(nil); #expect(editor.position == 0)
    editor.timeline.endButton.performClick(nil); #expect(editor.position == 12)
    editor.seek(to: 3); editor.setStart(); editor.discard()
    #expect(bar.discardButton.armed)
    editor.goToStart()
    #expect(!bar.discardButton.armed && bar.discardButton.title == "破棄")
}

@MainActor @Test(arguments: [VideoTransitionKind.none, .fade, .dissolve])
func closingTransitionMenuKeepsChosenKindWhenSpeedFieldLosesFocus(_ kind: VideoTransitionKind) throws {
    let document = VideoEditDocument(duration: 24.1, kept: [.init(2.4, 6.2), .init(11, 21.8)])
    let range = document.interiorCuts[0]
    var chosen: [VideoTransitionKind] = []
    let menu = VideoTransitionMenu(transition: document.transition(for: range)) { kind, _ in chosen.append(kind) }
    // ポップオーバーと同じく、唯一の入力欄が最初のfirst responderになる。
    let window = NSWindow(contentRect: menu.view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = menu.view
    let field = try #require(menu.view.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    #expect(window.makeFirstResponder(field))
    let button = try #require(menu.view.subviews.compactMap { $0 as? NSButton }.first { $0.tag == VideoTransitionKind.allCases.firstIndex(of: kind) })
    button.performClick(nil)
    // 閉じるとフォーカスが外れ、入力欄の編集終了のactionが届く。
    #expect(window.makeFirstResponder(nil))
    #expect(chosen == [kind])
}

@MainActor @Test func shortZoomRangeOpensEaseMenuOnSecondClickAndMovesEdgeOnlyAfterDrag() throws {
    let zoom = VideoZoom(range: .init(90, 92), rect: CGRect(x: 0, y: 0, width: 80, height: 60))
    let editor = VideoEditorController(source: URL(fileURLWithPath: "/tmp/utsushie-test-missing.mp4"),
        document: VideoEditDocument(duration: 180, zooms: [zoom]), screen: nil, focus: .init(activate: {}, restore: { _ in }))
    defer { editor.window.close() }
    editor.window.orderFront(nil)
    editor.window.contentView?.layoutSubtreeIfNeeded()
    let timeline = editor.timeline, width = timeline.bounds.width - 48
    // 2秒の区間は14pt未満で、両端7ptの判定が区間全体を覆う。
    try #require(width * 2 / 180 < 14)
    #expect(VideoTimelineGesture.hit(x: width * 91 / 180, y: 46, width: width, document: timeline.document) != .zoom(index: 0))
    func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: timeline.convert(CGPoint(x: x, y: 70 + 46), to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: editor.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    let center = 24 + width * 91 / 180
    func click(dragTo x: CGFloat? = nil) throws {
        timeline.mouseDown(with: try event(.leftMouseDown, center))
        if let x { timeline.mouseDragged(with: try event(.leftMouseDragged, x)) }
        timeline.mouseUp(with: try event(.leftMouseUp, x ?? center))
    }
    // 1回目は選ぶだけ。
    try click()
    #expect(timeline.selectedZoom == zoom.id && timeline.zoomMenu == nil)
    // 4pt以内のずれはクリックとして扱い、端を動かさずにメニューを開く。
    try click(dragTo: center + 3)
    #expect(timeline.zoomMenu != nil && timeline.document.zooms[0].range == zoom.range)
    timeline.closeTransitionMenu()
    // 4ptを超えたら端を動かし、メニューは開かない。
    try click(dragTo: center + 40)
    #expect(timeline.zoomMenu == nil && timeline.document.zooms[0].range != zoom.range)
    editor.undo(); #expect(timeline.document.zooms[0].range == zoom.range)
}

@MainActor @Test func draggingInsideZoomRangeMovesItKeepingLengthAndStopsAtNeighbor() throws {
    let rect = CGRect(x: 0, y: 0, width: 80, height: 60)
    let first = VideoZoom(range: .init(2, 6), rect: rect), second = VideoZoom(range: .init(8, 10), rect: rect)
    let editor = VideoEditorController(source: URL(fileURLWithPath: "/tmp/utsushie-test-missing.mp4"),
        document: VideoEditDocument(duration: 12, zooms: [first, second]), screen: nil, focus: .init(activate: {}, restore: { _ in }))
    defer { editor.window.close() }
    editor.window.orderFront(nil)
    editor.window.contentView?.layoutSubtreeIfNeeded()
    let timeline = editor.timeline, width = timeline.bounds.width - 48
    func x(_ time: Double) -> CGFloat { 24 + width * time / 12 }
    #expect(VideoTimelineGesture.hit(x: width * 4 / 12, y: 46, width: width, document: timeline.document) == .zoom(index: 0))
    func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: timeline.convert(CGPoint(x: x, y: 70 + 46), to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: editor.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    func drag(from a: CGFloat, to b: CGFloat? = nil) throws {
        timeline.mouseDown(with: try event(.leftMouseDown, a))
        if let b { timeline.mouseDragged(with: try event(.leftMouseDragged, b)) }
        timeline.mouseUp(with: try event(.leftMouseUp, b ?? a))
    }
    // 1回目は選ぶだけ、動かさずにもう一度押して離すとメニューを開く。
    try drag(from: x(4))
    #expect(timeline.selectedZoom == first.id && timeline.zoomMenu == nil)
    // 選んだ区間は状態と消すキーだけを出す。補間の秒数は「イン・アウト」と呼ぶ。
    #expect(timeline.zoomSummary(first) == "ズーム ・ 長さ 4.0秒 ・ イン・アウト 0.3秒 ・ ⌫ 消す")
    timeline.videoSize = CGSize(width: 160, height: 120)
    #expect(timeline.zoomSummary(first) == "ズーム ×2.0 ・ 長さ 4.0秒 ・ イン・アウト 0.3秒 ・ ⌫ 消す")
    try drag(from: x(4), to: x(4) + 3)
    #expect(timeline.zoomMenu != nil && timeline.document.zooms[0].range == first.range)
    let labels = timeline.zoomMenu?.view.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isEditable } ?? []
    let label = try #require(labels.first { $0.stringValue == "イン・アウト" })
    #expect(label.attributedStringValue.size().width <= label.frame.width)
    timeline.closeTransitionMenu()
    // 中を引くと長さを保って動かし、再生位置も一緒に動かす。メニューは開かない。
    try drag(from: x(4), to: x(5))
    #expect(timeline.zoomMenu == nil && timeline.document.zooms.map(\.range) == [.init(3, 7), second.range])
    #expect(abs(editor.position - 5) < 0.01 && timeline.selectedZoom == first.id)
    // 1回の履歴に入る。
    editor.undo(); #expect(timeline.document.zooms.map(\.range) == [first.range, second.range])
    // 隣の区間の手前で止まる。
    try drag(from: x(4), to: x(9))
    #expect(timeline.document.zooms.map(\.range) == [.init(4, 8), second.range])
    #expect(abs(editor.position - 6) < 0.01)
    // 引いている途中の⌘Zは、引く前へ戻すだけで履歴は進めない。区間から外れた再生位置も押した位置へ戻す。
    timeline.mouseDown(with: try event(.leftMouseDown, x(6)))
    timeline.mouseDragged(with: try event(.leftMouseDragged, x(1)))
    #expect(timeline.document.zooms[0].range == .init(0, 4) && abs(editor.position - 2) < 0.01)
    editor.undo()
    #expect(timeline.document.zooms.map(\.range) == [.init(4, 8), second.range] && abs(editor.position - 6) < 0.01)
    timeline.mouseUp(with: try event(.leftMouseUp, x(1)))
    #expect(timeline.document.zooms.map(\.range) == [.init(4, 8), second.range])
    // ツールの切り替えで取り消しても、未確定の移動を残さない。
    func key(_ code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: editor.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }
    timeline.mouseDown(with: try event(.leftMouseDown, x(6)))
    timeline.mouseDragged(with: try event(.leftMouseDragged, x(1)))
    #expect(editor.handleKey(try key(6)) && editor.zoomTool)
    #expect(timeline.document.zooms.map(\.range) == [.init(4, 8), second.range] && abs(editor.position - 6) < 0.01)
    timeline.mouseUp(with: try event(.leftMouseUp, x(1)))
    #expect(timeline.document.zooms.map(\.range) == [.init(4, 8), second.range])
    // 次の編集で取り消し済みの移動が現れたり消えたりしない。
    editor.undo(); #expect(timeline.document.zooms.map(\.range) == [first.range, second.range])
}

@MainActor @Test func zoomEaseMenuEditsTenthsOfSecondAndUsesEditorUndoHistory() throws {
    let zoom = VideoZoom(range: .init(2, 6), rect: CGRect(x: 0, y: 0, width: 80, height: 60))
    let editor = VideoEditorController(source: URL(fileURLWithPath: "/tmp/utsushie-test-missing.mp4"),
        document: VideoEditDocument(duration: 12, zooms: [zoom]), screen: nil, focus: .init(activate: {}, restore: { _ in }))
    defer { editor.window.close() }
    editor.window.contentView?.layoutSubtreeIfNeeded()
    // 時間軸と同じ変更の経路で、選んだ区間の秒数だけを変える。
    let menu = VideoZoomMenu(ease: zoom.ease) { seconds in
        var next = editor.timeline.document; next.setZoomEase(zoom.id, seconds: seconds); editor.timeline.onEdit?(next, true)
    }
    let field = try #require(menu.view.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    #expect(field.stringValue == "0.3")
    func end() { menu.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification)) }
    field.stringValue = "1.25"; end()
    #expect(editor.timeline.document.zooms[0].ease == 1.3 && field.stringValue == "1.3")
    let stepper = try #require(menu.view.subviews.compactMap { $0 as? NSStepper }.first)
    #expect(stepper.minValue == 0 && stepper.maxValue == 2 && stepper.increment == 0.1)
    stepper.doubleValue = 1.4; _ = NSApp.sendAction(stepper.action!, to: stepper.target, from: stepper)
    #expect(editor.timeline.document.zooms[0].ease == 1.4)
    field.stringValue = "5"; end()
    #expect(editor.timeline.document.zooms[0].ease == 2)
    // 数でない入力と同じ値では履歴へ入れない。
    field.stringValue = "abc"; end(); field.stringValue = "2.0"; end()
    #expect(editor.timeline.document.zooms[0].ease == 2 && field.stringValue == "2.0")
    editor.undo(); #expect(editor.timeline.document.zooms[0].ease == 1.4)
    editor.undo(); #expect(editor.timeline.document.zooms[0].ease == 1.3)
    editor.undo(); #expect(editor.timeline.document.zooms[0].ease == 0.3)
    #expect(editor.timeline.document.zooms[0].range == zoom.range && editor.timeline.document.zooms[0].rect == zoom.rect)
    // 台は足さない。
    #expect(editor.toolbar.trays.map { $0.buttons.map(\.title) } == [["始め", "終わり", "切る"], ["ズーム"], ["撮る"]])
}

@MainActor @Test func cutTransitionMenuEditsIntegerSpeedAndUsesEditorUndoHistory() throws {
    var document = VideoEditDocument(duration: 24.1, kept: [.init(2.4, 6.2), .init(11, 21.8)])
    let range = document.interiorCuts[0]
    let editor = VideoEditorController(source: URL(fileURLWithPath: "/tmp/utsushie-test-missing.mp4"),
        document: document, screen: nil, focus: .init(activate: {}, restore: { _ in }))
    defer { editor.window.close() }
    editor.window.contentView?.layoutSubtreeIfNeeded()
    let menu = VideoTransitionMenu(transition: document.transition(for: range)) { kind, speed in
        var next = editor.timeline.document; next.setTransition(for: range, kind: kind, speed: speed)
        editor.timeline.onEdit?(next, true)
    }
    let buttons = menu.view.subviews.compactMap { $0 as? NSButton }
    #expect(buttons.count == 4)
    let fastForward = try #require(buttons.first { $0.tag == 1 }); fastForward.performClick(nil)
    #expect(editor.timeline.document.transitions[0].multiplier == 5)
    #expect(editor.toolbar.length.stringValue == "残す 14.6秒 + つなぎ 1.0秒 / 24.1秒")
    let field = try #require(menu.view.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    field.stringValue = "8"; menu.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
    #expect(editor.timeline.document.transitions[0].multiplier == 8)
    let stepper = try #require(menu.view.subviews.compactMap { $0 as? NSStepper }.first)
    stepper.integerValue = 9; _ = NSApp.sendAction(stepper.action!, to: stepper.target, from: stepper)
    #expect(editor.timeline.document.transitions[0].multiplier == 9)
    editor.undo(); #expect(editor.timeline.document.transitions[0].multiplier == 8)
    editor.undo(); #expect(editor.timeline.document.transitions[0].multiplier == 5)
    editor.undo(); #expect(editor.timeline.document.transitions[0].kind == .none)
    editor.redo(); #expect(editor.timeline.document.transitions[0].kind == .fastForward)
    let fade = try #require(buttons.first { $0.tag == 2 }); fade.performClick(nil)
    menu.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
    #expect(editor.timeline.document.transitions[0].kind == .fade)
    field.stringValue = "2.5"; menu.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
    #expect(editor.timeline.document.transitions[0].kind == .fade)
    fastForward.performClick(nil)
    document = editor.timeline.document
    let reopened = VideoEditorController(source: URL(fileURLWithPath: "/tmp/utsushie-test-missing.mp4"),
        document: document, screen: nil, focus: .init(activate: {}, restore: { _ in }))
    defer { reopened.window.close() }
    #expect(reopened.timeline.document.transitions[0].multiplier == 9)
    // つなぎ方では台を足さない。
    #expect(reopened.toolbar.trays.map { $0.buttons.map(\.title) } == [["始め", "終わり", "切る"], ["ズーム"], ["撮る"]])
}
