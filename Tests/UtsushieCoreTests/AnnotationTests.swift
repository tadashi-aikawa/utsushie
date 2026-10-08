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
    #expect(document.hit(at: CGPoint(x: 13, y: 100), style: style, tolerance: 6) == (tool == .spotlight ? area.id : nil))
    #expect(document.hit(at: CGPoint(x: 12, y: 100), style: style, tolerance: 6) == nil)
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
func annotationAreaInteractionResizesUnselectedEdgesAndMovesInteriorInSelection(_ areaTool: AnnotationTool) {
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
            let action = document.interaction(at: point, selected: [area.id], tool: mode, style: style, tolerance: 7)
            #expect(action == .resize(area.id, handle))
            #expect(action.cursor(tool: mode) == cursor)
            let unselected = document.interaction(at: point, selected: [], tool: mode, style: style, tolerance: 7)
            #expect(unselected == .resize(area.id, handle))
            #expect(unselected.cursor(tool: mode) == cursor)
        }
        let interior = document.interaction(at: CGPoint(x: 100, y: 80), selected: [area.id], tool: mode, style: style, tolerance: 7)
        #expect(interior == (mode == .selection ? .move(area.id) : .create))
        let empty = document.interaction(at: CGPoint(x: 250, y: 200), selected: [area.id], tool: mode, style: style, tolerance: 7)
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
            let action = document.interaction(at: point, selected: [], tool: mode, style: style, tolerance: 7)
            #expect(action == .move(id))
            #expect(action.cursor(tool: mode) == .move)
        }
        #expect(document.interaction(at: arrow.start, selected: [arrow.id], tool: mode, style: style, tolerance: 7) == .resize(arrow.id, .arrowStart))
        #expect(document.interaction(at: arrow.start, selected: [], tool: mode, style: style, tolerance: 7) == .resize(arrow.id, .arrowStart))
        #expect(document.interaction(at: arrow.end, selected: [], tool: mode, style: style, tolerance: 7) == .resize(arrow.id, .arrowEnd))
        let end = document.interaction(at: arrow.end, selected: [arrow.id], tool: mode, style: style, tolerance: 7)
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

@Test func annotationMarginExpandsOnlyRequiredEdgesAndIncludesInkAndPadding() {
    let size = CGSize(width: 960, height: 600)
    let right = Annotation(tool: .text, start: CGPoint(x: 984, y: 163), end: CGPoint(x: 1219, y: 197), text: "説明")
    let topLeft = Annotation(tool: .rectangle, start: CGPoint(x: -100, y: -80), end: CGPoint(x: -20, y: -10))
    let bottom = Annotation(tool: .arrow, start: CGPoint(x: 200, y: 620), end: CGPoint(x: 300, y: 620))
    let inside = Annotation(tool: .text, start: CGPoint(x: 940, y: 100), end: CGPoint(x: 965, y: 130))
    let document = AnnotationDocument(annotations: [right, topLeft, bottom, inside])
    let layout = document.exportLayout(imageSize: size)
    #expect(layout.left == 128 && layout.top == 108 && layout.right == 285 && layout.bottom == 55)
    #expect(layout.bounds == CGRect(x: -128, y: -108, width: 1373, height: 763))
    let rightOnly = AnnotationDocument(annotations: [right]).exportLayout(imageSize: size)
    #expect(rightOnly.left == 0 && rightOnly.top == 0 && rightOnly.bottom == 0 && rightOnly.right == 285)
    #expect(rightOnly.summary == "書き出し 1245 × 600 右に余白 285")
    #expect(AnnotationDocument(annotations: [inside]).exportLayout(imageSize: size).bounds.size == size)
    #expect(AnnotationStyle(imageSize: CGSize(width: 1920, height: 1200)).marginPadding == 48)
    #expect(AnnotationStyle(imageSize: size).leaderDotDiameter == 9)
    #expect(AnnotationDocument(annotations: document.annotations.reversed()).exportLayout(imageSize: size) == layout)
}

