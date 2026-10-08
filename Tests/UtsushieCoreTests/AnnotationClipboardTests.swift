import Foundation
import Testing
@testable import UtsushieCore

@Test func annotationClipboardOffsetsRepeatedPastesAndRenumbers() {
    let first = Annotation(tool: .number, start: CGPoint(x: 100, y: 100), leaderTarget: CGPoint(x: 20, y: 20))
    let second = Annotation(tool: .number, start: CGPoint(x: 200, y: 100))
    var doc = AnnotationDocument(annotations: [first, second])
    let size = CGSize(width: 1000, height: 600)
    var clipboard = AnnotationClipboard()
    clipboard.copy([second.id, first.id], from: doc)
    let pasted = clipboard.paste(into: &doc, imageSize: size)
    #expect(pasted.count == 2 && pasted.isDisjoint(with: [first.id, second.id]))
    #expect(doc.annotations[2].start == CGPoint(x: 120, y: 120))
    #expect(doc.annotations[2].leaderTarget == CGPoint(x: 40, y: 40))
    #expect(doc.number(for: doc.annotations[2].id) == 3)
    #expect(doc.number(for: doc.annotations[3].id) == 4)
    _ = clipboard.paste(into: &doc, imageSize: size)
    #expect(doc.annotations[4].start == CGPoint(x: 140, y: 140))
    #expect(doc.number(for: doc.annotations[4].id) == 5)
    let before = doc
    var history = AnnotationHistory(doc)
    let duplicated = doc.duplicate(pasted, imageSize: size)
    #expect(duplicated.count == 2)
    #expect(doc.annotations[6].start == CGPoint(x: 140, y: 140))
    history.commit(doc); history.undo()
    #expect(history.document == before)
    clipboard.copy([second.id], from: doc)
    _ = clipboard.paste(into: &doc, imageSize: size)
    #expect(doc.annotations.last?.start == CGPoint(x: 220, y: 120))
}

@Test func annotationCopiesKeepRestrictedToolsInsideAndPermitMargins() {
    let size = CGSize(width: 100, height: 100)
    for tool in [AnnotationTool.rectangle, .spotlight, .mosaic, .line, .arrow, .highlighter, .text] {
        let original = Annotation(tool: tool, start: CGPoint(x: 90, y: 90), end: CGPoint(x: 100, y: 100), text: "文字")
        var doc = AnnotationDocument(annotations: [original])
        var clipboard = AnnotationClipboard()
        clipboard.copy([original.id], from: doc)
        for _ in 0..<5 { _ = clipboard.paste(into: &doc, imageSize: size) }
        let copy = doc.annotations.last!
        if tool.allowsMargin {
            #expect(copy.start == CGPoint(x: 100, y: 100))
            #expect(doc.exportLayout(imageSize: size).right > 0)
        } else {
            #expect(copy.rect.maxX <= 100 && copy.rect.maxY <= 100)
            #expect(doc.exportLayout(imageSize: size).right == 0)
        }
    }
}

@Test func highlighterCopiesAndDuplicatesKeepBothSettings() {
    let pen = Annotation(tool: .highlighter, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 60, y: 20), highlighterColor: .pink, darkBackground: true)
    var document = AnnotationDocument(annotations: [pen])
    var clipboard = AnnotationClipboard()
    clipboard.copy([pen.id], from: document)
    _ = clipboard.paste(into: &document, imageSize: CGSize(width: 160, height: 100))
    _ = document.duplicate([pen.id], imageSize: CGSize(width: 160, height: 100))
    #expect(document.annotations.count == 3)
    for copy in document.annotations.dropFirst() {
        #expect(copy.id != pen.id && copy.highlighterColor == .pink && copy.darkBackground)
        #expect(copy.points != pen.points)
    }
}
