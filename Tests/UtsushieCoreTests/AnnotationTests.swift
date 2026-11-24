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
@Test func annotationStyleIsFixedPerCapturePoint() {
    let style = AnnotationStyle()
    #expect(style.fontSize == 18)
    #expect(style.lineWidth == 3)
    #expect(style.edge == 2 && style.radius == 6)
    #expect(style.horizontalPadding == 11 && style.verticalPadding == 6)
    #expect(style.numberDiameter == 27)
    #expect(style.blockSize == 15 && style.marginPadding == 24 && style.leaderDotDiameter == 9 && style.pasteOffset == 18)
    // Rで2xにした画像は中の文字も2倍の画素なので、同じ見た目になるよう倍にする。
    let retina = AnnotationStyle(scale: 2)
    #expect(retina.fontSize == 36 && retina.lineWidth == 6 && retina.blockSize == 30 && retina.marginPadding == 48)
    #expect(AnnotationDocument(scale: 2).style() == retina)
    #expect(style.numberRect(at: .zero, number: 12).width > style.numberRect(at: .zero, number: 1).width)
}
@Test func annotationHitUsesFixedLayersAndArrowSegment() {
    let rect = Annotation(tool: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 100, y: 100))
    let number = Annotation(tool: .number, start: CGPoint(x: 50, y: 50))
    let mosaic = Annotation(tool: .mosaic, start: .zero, end: CGPoint(x: 200, y: 200))
    let arrow = Annotation(tool: .arrow, start: .zero, end: CGPoint(x: 100, y: 100))
    let doc = AnnotationDocument(annotations: [number, rect, arrow, mosaic])
    let style = AnnotationStyle()
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
    let style = AnnotationStyle()
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
    let style = AnnotationStyle()
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
        // 選択ツールと同じ種類のツールだけ縁で変形し、別の種類のツールではその上へ置く。
        let reshapes = mode == .selection || mode == areaTool
        for (point, handle, cursor) in locations {
            for selected: Set<UUID> in [[area.id], []] {
                let action = document.interaction(at: point, selected: selected, tool: mode, style: style, tolerance: 7)
                #expect(action == (reshapes ? .resize(area.id, handle) : .create))
                #expect(action.cursor(tool: mode) == (reshapes ? cursor : AnnotationInteraction.create.cursor(tool: mode)))
            }
        }
        let interior = document.interaction(at: CGPoint(x: 100, y: 80), selected: [area.id], tool: mode, style: style, tolerance: 7)
        #expect(interior == (mode == .selection ? .move(area.id) : .create))
        let empty = document.interaction(at: CGPoint(x: 250, y: 200), selected: [area.id], tool: mode, style: style, tolerance: 7)
        #expect(empty == (mode == .selection ? .none : .create))
        #expect(empty.cursor(tool: mode) == (mode == .selection ? .arrow : mode.usesSampleCursor ? .sample : .crosshair))
    }
}
@Test func onlyFreehandHighlighterAndNumberUseSampleCursor() {
    let sampled = AnnotationTool.allCases.filter(\.usesSampleCursor)
    #expect(sampled == [.number, .freehand, .highlighter])
    for tool in AnnotationTool.allCases {
        let expected: AnnotationCursor = tool == .selection ? .arrow : sampled.contains(tool) ? .sample : .crosshair
        #expect(AnnotationInteraction.create.cursor(tool: tool) == expected)
        // 端点や辺をつかむときは、見本ではなく変形のカーソルを出す。
        #expect(AnnotationInteraction.resize(UUID(), .arrowEnd).cursor(tool: tool) == .crosshair)
        #expect(AnnotationInteraction.resize(UUID(), .left).cursor(tool: tool) == .horizontal)
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
@Test func annotationCreationToolsPreferCreationOverMovingAndKeepSameKindEndpointHandles() {
    let arrow = Annotation(tool: .arrow, start: CGPoint(x: 20, y: 30), end: CGPoint(x: 120, y: 30))
    let label = Annotation(tool: .text, start: CGPoint(x: 20, y: 60), end: CGPoint(x: 120, y: 100), text: "ラベル")
    let number = Annotation(tool: .number, start: CGPoint(x: 160, y: 100))
    let line = Annotation(tool: .line, start: CGPoint(x: 20, y: 180), end: CGPoint(x: 120, y: 180))
    let pen = Annotation(tool: .highlighter, start: CGPoint(x: 20, y: 240), end: CGPoint(x: 120, y: 240))
    let document = AnnotationDocument(annotations: [arrow, label, number, line, pen])
    let style = AnnotationStyle()
    for mode in AnnotationTool.allCases {
        for (point, id) in [(CGPoint(x: 70, y: 30), arrow.id), (CGPoint(x: 70, y: 80), label.id), (CGPoint(x: 160, y: 100), number.id),
                            (CGPoint(x: 70, y: 180), line.id), (CGPoint(x: 70, y: 240), pen.id)] {
            for selected: Set<UUID> in [[], [id]] {
                let action = document.interaction(at: point, selected: selected, tool: mode, style: style, tolerance: 7)
                #expect(action == (mode == .selection ? .move(id) : .create))
                #expect(action.cursor(tool: mode) == (mode == .selection ? .move : mode.usesSampleCursor ? .sample : .crosshair))
            }
        }
        // 端点を変えるのは選択ツールと同じ種類のツールだけ。番号ツールなら矢印の端へ番号を置く。
        let arrowEnds = mode == .selection || mode == .arrow
        let lineEnds = mode == .selection || mode == .line
        #expect(document.interaction(at: arrow.start, selected: [arrow.id], tool: mode, style: style, tolerance: 7) == (arrowEnds ? .resize(arrow.id, .arrowStart) : .create))
        #expect(document.interaction(at: arrow.start, selected: [], tool: mode, style: style, tolerance: 7) == (arrowEnds ? .resize(arrow.id, .arrowStart) : .create))
        #expect(document.interaction(at: arrow.end, selected: [], tool: mode, style: style, tolerance: 7) == (arrowEnds ? .resize(arrow.id, .arrowEnd) : .create))
        let end = document.interaction(at: arrow.end, selected: [arrow.id], tool: mode, style: style, tolerance: 7)
        #expect(end == (arrowEnds ? .resize(arrow.id, .arrowEnd) : .create))
        #expect(end.cursor(tool: mode) == (arrowEnds ? .crosshair : AnnotationInteraction.create.cursor(tool: mode)))
        #expect(document.interaction(at: line.start, selected: [], tool: mode, style: style, tolerance: 7) == (lineEnds ? .resize(line.id, .arrowStart) : .create))
        #expect(document.interaction(at: line.end, selected: [], tool: mode, style: style, tolerance: 7) == (lineEnds ? .resize(line.id, .arrowEnd) : .create))
    }
}
@Test func annotationCreationToolReshapesSameKindEvenUnderAnotherKind() {
    // 枠の上辺に番号が重なっていても、枠ツールなら枠の縁を直せる。選択ツールは手前の番号をつかむ。
    let area = Annotation(tool: .rectangle, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 180, y: 140))
    let number = Annotation(tool: .number, start: CGPoint(x: 100, y: 20))
    let document = AnnotationDocument(annotations: [area, number])
    let style = AnnotationStyle()
    let edge = CGPoint(x: 100, y: 20)
    #expect(document.hit(at: edge, style: style, tolerance: 7) == number.id)
    #expect(document.interaction(at: edge, selected: [], tool: .rectangle, style: style, tolerance: 7) == .resize(area.id, .top))
    #expect(document.interaction(at: edge, selected: [], tool: .selection, style: style, tolerance: 7) == .move(number.id))
    #expect(document.interaction(at: edge, selected: [], tool: .arrow, style: style, tolerance: 7) == .create)
    // 同じ種類の中では、手前の文字のラベルが下の文字の指す点を覆っていればラベルを優先し、再編集できるよう作成に回す。
    let below = Annotation(tool: .text, start: CGPoint(x: 300, y: 100), end: CGPoint(x: 360, y: 130), text: "下", leaderTarget: CGPoint(x: 250, y: 220))
    let above = Annotation(tool: .text, start: CGPoint(x: 220, y: 200), end: CGPoint(x: 300, y: 240), text: "上")
    let labels = AnnotationDocument(annotations: [below, above])
    #expect(labels.hit(at: CGPoint(x: 250, y: 220), style: style, tolerance: 7, kind: .text) == above.id)
    #expect(labels.interaction(at: CGPoint(x: 250, y: 220), selected: [], tool: .text, style: style, tolerance: 7) == .create)
}
@Test func annotationOptionGrabsSameKindLabelOnlyInLabelTools() {
    let number = Annotation(tool: .number, start: CGPoint(x: 200, y: 50), leaderTarget: CGPoint(x: 40, y: 50))
    let text = Annotation(tool: .text, start: CGPoint(x: 100, y: 150), end: CGPoint(x: 180, y: 190), text: "説明")
    let document = AnnotationDocument(annotations: [number, text])
    let style = AnnotationStyle()
    let badge = number.start, line = CGPoint(x: 120, y: 50), label = CGPoint(x: 140, y: 170)
    func action(_ point: CGPoint, _ tool: AnnotationTool, _ option: Bool) -> AnnotationInteraction {
        document.interaction(at: point, selected: [], tool: tool, style: style, tolerance: 7, grabsLabel: option)
    }
    // ⌥を押した同じ種類のラベルだけ、指す点を残して動かす。
    #expect(action(badge, .number, true) == .move(number.id, leader: false))
    #expect(action(badge, .number, true).cursor(tool: .number) == .move)
    #expect(action(label, .text, true) == .move(text.id, leader: false))
    // 修飾なしは、ラベルの中からでも新しく引き出し線を引く。
    #expect(action(badge, .number, false) == .create)
    #expect(action(label, .text, false) == .create)
    // 引き出し線の上と、別の種類のラベルは⌥でも置く。
    #expect(action(line, .number, true) == .create)
    #expect(action(label, .number, true) == .create)
    #expect(action(badge, .text, true) == .create)
    #expect(action(badge, .rectangle, true) == .create)
    // 円の番号の外接矩形の角は、円の外なのでつかまない。斜めの引き出し線が通る所。
    let rect = document.bounds(of: number, style: style)
    let corner = CGPoint(x: rect.maxX - 1, y: rect.minY + 1)
    #expect(document.grabbedLabel(at: corner, tool: .number, style: style) == nil)
    #expect(action(corner, .number, true) == .create)
    // 手前の番号の下に隠れた文字は、文字のツールでもつかまない。
    let cover = Annotation(tool: .number, start: label)
    let covered = AnnotationDocument(annotations: [text, cover])
    #expect(covered.grabbedLabel(at: label, tool: .text, style: style) == nil)
    #expect(covered.grabbedLabel(at: label, tool: .number, style: style) == cover.id)
    // 複数選択中でも、⌥は押したラベルをつかむ。
    #expect(document.interaction(at: badge, selected: [number.id, text.id], tool: .number, style: style, tolerance: 7, grabsLabel: true) == .move(number.id, leader: false))
}
@Test func annotationCreationToolKeepsSpotInnerWidthAtHighZoom() {
    // 4倍表示でスポットの左の線から内側へ入った位置は、同じ種類のツールでも従来どおり新しく描く。外側の縁では変形する。
    let spot = Annotation(tool: .spotlight, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 300, y: 300))
    let document = AnnotationDocument(annotations: [spot])
    let style = AnnotationStyle()
    #expect(document.interaction(at: CGPoint(x: 105, y: 200), selected: [], tool: .spotlight, style: style, tolerance: 7 / 4) == .create)
    #expect(document.interaction(at: CGPoint(x: 95, y: 200), selected: [], tool: .spotlight, style: style, tolerance: 7 / 4) == .resize(spot.id, .left))
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
    #expect(AnnotationDocument(annotations: document.annotations.reversed()).exportLayout(imageSize: size) == layout)
}