@Test(arguments: AnnotationTool.allCases)
func annotationPlacementUsesCenterAndToolRestriction(_ tool: AnnotationTool) {
    let size = CGSize(width: 960, height: 600)
    let style = AnnotationStyle(imageSize: size)
    let document = AnnotationDocument()
    let outside = Annotation(tool: tool, start: CGPoint(x: -100, y: 200), end: CGPoint(x: -20, y: 280))
    let bounds = document.bounds(of: outside, style: style)
    let placed = AnnotationGeometry.placed(outside, bounds: bounds, imageSize: size)
    #expect(placed == (tool.allowsMargin ? outside : outside.translated(by: CGPoint(x: -bounds.minX, y: 0))))
    if !tool.allowsMargin { #expect(AnnotationDocument(annotations: [outside]).exportLayout(imageSize: size).bounds.size == size) }
    let crossing = Annotation(tool: tool, start: CGPoint(x: -10, y: 200), end: CGPoint(x: 70, y: 280))
    let crossingBounds = document.bounds(of: crossing, style: style)
    let inImage = AnnotationGeometry.placed(crossing, bounds: crossingBounds, imageSize: size)
    if tool == .arrow { #expect(inImage == crossing) }
    else if AnnotationGeometry.containsCenter(of: crossingBounds, in: CGRect(origin: .zero, size: size)) {
        #expect(document.bounds(of: inImage, style: style).minX == 0)
    }
}

@Test func annotationMarginShrinksAfterMoveDeleteUndoAndRedo() {
    let size = CGSize(width: 960, height: 600)
    let label = Annotation(tool: .text, start: CGPoint(x: 1000, y: 100), end: CGPoint(x: 1100, y: 140), text: "説明")
    var history = AnnotationHistory()
    let outside = AnnotationDocument(annotations: [label])
    history.commit(outside)
    #expect(history.document.exportLayout(imageSize: size).right == 166)
    history.commit(AnnotationDocument(annotations: [label.translated(by: CGPoint(x: -500, y: 0))]))
    #expect(history.document.exportLayout(imageSize: size).right == 0)
    history.undo()
    #expect(history.document.exportLayout(imageSize: size).right == 166)
    history.redo()
    #expect(history.document.exportLayout(imageSize: size).right == 0)
    history.commit(outside); history.commit(AnnotationDocument())
    #expect(history.document.exportLayout(imageSize: size).bounds.size == size)
}

@Test(arguments: [AnnotationTool.rectangle, .spotlight, .mosaic])
func annotationOversizedShapeWithCenterInsideIsKeptInside(_ tool: AnnotationTool) {
    let size = CGSize(width: 960, height: 600)
    let annotation = Annotation(tool: tool, start: CGPoint(x: -100, y: -100), end: CGPoint(x: 1060, y: 700))
    let placed = AnnotationGeometry.placed(annotation, bounds: annotation.rect, imageSize: size)
    #expect(placed.rect == CGRect(origin: .zero, size: size))
    #expect(AnnotationDocument(annotations: [placed]).exportLayout(imageSize: size).bounds.size == size)
}

@Test func annotationArrowEndpointsCanLeaveImageWhileCenterStaysInside() {
    let size = CGSize(width: 960, height: 600)
    let cases = [
        Annotation(tool: .arrow, start: CGPoint(x: 100, y: 200), end: CGPoint(x: 1000, y: 200)),
        Annotation(tool: .arrow, start: CGPoint(x: -40, y: 300), end: CGPoint(x: 800, y: 300)),
        Annotation(tool: .arrow, start: CGPoint(x: 300, y: 100), end: CGPoint(x: 300, y: 640)),
        Annotation(tool: .arrow, start: CGPoint(x: 300, y: -40), end: CGPoint(x: 300, y: 500))
    ]
    for (index, arrow) in cases.enumerated() {
        #expect(AnnotationGeometry.containsCenter(of: arrow.rect, in: CGRect(origin: .zero, size: size)))
        #expect(AnnotationGeometry.placed(arrow, bounds: arrow.rect, imageSize: size) == arrow)
        let layout = AnnotationDocument(annotations: [arrow]).exportLayout(imageSize: size)
        #expect([layout.right, layout.left, layout.bottom, layout.top][index] > 40)
    }
    let inside = Annotation(tool: .arrow, start: CGPoint(x: 100, y: 300), end: CGPoint(x: 900, y: 300))
    #expect(AnnotationDocument(annotations: [inside]).exportLayout(imageSize: size).bounds.size == size)
}

@Test func annotationNumberLeaderUsesCircleAndCapsuleEdgeAfterRenumbering() throws {
    let style = AnnotationStyle(imageSize: CGSize(width: 960, height: 600))
    var numbers = (1...12).map { _ in Annotation(tool: .number, start: CGPoint(x: 300, y: 120), leaderTarget: CGPoint(x: 100, y: 120)) }
    var document = AnnotationDocument(annotations: numbers)
    let last = numbers[11]
    let capsule = try #require(document.leaderSegment(for: last, style: style))
    #expect(abs(capsule.labelEdge.x - document.bounds(of: last, style: style).minX) < 0.0001)
    numbers.removeFirst(); numbers.removeFirst(); numbers.removeFirst()
    document = AnnotationDocument(annotations: numbers)
    let circle = try #require(document.leaderSegment(for: last, style: style))
    #expect(circle.labelEdge.x > capsule.labelEdge.x)
    #expect(document.number(for: last.id) == 9)
    for tool in AnnotationTool.allCases {
        #expect(document.interaction(at: last.leaderTarget!, selected: [], tool: tool, style: style, tolerance: 7) == .resize(last.id, .leaderTarget))
        #expect(document.hit(at: CGPoint(x: 200, y: 120), style: style, tolerance: 7) == last.id)
    }
    let moved = last.translated(by: CGPoint(x: 30, y: 40))
    #expect(moved.start == CGPoint(x: 330, y: 160) && moved.leaderTarget == last.leaderTarget)
    let hidden = Annotation(tool: .number, start: last.start, leaderTarget: last.start)
    let hiddenDocument = AnnotationDocument(annotations: [hidden])
    #expect(hiddenDocument.leaderSegment(for: hidden, style: style) == nil)
    #expect(hiddenDocument.interaction(at: hidden.start, selected: [], tool: .selection, style: style, tolerance: 7) == .move(hidden.id))
    #expect(hiddenDocument.interaction(at: hidden.start, selected: [hidden.id], tool: .selection, style: style, tolerance: 7) == .resize(hidden.id, .leaderTarget))
}

@Test func annotationSpotVisibleOuterFrameResizesAtHighZoomWithoutSelection() {
    let spot = Annotation(tool: .spotlight, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 300, y: 300))
    let document = AnnotationDocument(annotations: [spot])
    let style = AnnotationStyle(imageSize: CGSize(width: 960, height: 600))
    for tool in AnnotationTool.allCases {
        let action = document.interaction(at: CGPoint(x: 95, y: 200), selected: [], tool: tool, style: style, tolerance: 7 / 4)
        #expect(action == .resize(spot.id, .left))
        #expect(action.cursor(tool: tool) == .horizontal)
    }
}

@Test func annotationCornerAndEndpointHandlesKeepSevenPointToleranceWhenZoomed() {
    let rect = Annotation(tool: .rectangle, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 300, y: 300))
    let arrow = Annotation(tool: .arrow, start: CGPoint(x: 100, y: 50), end: CGPoint(x: 300, y: 50))
    let label = Annotation(tool: .number, start: CGPoint(x: 300, y: 200), leaderTarget: CGPoint(x: 100, y: 200))
    let style = AnnotationStyle(imageSize: CGSize(width: 960, height: 600))
    for annotation in [rect, arrow, label] {
        let handle = annotation.tool == .number ? annotation.leaderTarget! : annotation.start
        #expect(AnnotationGeometry.resizeHandle(at: CGPoint(x: handle.x + 1.5, y: handle.y), annotation: annotation, tolerance: 7 / 4) != nil)
        if annotation.tool != .rectangle {
            #expect(AnnotationGeometry.resizeHandle(at: CGPoint(x: handle.x + 2, y: handle.y), annotation: annotation, tolerance: 7 / 4) == nil)
        }
    }
    let document = AnnotationDocument(annotations: [rect])
    #expect(document.interaction(at: CGPoint(x: 102, y: 102), selected: [], tool: .selection, style: style, tolerance: 7 / 4) == .resize(rect.id, .top))
}

