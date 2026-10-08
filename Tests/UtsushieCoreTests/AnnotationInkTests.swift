import Foundation
import Testing
@testable import UtsushieCore

@Test func inkSettingsOnlyChangeSelectedSupportedAnnotations() {
    let supported: [AnnotationTool] = [.rectangle, .spotlight, .arrow, .line, .text, .number]
    let annotations = supported.map { Annotation(tool: $0, start: .zero, end: CGPoint(x: 40, y: 20), inkColor: .indigo) }
    let unselected = Annotation(tool: .line, start: .zero, inkColor: .white)
    let pen = Annotation(tool: .highlighter, start: .zero, highlighterColor: .cyan, darkBackground: true, inkColor: .green)
    let mosaic = Annotation(tool: .mosaic, start: .zero, inkColor: .black)
    let initial = AnnotationDocument(annotations: annotations + [unselected, pen, mosaic])
    let selected = Set(annotations.map(\.id) + [pen.id, mosaic.id, UUID()])
    let colored = initial.settingInk(selected, color: .green)
    for (before, after) in zip(annotations, colored.annotations) {
        var expected = before; expected.inkColor = .green
        #expect(after == expected)
    }
    #expect(Array(colored.annotations.suffix(3)) == [unselected, pen, mosaic])
    #expect(pen.inkColor == .red && mosaic.inkColor == .red)
    #expect(initial.settingInk([], color: .black) == initial)
    for tool in AnnotationTool.allCases { #expect(Annotation(tool: tool, start: .zero).inkColor == .red) }
    var history = AnnotationHistory(initial)
    history.commit(colored); history.undo()
    #expect(history.document == initial && !history.canUndo)
    history.redo(); #expect(history.document == colored)
}

@Test func inkColorsUsePhysicalUnmodifiedKeysOutsideTextInput() {
    let mappings: [(UInt16, InkColor)] = [(18, .red), (19, .orange), (20, .green), (21, .indigo), (23, .purple), (22, .pink), (26, .black), (28, .white)]
    for (code, color) in mappings {
        #expect(InkColor(keyCode: code) == color)
        #expect(InkColor(keyCode: code, modified: true) == nil)
        #expect(InkColor(keyCode: code, editingText: true) == nil)
    }
    #expect(InkColor.allCases.map(\.key) == ["1", "2", "3", "4", "5", "6", "7", "8"])
    #expect(InkColor.allCases.map(\.label) == ["朱", "橙", "緑", "藍", "紫", "桃", "墨", "白"])
    for code: UInt16 in [0, 2, 25, 29, 35, 53, 83, 84, 85, 86, 87] { #expect(InkColor(keyCode: code) == nil) }
}

@Test func inkCopiesAndDuplicatesKeepEveryColorAndLeader() {
    let size = CGSize(width: 1000, height: 600)
    for tool in [AnnotationTool.rectangle, .spotlight, .arrow, .line, .text, .number] {
        for color in InkColor.allCases {
            let original = Annotation(tool: tool, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 180, y: 140),
                                      text: "文字", leaderTarget: CGPoint(x: 50, y: 100), inkColor: color)
            var document = AnnotationDocument(annotations: [original])
            var clipboard = AnnotationClipboard()
            clipboard.copy([original.id], from: document)
            _ = clipboard.paste(into: &document, imageSize: size)
            _ = document.duplicate([original.id], imageSize: size)
            for copy in document.annotations.dropFirst() {
                #expect(copy.id != original.id && copy.inkColor == color)
                #expect(copy.start == CGPoint(x: 120, y: 120) && copy.text == original.text)
                #expect(copy.leaderTarget == original.leaderTarget.map { CGPoint(x: $0.x + 20, y: $0.y + 20) })
            }
        }
    }
}
