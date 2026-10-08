import Foundation
import Testing
@testable import UtsushieCore

@Test func colorCycleKeysUsePhysicalCAndOnlyAllowShiftOutsideTextInput() {
    for shift in [false, true] {
        let direction: ColorCycleDirection = shift ? .previous : .next
        #expect(ColorCycleDirection(keyCode: 8, shift: shift) == direction)
        #expect(HighlighterAction(keyCode: 8, shift: shift) == .cycleColor(direction))
        #expect(ColorCycleDirection(keyCode: 8, shift: shift, modified: true) == nil)
        #expect(ColorCycleDirection(keyCode: 8, shift: shift, editingText: true) == nil)
        #expect(HighlighterAction(keyCode: 8, shift: shift, modified: true) == nil)
        #expect(HighlighterAction(keyCode: 8, shift: shift, editingText: true) == nil)
    }
    for code: UInt16 in [0, 2, 18, 19, 20, 21, 23, 22, 26, 28, 53] {
        #expect(ColorCycleDirection(keyCode: code) == nil)
        #expect(HighlighterAction(keyCode: code, shift: true) == nil)
    }
}

@Test func inkAndHighlighterColorsCycleBothWaysAndWrapAtEnds() {
    let inks: [InkColor] = [.red, .orange, .green, .indigo, .purple, .pink, .black, .white, .red]
    for (before, after) in zip(inks, inks.dropFirst()) {
        #expect(before.cycled(.next) == after)
        #expect(after.cycled(.previous) == before)
    }
    let pens: [HighlighterColor] = [.yellow, .cyan, .pink, .green, .yellow]
    for (before, after) in zip(pens, pens.dropFirst()) {
        #expect(before.cycled(.next) == after)
        #expect(after.cycled(.previous) == before)
    }
}

@Test func inkCycleUsesFirstSelectedSupportedAnnotationOrRememberedDefault() {
    let unselected = Annotation(tool: .line, start: .zero, inkColor: .purple)
    let pen = Annotation(tool: .highlighter, start: .zero)
    let first = Annotation(tool: .text, start: .zero, inkColor: .white)
    let second = Annotation(tool: .arrow, start: .zero, inkColor: .indigo)
    let document = AnnotationDocument(annotations: [unselected, pen, first, second])
    let selection: Set<UUID> = [second.id, pen.id, first.id, UUID()]
    let next = document.cycledInkColor(selection, direction: .next, defaultColor: .green)
    #expect(next == .red)
    #expect(document.cycledInkColor(selection, direction: .previous, defaultColor: .green) == .black)
    let colored = document.settingInk(selection, color: next)
    #expect(colored.annotations[0] == unselected && colored.annotations[1] == pen)
    #expect(colored.annotations[2].inkColor == .red && colored.annotations[3].inkColor == .red)
    let reordered = AnnotationDocument(annotations: [second, first])
    #expect(reordered.cycledInkColor(selection, direction: .next, defaultColor: .green) == .purple)
    #expect(document.cycledInkColor([], direction: .next, defaultColor: .white) == .red)
    #expect(document.cycledInkColor([pen.id], direction: .previous, defaultColor: .red) == .white)
}

@Test func highlighterCycleUsesFirstSelectedPenAndPreservesBackgrounds() {
    let unselected = Annotation(tool: .highlighter, start: .zero, highlighterColor: .cyan)
    let ink = Annotation(tool: .rectangle, start: .zero, inkColor: .purple)
    let first = Annotation(tool: .highlighter, start: .zero, highlighterColor: .green, darkBackground: true)
    let second = Annotation(tool: .highlighter, start: .zero, highlighterColor: .pink)
    let document = AnnotationDocument(annotations: [unselected, ink, first, second])
    let selection: Set<UUID> = [second.id, ink.id, first.id, UUID()]
    let next = document.cycledHighlighterColor(selection, direction: .next, defaultColor: .cyan)
    #expect(next == .yellow)
    #expect(document.cycledHighlighterColor(selection, direction: .previous, defaultColor: .cyan) == .pink)
    let colored = document.settingHighlighter(selection, color: next)
    #expect(colored.annotations[0] == unselected && colored.annotations[1] == ink)
    #expect(colored.annotations[2].highlighterColor == .yellow && colored.annotations[3].highlighterColor == .yellow)
    #expect(colored.annotations[2].darkBackground && !colored.annotations[3].darkBackground)
    let reordered = AnnotationDocument(annotations: [second, first])
    #expect(reordered.cycledHighlighterColor(selection, direction: .next, defaultColor: .cyan) == .green)
    #expect(document.cycledHighlighterColor([], direction: .next, defaultColor: .green) == .yellow)
    #expect(document.cycledHighlighterColor([ink.id], direction: .previous, defaultColor: .yellow) == .green)
}
