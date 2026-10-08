import Foundation
import Testing
@testable import UtsushieCore

@Test func marqueeSelectsPartialIntersectionAndPolylineSegments() {
    let area = Annotation(tool: .rectangle, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 80, y: 80))
    let line = Annotation(tool: .line, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 200, y: 200))
    let pen = Annotation(tool: .highlighter, start: CGPoint(x: 220, y: 100),
                         points: [CGPoint(x: 220, y: 100), CGPoint(x: 280, y: 100), CGPoint(x: 280, y: 200)])
    let doc = AnnotationDocument(annotations: [area, line, pen])
    let style = AnnotationStyle(imageSize: CGSize(width: 400, height: 300))
    #expect(doc.intersecting(CGRect(x: 70, y: 70, width: 10, height: 20), style: style) == [area.id])
    #expect(doc.intersecting(CGRect(x: 145, y: 145, width: 5, height: 5), style: style) == [line.id])
    #expect(doc.intersecting(CGRect(x: 100, y: 180, width: 10, height: 10), style: style).isEmpty)
    #expect(doc.intersecting(CGRect(x: 230, y: 140, width: 10, height: 10), style: style).isEmpty)
    #expect(doc.intersecting(CGRect(x: 284, y: 140, width: 2, height: 10), style: style) == [pen.id])
}

@Test func multipleSelectionMovesTogetherDeletesAndUndoesAsOneOperation() {
    let mosaic = Annotation(tool: .mosaic, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 60, y: 60))
    let label = Annotation(tool: .text, start: CGPoint(x: 100, y: 80), end: CGPoint(x: 160, y: 110), text: "説明", leaderTarget: CGPoint(x: 50, y: 50))
    let doc = AnnotationDocument(annotations: [mosaic, label])
    let ids: Set<UUID> = [mosaic.id, label.id]
    let moved = doc.moving(ids, by: CGPoint(x: -40, y: 20), imageSize: CGSize(width: 400, height: 300))
    #expect(moved.annotations[0].start == CGPoint(x: 0, y: 30))
    #expect(moved.annotations[1].start == CGPoint(x: 90, y: 100))
    #expect(moved.annotations[1].leaderTarget == label.leaderTarget)
    var history = AnnotationHistory(doc)
    history.commit(moved); history.undo()
    #expect(history.document == doc)
    var deleted = doc; deleted.remove(ids); history.commit(deleted)
    #expect(history.document.annotations.isEmpty)
    history.undo(); #expect(history.document == doc)
    #expect(doc.interaction(at: mosaic.start, selected: ids, tool: .selection,
                            style: AnnotationStyle(imageSize: CGSize(width: 400, height: 300)), tolerance: 7) == .move(mosaic.id))
}

@Test func shiftConstrainsMovementAngleAndSquare() {
    #expect(AnnotationGeometry.axisConstrained(CGPoint(x: -40, y: 20)) == CGPoint(x: -40, y: 0))
    #expect(AnnotationGeometry.axisConstrained(CGPoint(x: 10, y: -30)) == CGPoint(x: 0, y: -30))
    let anchor = CGPoint(x: 50, y: 50)
    let endpoint = AnnotationGeometry.angleConstrained(CGPoint(x: 150, y: 130), from: anchor)
    #expect(abs(endpoint.x - endpoint.y) < 0.00001)
    let square = AnnotationGeometry.squareConstrained(CGPoint(x: 90, y: 20), from: anchor)
    #expect(square == CGPoint(x: 90, y: 10))
    let size = CGSize(width: 100, height: 80)
    for tool in [AnnotationTool.rectangle, .spotlight, .mosaic] {
        let p = AnnotationGeometry.creationPoint(CGPoint(x: 90, y: 70), from: anchor, tool: tool, shift: true, imageSize: size)
        #expect(abs(p.x - anchor.x) == abs(p.y - anchor.y))
        if tool != .rectangle { #expect(p.y <= size.height) }
        let annotation = Annotation(tool: tool, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 40, y: 30))
        for handle in [AnnotationResizeHandle.topLeft, .topRight, .bottomLeft, .bottomRight] {
            let resized = AnnotationGeometry.resized(annotation, handle: handle, to: CGPoint(x: 95, y: 70), shift: true, imageSize: size)
            #expect(resized.rect.width == resized.rect.height)
        }
        let edge = AnnotationGeometry.resized(annotation, handle: .right, to: CGPoint(x: 95, y: 70), shift: true, imageSize: size)
        #expect(edge.rect.height == 20 && edge.rect.width == 85)
    }
    for tool in [AnnotationTool.line, .arrow] {
        let annotation = Annotation(tool: tool, start: anchor, end: CGPoint(x: 90, y: 70))
        let changed = AnnotationGeometry.resized(annotation, handle: .arrowEnd, to: CGPoint(x: 100, y: 90), shift: true, imageSize: size)
        #expect(abs(changed.end.x - changed.end.y) < 0.00001)
    }
}
