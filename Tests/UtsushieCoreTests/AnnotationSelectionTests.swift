import Foundation
import Testing
@testable import UtsushieCore

@Test func highlighterShiftSnapsToNearestAxisAndClampsAfterChoosingAxis() {
    let anchor = CGPoint(x: 50, y: 50)
    let size = CGSize(width: 100, height: 80)
    let cases: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 90, y: 30), CGPoint(x: 90, y: 50)),
        (CGPoint(x: 70, y: 10), CGPoint(x: 50, y: 10)),
        (CGPoint(x: 10, y: 70), CGPoint(x: 10, y: 50)),
        (CGPoint(x: 30, y: 90), CGPoint(x: 50, y: 80)),
        (CGPoint(x: 80, y: 20), CGPoint(x: 80, y: 50)),
        (CGPoint(x: 20, y: 80), CGPoint(x: 20, y: 50)),
        (anchor, anchor),
        (CGPoint(x: 200, y: -50), CGPoint(x: 100, y: 50)),
        (CGPoint(x: -100, y: 150), CGPoint(x: 0, y: 50)),
        (CGPoint(x: 80, y: -100), CGPoint(x: 50, y: 0)),
        (CGPoint(x: 120, y: 200), CGPoint(x: 50, y: 80)),
    ]
    for (point, expected) in cases {
        #expect(AnnotationGeometry.highlighterEndpoint(point, from: anchor, imageSize: size) == expected)
        let pen = Annotation(tool: .highlighter, start: anchor)
        #expect(AnnotationGeometry.creating(pen, to: point, shift: true, imageSize: size).end == expected)
        #expect(AnnotationGeometry.creating(pen, to: point, shift: false, imageSize: size).end == AnnotationGeometry.clamped(point, to: size))
    }
}

@Test func marqueeSelectsPartialIntersectionAndPolylineSegments() {
    let area = Annotation(tool: .rectangle, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 80, y: 80))
    let line = Annotation(tool: .line, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 200, y: 200))
    let pen = Annotation(tool: .highlighter, start: CGPoint(x: 220, y: 100),
                         points: [CGPoint(x: 220, y: 100), CGPoint(x: 280, y: 100), CGPoint(x: 280, y: 200)])
    let doc = AnnotationDocument(annotations: [area, line, pen])
    let style = AnnotationStyle()
    #expect(doc.intersecting(CGRect(x: 70, y: 70, width: 10, height: 20), style: style) == [area.id])
    #expect(doc.intersecting(CGRect(x: 145, y: 145, width: 5, height: 5), style: style) == [line.id])
    #expect(doc.intersecting(CGRect(x: 100, y: 180, width: 10, height: 10), style: style).isEmpty)
    #expect(doc.intersecting(CGRect(x: 230, y: 140, width: 10, height: 10), style: style).isEmpty)
    #expect(doc.intersecting(CGRect(x: 282, y: 140, width: 2, height: 10), style: style) == [pen.id])
    // 蛍光ペンを縦に引いた部分はペン先の帯の幅だけ。
    #expect(doc.intersecting(CGRect(x: 280 + style.highlighterTip.width / 2 + 1, y: 140, width: 2, height: 10), style: style).isEmpty)
    #expect(doc.intersecting(CGRect(x: 250, y: 100 + style.highlighterTip.height / 2 - 2, width: 2, height: 2), style: style) == [pen.id])
}

@Test func multipleSelectionMovesTogetherDeletesAndUndoesAsOneOperation() {
    let mosaic = Annotation(tool: .mosaic, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 60, y: 60))
    let label = Annotation(tool: .text, start: CGPoint(x: 100, y: 80), end: CGPoint(x: 160, y: 110), text: "説明", leaderTarget: CGPoint(x: 50, y: 50))
    let doc = AnnotationDocument(annotations: [mosaic, label])
    let ids: Set<UUID> = [mosaic.id, label.id]
    let moved = doc.moving(ids, by: CGPoint(x: -40, y: 20), imageSize: CGSize(width: 400, height: 300))
    #expect(moved.annotations[0].start == CGPoint(x: 0, y: 30))
    #expect(moved.annotations[1].start == CGPoint(x: 90, y: 100))
    // 複数選択では指す点も同じ量だけ動く。モザイクが端で止めた分、全体の移動量も止まる。
    #expect(moved.annotations[1].leaderTarget == CGPoint(x: 40, y: 70))
    var history = AnnotationHistory(doc)
    history.commit(moved); history.undo()
    #expect(history.document == doc)
    var deleted = doc; deleted.remove(ids); history.commit(deleted)
    #expect(history.document.annotations.isEmpty)
    history.undo(); #expect(history.document == doc)
    for tool in AnnotationTool.allCases {
        let style = AnnotationStyle()
        for point in [mosaic.start, CGPoint(x: 30, y: 30)] {
            #expect(doc.interaction(at: point, selected: ids, tool: tool, style: style, tolerance: 7) == .move(mosaic.id))
        }
    }
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
        let created = AnnotationGeometry.creating(Annotation(tool: tool, start: anchor), to: CGPoint(x: 90, y: 70), shift: true, imageSize: size)
        #expect(abs(created.rect.width - created.rect.height) < 0.000001)
        #expect(created.rect.maxY <= size.height)
        let annotation = Annotation(tool: tool, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 40, y: 30))
        for handle in [AnnotationResizeHandle.topLeft, .topRight, .bottomLeft, .bottomRight] {
            let resized = AnnotationGeometry.resized(annotation, handle: handle, to: CGPoint(x: 95, y: 70), shift: true, imageSize: size)
            #expect(resized.rect.width == resized.rect.height)
        }
        let edge = AnnotationGeometry.resized(annotation, handle: .right, to: CGPoint(x: 95, y: 70), shift: true, imageSize: size)
        #expect(edge.rect.height == 20)
        #expect(edge.rect.width == min(95, AnnotationGeometry.areaDrawingRect(tool: tool, imageSize: size).maxX) - 10)
    }
    for tool in [AnnotationTool.line, .arrow] {
        let annotation = Annotation(tool: tool, start: anchor, end: CGPoint(x: 90, y: 70))
        let changed = AnnotationGeometry.resized(annotation, handle: .arrowEnd, to: CGPoint(x: 100, y: 90), shift: true, imageSize: size)
        #expect(abs(changed.end.x - changed.end.y) < 0.00001)
    }
    let wideImage = CGSize(width: 160, height: 100)
    let large = AnnotationGeometry.creating(Annotation(tool: .rectangle, start: .zero), to: CGPoint(x: 120, y: 120), shift: true, imageSize: wideImage)
    let placed = AnnotationGeometry.placed(large, bounds: large.rect, imageSize: wideImage)
    #expect(placed.rect.size == CGSize(width: 93, height: 93))
}
