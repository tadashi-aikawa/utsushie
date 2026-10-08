import Foundation
import Testing
@testable import UtsushieCore

@Test func straightLineUsesArrowGeometryWithoutHead() {
    let line = Annotation(tool: .line, start: CGPoint(x: -20, y: 100), end: CGPoint(x: 200, y: 100))
    let size = CGSize(width: 400, height: 300)
    let style = AnnotationStyle(imageSize: size)
    let doc = AnnotationDocument(annotations: [line])
    #expect(doc.hit(at: CGPoint(x: 50, y: 104), style: style, tolerance: 2) == line.id)
    #expect(doc.hit(at: CGPoint(x: 50, y: 120), style: style, tolerance: 2) == nil)
    #expect(AnnotationGeometry.handles(for: line) == [line.start, line.end])
    #expect(AnnotationGeometry.placed(line, bounds: line.rect, imageSize: size) == line)
    #expect(doc.exportLayout(imageSize: size).left > 20)
    #expect(AnnotationTool.line.keyCode == 37)
}

@Test func highlighterTracksPolylineAndNeverAddsMargin() {
    let points = [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 10), CGPoint(x: 100, y: 80)]
    let pen = Annotation(tool: .highlighter, start: points[0], end: points[2], points: points)
    let size = CGSize(width: 400, height: 300)
    let doc = AnnotationDocument(annotations: [pen])
    let style = AnnotationStyle(imageSize: size)
    #expect(pen.rect == CGRect(x: 10, y: 10, width: 90, height: 70))
    #expect(doc.hit(at: CGPoint(x: 103, y: 40), style: style, tolerance: 2) == pen.id)
    #expect(doc.hit(at: CGPoint(x: 50, y: 40), style: style, tolerance: 2) == nil)
    #expect(AnnotationGeometry.handles(for: pen).isEmpty)
    let moved = pen.translated(by: CGPoint(x: -40, y: -40))
    let placed = AnnotationGeometry.placed(moved, bounds: moved.rect, imageSize: size)
    #expect(placed.points == [CGPoint(x: 0, y: 0), CGPoint(x: 90, y: 0), CGPoint(x: 90, y: 70)])
    #expect(AnnotationDocument(annotations: [moved]).exportLayout(imageSize: size).bounds == CGRect(origin: .zero, size: size))
    #expect(AnnotationTool.spotlight.layer < AnnotationTool.highlighter.layer)
    #expect(AnnotationTool.highlighter.layer < AnnotationTool.line.layer)
    #expect(AnnotationTool.highlighter.keyCode == 35)
}

@Test func highlighterSettingsOnlyChangeSelectedHighlightersAndKeepOtherAxis() {
    let a = Annotation(tool: .highlighter, start: .zero, end: CGPoint(x: 30, y: 20), highlighterColor: .cyan)
    let b = Annotation(tool: .highlighter, start: CGPoint(x: 10, y: 50), end: CGPoint(x: 40, y: 50), highlighterColor: .green, darkBackground: true)
    let c = Annotation(tool: .highlighter, start: CGPoint(x: 10, y: 80), highlighterColor: .pink)
    let line = Annotation(tool: .line, start: .zero, end: CGPoint(x: 40, y: 20), highlighterColor: .pink, darkBackground: true)
    let initial = AnnotationDocument(annotations: [a, b, c, line])
    let selected: Set<UUID> = [a.id, b.id, line.id, UUID()]
    let colored = initial.settingHighlighter(selected, color: .yellow)
    #expect(colored.annotations[0].highlighterColor == .yellow && !colored.annotations[0].darkBackground)
    #expect(colored.annotations[1].highlighterColor == .yellow && colored.annotations[1].darkBackground)
    #expect(colored.annotations[2] == c && colored.annotations[3] == line)
    #expect(line.highlighterColor == .yellow && !line.darkBackground)
    let dark = initial.settingHighlighter(selected, darkBackground: true)
    #expect(dark.annotations[0].darkBackground && dark.annotations[0].highlighterColor == .cyan)
    #expect(dark.annotations[1] == b && dark.annotations[2] == c && dark.annotations[3] == line)
    #expect(initial.settingHighlighter([], color: .pink, darkBackground: true) == initial)
    var history = AnnotationHistory(initial)
    history.commit(colored); history.undo()
    #expect(history.document == initial && !history.canUndo)
    history.redo(); #expect(history.document == colored)
}

@Test func highlighterActionsUsePhysicalUnmodifiedKeysOutsideTextInput() {
    let mappings: [(UInt16, HighlighterAction)] = [(18, .color(.yellow)), (19, .color(.cyan)), (20, .color(.pink)), (21, .color(.green)), (2, .toggleDarkBackground)]
    for (code, action) in mappings {
        #expect(HighlighterAction(keyCode: code) == action)
        #expect(HighlighterAction(keyCode: code, modified: true) == nil)
        #expect(HighlighterAction(keyCode: code, editingText: true) == nil)
    }
    for code: UInt16 in [0, 22, 23, 35, 53, 83, 84, 85, 86] { #expect(HighlighterAction(keyCode: code) == nil) }
}