@Test func annotationLeaderIntersectionIncludesRoundedCornerAndHidesInsideTarget() throws {
    var label = Annotation(tool: .text, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 200, y: 140), leaderTarget: CGPoint(x: 20, y: 120))
    let horizontal = try #require(AnnotationGeometry.leaderSegment(for: label, radius: 6))
    #expect(abs(horizontal.labelEdge.x - 100) < 0.0001 && abs(horizontal.labelEdge.y - 120) < 0.0001)
    label.leaderTarget = CGPoint(x: 150, y: 40)
    let vertical = try #require(AnnotationGeometry.leaderSegment(for: label, radius: 6))
    #expect(abs(vertical.labelEdge.x - 150) < 0.0001 && abs(vertical.labelEdge.y - 100) < 0.0001)
    label.leaderTarget = CGPoint(x: 0, y: 60)
    let corner = try #require(AnnotationGeometry.leaderSegment(for: label, radius: 6))
    #expect(corner.labelEdge.x > 100 && corner.labelEdge.y >= 100)
    label.leaderTarget = CGPoint(x: 130, y: 120)
    #expect(AnnotationGeometry.leaderSegment(for: label, radius: 6) == nil)
    label.leaderTarget = nil
    #expect(AnnotationGeometry.leaderSegment(for: label, radius: 6) == nil)
    #expect(!AnnotationGeometry.isValidDrag(tool: .text, from: .zero, to: CGPoint(x: 8, y: 0), displayScale: 0.5))
    #expect(AnnotationGeometry.isValidDrag(tool: .text, from: .zero, to: CGPoint(x: 9, y: 0), displayScale: 0.5))
}

