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
    #expect(editor.window.styleMask.contains(.nonactivatingPanel))
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
    #expect(editor.handleKey(try videoKey(editor, 12)))
    #expect(!closed && editor.hintText == "もう一度押すと破棄")
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
    timeline.mouseDragged(with: try event(.leftMouseDragged, 1))
    timeline.mouseDragged(with: try event(.leftMouseDragged, 2))
    timeline.mouseUp(with: try event(.leftMouseUp, 2))
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
    editor.undo()
    #expect(timeline.document.kept == [.init(0, 10)])
}
@MainActor @Test func videoPanelRequestsActivationByFrontmostPIDAndRestoresPreviousApp() throws {
    _ = NSApplication.shared
    let previous = VideoRunningApplication(-2), current = VideoRunningApplication(ProcessInfo.processInfo.processIdentifier)
    var front: NSRunningApplication? = previous
    var requests = 0, restored = false
    let focus = AnnotationApplicationFocus(isActive: { true }, frontmostApplication: { front }, activate: { requests += 1 }, restore: { restored = $0 === previous })
    let editor = VideoEditorController(source: URL(fileURLWithPath: "/tmp/utsushie-test-missing.mp4"),
        document: VideoEditDocument(duration: 12), screen: nil, focus: focus)
    defer { editor.window.close() }
    editor.show()
    #expect(requests == 1)
    editor.requestActivation(); #expect(requests == 2)
    front = current; editor.requestActivation(); #expect(requests == 2)
    front = nil; editor.requestActivation(); #expect(requests == 3)
    front = current; editor.window.close(); #expect(restored)
}