@Test(arguments: AnnotationTool.allCases)
func annotationPlacementUsesCenterAndToolRestriction(_ tool: AnnotationTool) {
    let size = CGSize(width: 960, height: 600)
    let style = AnnotationStyle()
    let document = AnnotationDocument()
    let outside = Annotation(tool: tool, start: CGPoint(x: -100, y: 200), end: CGPoint(x: -20, y: 280))
    let bounds = document.bounds(of: outside, style: style)
    let placed = AnnotationGeometry.placed(outside, bounds: bounds, imageSize: size)
    let inset = style.areaInset(for: tool)
    #expect(placed == (tool.allowsMargin ? outside : outside.translated(by: CGPoint(x: -bounds.minX + inset, y: 0))))
    if !tool.allowsMargin { #expect(AnnotationDocument(annotations: [outside]).exportLayout(imageSize: size).bounds.size == size) }
    let crossing = Annotation(tool: tool, start: CGPoint(x: -10, y: 200), end: CGPoint(x: 70, y: 280))
    let crossingBounds = document.bounds(of: crossing, style: style)
    let inImage = AnnotationGeometry.placed(crossing, bounds: crossingBounds, imageSize: size)
    if [.arrow, .line, .freehand].contains(tool) { #expect(inImage == crossing) }
    else if AnnotationGeometry.containsCenter(of: crossingBounds, in: CGRect(origin: .zero, size: size)) {
        #expect(abs(document.bounds(of: inImage, style: style).minX - inset) < 0.000001)
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
    #expect(placed.rect == AnnotationGeometry.areaDrawingRect(tool: tool, imageSize: size))
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
    let style = AnnotationStyle()
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
        let reshapes = tool == .selection || tool == .number
        #expect(document.interaction(at: last.leaderTarget!, selected: [], tool: tool, style: style, tolerance: 7) == (reshapes ? .resize(last.id, .leaderTarget) : .create))
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
    let style = AnnotationStyle()
    for tool in [AnnotationTool.selection, .spotlight] {
        let action = document.interaction(at: CGPoint(x: 95, y: 200), selected: [], tool: tool, style: style, tolerance: 7 / 4)
        #expect(action == .resize(spot.id, .left))
        #expect(action.cursor(tool: tool) == .horizontal)
    }
}

@Test func annotationCornerAndEndpointHandlesKeepSevenPointToleranceWhenZoomed() {
    let rect = Annotation(tool: .rectangle, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 300, y: 300))
    let arrow = Annotation(tool: .arrow, start: CGPoint(x: 100, y: 50), end: CGPoint(x: 300, y: 50))
    let label = Annotation(tool: .number, start: CGPoint(x: 300, y: 200), leaderTarget: CGPoint(x: 100, y: 200))
    let style = AnnotationStyle()
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
    let style = AnnotationStyle()
    #expect(document.hit(at: CGPoint(x: 100, y: 122), style: style, tolerance: 7) == label.id)
    #expect(document.hit(at: CGPoint(x: 100, y: 135), style: style, tolerance: 7) == nil)
    for tool in AnnotationTool.allCases {
        let reshapes = tool == .selection || tool == .text
        for selected: Set<UUID> in [[], [label.id]] {
            #expect(document.interaction(at: label.leaderTarget!, selected: selected, tool: tool, style: style, tolerance: 7) == (reshapes ? .resize(label.id, .leaderTarget) : .create))
        }
    }
    let moved = label.translated(by: CGPoint(x: 10, y: 30))
    #expect(moved.leaderTarget == label.leaderTarget && moved.start == CGPoint(x: 210, y: 130))
    let resized = AnnotationGeometry.resized(label, handle: .leaderTarget, to: CGPoint(x: -10, y: 700))
    let placed = AnnotationGeometry.placed(resized, bounds: resized.rect, imageSize: CGSize(width: 960, height: 600))
    #expect(placed.start == label.start && placed.end == label.end && placed.leaderTarget == CGPoint(x: 0, y: 600))
    let overLine = Annotation(tool: .text, start: CGPoint(x: 80, y: 100), end: CGPoint(x: 120, y: 140), text: "札")
    #expect(AnnotationDocument(annotations: [overLine, label]).hit(at: CGPoint(x: 100, y: 120), style: style, tolerance: 7) == overLine.id)
}

@Test func annotationLeaderLineDragMovesLabelWithTarget() throws {
    let image = CGSize(width: 960, height: 600)
    let label = Annotation(tool: .text, start: CGPoint(x: 200, y: 100), end: CGPoint(x: 300, y: 140), text: "説明", leaderTarget: CGPoint(x: 20, y: 120))
    let document = AnnotationDocument(annotations: [label])
    let style = AnnotationStyle()
    let line = CGPoint(x: 100, y: 120), body = CGPoint(x: 250, y: 120)
    for selected: Set<UUID> in [[], [label.id]] {
        #expect(document.interaction(at: line, selected: selected, tool: .selection, style: style, tolerance: 7) == .move(label.id, leader: true))
        #expect(document.interaction(at: body, selected: selected, tool: .selection, style: style, tolerance: 7) == .move(label.id, leader: false))
    }
    #expect(document.interaction(at: line, selected: [], tool: .text, style: style, tolerance: 7) == .create)
    let delta = CGPoint(x: 30, y: 40)
    let whole = document.moving([label.id], by: delta, imageSize: image, grabbedLeader: true).annotations[0]
    #expect(whole.start == CGPoint(x: 230, y: 140) && whole.leaderTarget == CGPoint(x: 50, y: 160))
    let labelOnly = document.moving([label.id], by: delta, imageSize: image).annotations[0]
    #expect(labelOnly.start == CGPoint(x: 230, y: 140) && labelOnly.leaderTarget == label.leaderTarget)
    // 指す点が画像の端に着いたら、ラベルも同じ所で止めて形を保つ。
    let edge = document.moving([label.id], by: CGPoint(x: -50, y: 0), imageSize: image, grabbedLeader: true).annotations[0]
    #expect(edge.leaderTarget == CGPoint(x: 0, y: 120) && edge.start == CGPoint(x: 180, y: 100))
    // 余白のラベルが画像へ押し戻されても、指す点はラベルと同じ量だけ動く。
    let small = CGSize(width: 400, height: 300)
    let outside = Annotation(tool: .text, start: CGPoint(x: -100, y: 100), end: CGPoint(x: -20, y: 140), text: "外", leaderTarget: CGPoint(x: 100, y: 120))
    let mosaic = Annotation(tool: .mosaic, start: CGPoint(x: 200, y: 200), end: CGPoint(x: 240, y: 240))
    let margin = AnnotationDocument(annotations: [outside, mosaic])
    for (ids, grabbed) in [([outside.id], true), ([outside.id, mosaic.id], false)] as [(Set<UUID>, Bool)] {
        let back = margin.moving(ids, by: CGPoint(x: 60, y: 0), imageSize: small, grabbedLeader: grabbed).annotations[0]
        #expect(back.start == CGPoint(x: 0, y: 100) && back.leaderTarget == CGPoint(x: 200, y: 120))
    }
    // 押し戻すと指す点が画像から出る形は、ラベルを余白に残したまま手前で止める。
    var far = outside; far.leaderTarget = CGPoint(x: 330, y: 120)
    let farDocument = AnnotationDocument(annotations: [far, mosaic])
    for (ids, grabbed) in [([far.id], true), ([far.id, mosaic.id], false)] as [(Set<UUID>, Bool)] {
        let stopped = farDocument.moving(ids, by: CGPoint(x: 60, y: 0), imageSize: small, grabbedLeader: grabbed).annotations[0]
        let target = try #require(stopped.leaderTarget)
        #expect(stopped.start.x < -39.9 && stopped.start.x > -40.1)
        #expect(abs((target.x - stopped.start.x) - 430) < 1e-6 && target.y == 120)
    }
    // 縮めた移動でも、今見えている蛍光ペンを画像から消さない。
    let near = Annotation(tool: .text, start: CGPoint(x: -120, y: 100), end: CGPoint(x: -40, y: 140), text: "外", leaderTarget: CGPoint(x: 300, y: 120))
    let pen = Annotation(tool: .highlighter, start: CGPoint(x: 350, y: 100),
                         points: [CGPoint(x: 350, y: 100), CGPoint(x: 350, y: 1000), CGPoint(x: -100, y: 1000), CGPoint(x: -100, y: 100)])
    let withPen = AnnotationDocument(annotations: [near, pen])
    let penMoved = withPen.moving([near.id, pen.id], by: CGPoint(x: 100, y: 0), imageSize: small)
    let nearMoved = penMoved.annotations[0], nearTarget = try #require(penMoved.annotations[0].leaderTarget)
    #expect(AnnotationGeometry.highlighterShows(penMoved.annotations[1], in: CGRect(origin: .zero, size: small), style: penMoved.style()))
    #expect(abs((nearTarget.x - nearMoved.start.x) - 420) < 1e-6)
    // ラベルの中心が縁を跨ぐと収まる倍率が飛び飛びになる。後半の収まる区間まで探す。
    let a = Annotation(tool: .text, start: CGPoint(x: 100, y: -184), end: CGPoint(x: 180, y: -104), text: "A", leaderTarget: CGPoint(x: 200, y: 120))
    let b = Annotation(tool: .text, start: CGPoint(x: 350, y: -120), end: CGPoint(x: 430, y: -40), text: "B", leaderTarget: CGPoint(x: 10, y: 50))
    let gapped = AnnotationDocument(annotations: [a, b]).moving([a.id, b.id], by: CGPoint(x: 20, y: 180), imageSize: small)
    for (original, moved) in zip([a, b], gapped.annotations) {
        let target = try #require(moved.leaderTarget), before = try #require(original.leaderTarget)
        #expect(abs((target.x - moved.start.x) - (before.x - original.start.x)) < 1e-6)
        #expect(abs((target.y - moved.start.y) - (before.y - original.start.y)) < 1e-6)
    }
    #expect(gapped.annotations[1].leaderTarget!.y - 50 > 180 * 0.7)
}