@Test func annotationLeaderMovesLabelAndTargetIndependentlyAndHitsLine() {
    let label = Annotation(tool: .text, start: CGPoint(x: 200, y: 100), end: CGPoint(x: 300, y: 140), text: "説明", leaderTarget: CGPoint(x: 20, y: 120))
    let document = AnnotationDocument(annotations: [label])
    let style = AnnotationStyle(imageSize: CGSize(width: 960, height: 600))
    #expect(document.hit(at: CGPoint(x: 100, y: 122), style: style, tolerance: 7) == label.id)
    #expect(document.hit(at: CGPoint(x: 100, y: 135), style: style, tolerance: 7) == nil)
    #expect(document.interaction(at: label.leaderTarget!, selected: [label.id], tool: .selection, style: style, tolerance: 7) == .resize(label.id, .leaderTarget))
    let moved = label.translated(by: CGPoint(x: 10, y: 30))
    #expect(moved.leaderTarget == label.leaderTarget && moved.start == CGPoint(x: 210, y: 130))
    let resized = AnnotationGeometry.resized(label, handle: .leaderTarget, to: CGPoint(x: -10, y: 700))
    let placed = AnnotationGeometry.placed(resized, bounds: resized.rect, imageSize: CGSize(width: 960, height: 600))
    #expect(placed.start == label.start && placed.end == label.end && placed.leaderTarget == CGPoint(x: 0, y: 600))
    let overLine = Annotation(tool: .text, start: CGPoint(x: 80, y: 100), end: CGPoint(x: 120, y: 140), text: "札")
    #expect(AnnotationDocument(annotations: [overLine, label]).hit(at: CGPoint(x: 100, y: 120), style: style, tolerance: 7) == overLine.id)
}
