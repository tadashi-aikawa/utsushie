import Foundation
import Testing
@testable import UtsushieCore

@Test(arguments: AnnotationSize.allCases)
func annotationSizeScalesAllInkMetricsOnly(_ size: AnnotationSize) {
    let image = CGSize(width: 960, height: 600)
    let base = AnnotationStyle(imageSize: image)
    let scaled = AnnotationStyle(imageSize: image, size: size)
    for (actual, original) in [(scaled.fontSize, base.fontSize), (scaled.lineWidth, base.lineWidth),
                               (scaled.numberDiameter, base.numberDiameter), (scaled.edge, base.edge),
                               (scaled.radius, base.radius), (scaled.horizontalPadding, base.horizontalPadding),
                               (scaled.verticalPadding, base.verticalPadding), (scaled.highlighterWidth, base.highlighterWidth),
                               (scaled.leaderDotDiameter, base.leaderDotDiameter)] {
        #expect(abs(actual - original * size.multiplier) < 0.000001)
    }
    #expect(scaled.blockSize == base.blockSize)
    #expect(scaled.marginPadding == base.marginPadding)
    #expect(scaled.forAnnotation(Annotation(tool: .number, start: .zero, size: size)) == scaled)
}

@Test func annotationSizeKeysFollowUSAndJISAndRejectModifiersAndText() {
    for (jis, smaller, larger) in [(false, UInt16(33), UInt16(30)), (true, UInt16(30), UInt16(42))] {
        #expect(AnnotationSizeDirection(keyCode: smaller, isJIS: jis) == .smaller)
        #expect(AnnotationSizeDirection(keyCode: larger, isJIS: jis) == .larger)
        #expect(AnnotationSizeDirection(keyCode: smaller, isJIS: jis, modified: true) == nil)
        #expect(AnnotationSizeDirection(keyCode: larger, isJIS: jis, editingText: true) == nil)
    }
    #expect(AnnotationSizeDirection(keyCode: 42, isJIS: false) == nil)
    #expect(AnnotationSizeDirection(keyCode: 33, isJIS: true) == nil)
    #expect(AnnotationSize.smallest.stepped(.smaller) == .smallest)
    #expect(AnnotationSize.largest.stepped(.larger) == .largest)
    #expect(AnnotationSize.normal.stepped(.smaller) == .small)
    #expect(AnnotationSize.normal.stepped(.larger) == .large)
}

@Test func annotationSizeChangesMixedSelectionInOneUndoAndSkipsMosaic() {
    let image = CGSize(width: 960, height: 600)
    let first = Annotation(tool: .line, start: CGPoint(x: 50, y: 50), size: .small)
    let pen = Annotation(tool: .highlighter, start: CGPoint(x: 100, y: 100), size: .largest)
    let text = Annotation(tool: .text, start: CGPoint(x: 200, y: 200), end: CGPoint(x: 300, y: 240), text: "文字")
    let mosaic = Annotation(tool: .mosaic, start: .zero, size: .largest)
    let untouched = Annotation(tool: .number, start: CGPoint(x: 400, y: 400))
    let original = AnnotationDocument(annotations: [first, pen, text, mosaic, untouched])
    let ids: Set<UUID> = [pen.id, text.id, first.id, mosaic.id]
    let nextSize = original.steppedSize(ids, direction: .larger, defaultSize: .largest)
    #expect(nextSize == .normal)
    var history = AnnotationHistory(original)
    history.commit(original.settingSize(ids, size: nextSize, imageSize: image))
    #expect(history.document.annotations.prefix(3).allSatisfy { $0.size == .normal })
    #expect(history.document.annotations[3] == mosaic)
    #expect(history.document.annotations[4] == untouched)
    history.undo(); #expect(history.document == original)
    history.redo(); #expect(history.document.annotations[0].size == .normal)
    #expect(original.steppedSize([], direction: .smaller, defaultSize: .normal) == .small)
}

@Test func annotationSizeTextKeepsCenterAndMeasuresWithNewStyle() {
    let text = Annotation(tool: .text, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 200, y: 140), text: "札")
    let document = AnnotationDocument(annotations: [text])
    let result = document.settingSize([text.id], size: .largest, imageSize: CGSize(width: 960, height: 600)) { string, style in
        #expect(string == "札" && style.fontSize == 38.4)
        return CGSize(width: 140, height: 60)
    }.annotations[0]
    #expect(result.rect == CGRect(x: 80, y: 90, width: 140, height: 60))
}

@Test func annotationSizeCopiesAndLegacyDecodeRetainDefaultsAndHistory() throws {
    let annotation = Annotation(tool: .number, start: CGPoint(x: 100, y: 100), size: .largest)
    var document = AnnotationDocument(annotations: [annotation])
    var clipboard = AnnotationClipboard()
    clipboard.copy([annotation.id], from: document)
    let pasted = clipboard.paste(into: &document, imageSize: CGSize(width: 960, height: 600))
    #expect(document.annotations.filter { pasted.contains($0.id) }.allSatisfy { $0.size == .largest })
    let duplicated = document.duplicate([annotation.id], imageSize: CGSize(width: 960, height: 600))
    #expect(document.annotations.filter { duplicated.contains($0.id) }.allSatisfy { $0.size == .largest })
    let decoder = JSONDecoder(), encoder = JSONEncoder()
    var legacy = try #require(JSONSerialization.jsonObject(with: encoder.encode(annotation)) as? [String: Any])
    legacy.removeValue(forKey: "size")
    let decoded = try decoder.decode(Annotation.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.size == .normal)
    var history = AnnotationHistory(AnnotationDocument(annotations: [decoded]))
    history.commit(document)
    var restored = try decoder.decode(AnnotationHistory.self, from: encoder.encode(history))
    #expect(restored.document == document)
    restored.undo(); #expect(restored.document.annotations[0].size == .normal)
    restored.redo(); #expect(restored.document == document)
}

@Test func annotationSizeHitSelectionAndExportUseEachAnnotationsStyle() {
    let image = CGSize(width: 960, height: 600)
    let number = Annotation(tool: .number, start: CGPoint(x: 100, y: 100), size: .largest)
    let line = Annotation(tool: .line, start: CGPoint(x: 200, y: 200), end: CGPoint(x: 300, y: 200), size: .largest)
    let document = AnnotationDocument(annotations: [number, line])
    let style = AnnotationStyle(imageSize: image)
    #expect(document.hit(at: CGPoint(x: 125, y: 100), style: style, tolerance: 0) == number.id)
    #expect(document.hit(at: CGPoint(x: 250, y: 208), style: style, tolerance: 0) == line.id)
    #expect(document.intersecting(CGRect(x: 124, y: 99, width: 1, height: 2), style: style) == [number.id])
    let outside = Annotation(tool: .number, start: CGPoint(x: -50, y: 100), size: .largest)
    let bounds = style.forAnnotation(outside).numberRect(at: outside.start, number: 1)
    let ink = AnnotationGeometry.inkBounds(of: outside, bounds: bounds, style: style)
    let layout = AnnotationDocument(annotations: [outside]).exportLayout(imageSize: image)
    #expect(abs(layout.bounds.minX - floor(ink.minX - style.marginPadding)) < 0.000001)
}

@Test func annotationSizeControlsFollowColorControls() {
    for tool in AnnotationTool.allCases {
        for selection in [[AnnotationTool](), [.mosaic], [.highlighter], [.number, .highlighter]] {
            #expect(AnnotationToolbarPresentation.showsSizeControls(tool: tool, selectedTools: selection)
                == (AnnotationToolbarPresentation.colorControls(tool: tool, selectedTools: selection) != .none))
        }
    }
}
