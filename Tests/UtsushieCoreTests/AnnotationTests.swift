import Foundation
import Testing
@testable import UtsushieCore

@Test func annotationNumbersFollowCreationOrderAcrossDeleteUndoRedo() {
    let first = Annotation(tool: .number, start: .zero)
    let second = Annotation(tool: .number, start: CGPoint(x: 20, y: 20))
    let third = Annotation(tool: .number, start: CGPoint(x: 40, y: 40))
    var document = AnnotationDocument(annotations: [first, Annotation(tool: .rectangle, start: .zero), second, third])
    var history = AnnotationHistory(document)
    document.remove(second.id); history.commit(document)
    #expect(history.document.number(for: third.id) == 2)
    #expect(history.document.nextNumber == 3)
    history.undo()
    #expect(history.document.number(for: third.id) == 3)
    history.redo()
    #expect(history.document.number(for: third.id) == 2)
    history.undo(); document = history.document; document.remove(first.id); history.commit(document)
    #expect(!history.canRedo)
    #expect(history.document.number(for: second.id) == 1)
}
@Test func annotationStyleScalesFromImagePixels() {
    let style = AnnotationStyle(imageSize: CGSize(width: 960, height: 600))
    #expect(style.fontSize == 19.2)
    #expect(style.lineWidth == 3)
    #expect(style.edge == 2 && style.radius == 6)
    #expect(style.horizontalPadding == 11 && style.verticalPadding == 6)
    #expect(abs(style.numberDiameter - 28.8) < 0.0001)
    #expect(style.blockSize == 16)
    let tiny = AnnotationStyle(imageSize: CGSize(width: 20, height: 10))
    #expect(tiny.fontSize == 16 && tiny.lineWidth == 3 && tiny.blockSize == 8)
    let large = AnnotationStyle(imageSize: CGSize(width: 4000, height: 2000))
    #expect(large.fontSize == 80 && large.lineWidth == 10)
    #expect(style.numberRect(at: .zero, number: 12).width > style.numberRect(at: .zero, number: 1).width)
}
@Test func annotationHitUsesFixedLayersAndArrowSegment() {
    let rect = Annotation(tool: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 100, y: 100))
    let number = Annotation(tool: .number, start: CGPoint(x: 50, y: 50))
    let mosaic = Annotation(tool: .mosaic, start: .zero, end: CGPoint(x: 200, y: 200))
    let arrow = Annotation(tool: .arrow, start: .zero, end: CGPoint(x: 100, y: 100))
    let doc = AnnotationDocument(annotations: [number, rect, arrow, mosaic])
    let style = AnnotationStyle(imageSize: CGSize(width: 960, height: 600))
    #expect(doc.hit(at: CGPoint(x: 50, y: 50), style: style, tolerance: 3) == number.id)
    #expect(doc.hit(at: CGPoint(x: 70, y: 72), style: style, tolerance: 3) == arrow.id)
    #expect(doc.hit(at: CGPoint(x: 10, y: 40), style: style, tolerance: 3) == rect.id)
    #expect(doc.hit(at: CGPoint(x: 60, y: 30), style: style, tolerance: 3) == nil)
    #expect(doc.hit(at: CGPoint(x: 0, y: 150), style: style, tolerance: 3) == mosaic.id)
    #expect(doc.ordered.map(\.tool) == [.mosaic, .rectangle, .arrow, .number])
}
@Test(arguments: [AnnotationTool.rectangle, .spotlight, .mosaic])
func annotationAreaHitOnlySelectsEdgeBand(_ tool: AnnotationTool) {
    let area = Annotation(tool: tool, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 180, y: 180))
    let style = AnnotationStyle(imageSize: CGSize(width: 960, height: 600))
    let document = AnnotationDocument(annotations: [area])
    #expect(document.hit(at: CGPoint(x: 100, y: 100), style: style, tolerance: 6) == nil)
    for point in [CGPoint(x: 20, y: 100), CGPoint(x: 180, y: 100), CGPoint(x: 100, y: 20), CGPoint(x: 100, y: 180), CGPoint(x: 15, y: 100), CGPoint(x: 25, y: 100)] {
        #expect(document.hit(at: point, style: style, tolerance: 6) == area.id)
    }
    #expect(document.hit(at: CGPoint(x: 13, y: 100), style: style, tolerance: 6) == nil)
    #expect(document.hit(at: CGPoint(x: 27, y: 100), style: style, tolerance: 6) == nil)
    #expect(AnnotationGeometry.handles(for: area).count == 4)
    let rectangle = Annotation(tool: .rectangle, start: CGPoint(x: 50, y: 50), end: CGPoint(x: 150, y: 150))
    let nested = AnnotationDocument(annotations: [rectangle, area])
    #expect(nested.hit(at: CGPoint(x: 50, y: 100), style: style, tolerance: 6) == rectangle.id)
}
@Test func annotationDragThresholdUsesDisplayPointsAndAllowsHorizontalArrows() {
    #expect(!AnnotationGeometry.isValidDrag(tool: .rectangle, from: .zero, to: CGPoint(x: 8, y: 80), displayScale: 0.5))
    #expect(AnnotationGeometry.isValidDrag(tool: .rectangle, from: .zero, to: CGPoint(x: 9, y: 9), displayScale: 0.5))
    #expect(AnnotationGeometry.isValidDrag(tool: .arrow, from: .zero, to: CGPoint(x: 20, y: 0), displayScale: 1))
    #expect(!AnnotationGeometry.isValidDrag(tool: .arrow, from: .zero, to: CGPoint(x: 4, y: 0), displayScale: 1))
}
@Test func annotationResizeKeepsOppositeCornerAndArrowEndpoint() {
    let rect = Annotation(tool: .spotlight, start: CGPoint(x: 10, y: 20), end: CGPoint(x: 100, y: 80))
    let resized = AnnotationGeometry.resized(rect, handle: .topRight, to: CGPoint(x: 120, y: 10))
    #expect(resized.rect == CGRect(x: 10, y: 10, width: 110, height: 70))
    let arrow = Annotation(tool: .arrow, start: CGPoint(x: 10, y: 20), end: CGPoint(x: 100, y: 80))
    let adjusted = AnnotationGeometry.resized(arrow, handle: .arrowStart, to: .zero)
    #expect(adjusted.start == .zero && adjusted.end == arrow.end)
    #expect(AnnotationGeometry.distance(CGPoint(x: 5, y: 5), toSegmentFrom: .zero, to: .zero) == hypot(5, 5))
}
@Test(arguments: [AnnotationTool.rectangle, .spotlight, .mosaic])
func annotationAreaInteractionResizesOnlySelectedEdgesAndMovesInteriorInSelection(_ areaTool: AnnotationTool) {
    let area = Annotation(tool: areaTool, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 180, y: 140))
    let document = AnnotationDocument(annotations: [area])
    let style = AnnotationStyle(imageSize: CGSize(width: 960, height: 600))
    let locations: [(CGPoint, AnnotationResizeHandle, AnnotationCursor)] = [
        (CGPoint(x: 20, y: 20), .topLeft, .diagonalDown),
        (CGPoint(x: 180, y: 20), .topRight, .diagonalUp),
        (CGPoint(x: 180, y: 140), .bottomRight, .diagonalDown),
        (CGPoint(x: 20, y: 140), .bottomLeft, .diagonalUp),
        (CGPoint(x: 50, y: 20), .top, .vertical),
        (CGPoint(x: 180, y: 60), .right, .horizontal),
        (CGPoint(x: 140, y: 140), .bottom, .vertical),
        (CGPoint(x: 20, y: 100), .left, .horizontal),
    ]
    for mode in AnnotationTool.allCases {
        for (point, handle, cursor) in locations {
            let action = document.interaction(at: point, selected: area.id, tool: mode, style: style, tolerance: 7)
            #expect(action == .resize(area.id, handle))
            #expect(action.cursor(tool: mode) == cursor)
            #expect(document.interaction(at: point, selected: nil, tool: mode, style: style, tolerance: 7) == .move(area.id))
        }
        let interior = document.interaction(at: CGPoint(x: 100, y: 80), selected: area.id, tool: mode, style: style, tolerance: 7)
        #expect(interior == (mode == .selection ? .move(area.id) : .create))
        let empty = document.interaction(at: CGPoint(x: 250, y: 200), selected: area.id, tool: mode, style: style, tolerance: 7)
        #expect(empty == (mode == .selection ? .none : .create))
        #expect(empty.cursor(tool: mode) == (mode == .selection ? .arrow : .crosshair))
    }
}
@Test func annotationEdgeResizeMovesOnlySpecifiedEdge() {
    // start/endを逆順に作った枠でも、見た目の上下左右を基準にする。
    let area = Annotation(tool: .rectangle, start: CGPoint(x: 180, y: 140), end: CGPoint(x: 20, y: 20))
    let point = CGPoint(x: 5, y: 8)
    #expect(AnnotationGeometry.resized(area, handle: .top, to: point).rect == CGRect(x: 20, y: 8, width: 160, height: 132))
    #expect(AnnotationGeometry.resized(area, handle: .bottom, to: point).rect == CGRect(x: 20, y: 8, width: 160, height: 12))
    #expect(AnnotationGeometry.resized(area, handle: .left, to: point).rect == CGRect(x: 5, y: 20, width: 175, height: 120))
    #expect(AnnotationGeometry.resized(area, handle: .right, to: point).rect == CGRect(x: 5, y: 20, width: 15, height: 120))
}
@Test func annotationArrowTextAndNumberInteractionsKeepMoveAndEndpointHandles() {
    let arrow = Annotation(tool: .arrow, start: CGPoint(x: 20, y: 30), end: CGPoint(x: 120, y: 30))
    let label = Annotation(tool: .text, start: CGPoint(x: 20, y: 60), end: CGPoint(x: 120, y: 100), text: "ラベル")
    let number = Annotation(tool: .number, start: CGPoint(x: 160, y: 100))
    let document = AnnotationDocument(annotations: [arrow, label, number])
    let style = AnnotationStyle(imageSize: CGSize(width: 960, height: 600))
    for mode in AnnotationTool.allCases {
        for (point, id) in [(CGPoint(x: 70, y: 30), arrow.id), (CGPoint(x: 70, y: 80), label.id), (CGPoint(x: 160, y: 100), number.id)] {
            let action = document.interaction(at: point, selected: nil, tool: mode, style: style, tolerance: 7)
            #expect(action == .move(id))
            #expect(action.cursor(tool: mode) == .move)
        }
        #expect(document.interaction(at: arrow.start, selected: arrow.id, tool: mode, style: style, tolerance: 7) == .resize(arrow.id, .arrowStart))
        let end = document.interaction(at: arrow.end, selected: arrow.id, tool: mode, style: style, tolerance: 7)
        #expect(end == .resize(arrow.id, .arrowEnd))
        #expect(end.cursor(tool: mode) == .crosshair)
    }
}
@Test func unchangedAnnotationDoesNotCreateUndoStep() {
    var history = AnnotationHistory()
    history.commit(history.document)
    #expect(!history.canUndo)
    history.undo(); history.redo()
    #expect(history.document.annotations.isEmpty)
}
