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
