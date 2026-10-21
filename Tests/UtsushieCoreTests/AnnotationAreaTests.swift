import Foundation
import Testing
@testable import UtsushieCore

private let areaImage = CGSize(width: 400, height: 300)

private func expectAreaInkInside(_ annotation: Annotation, imageSize: CGSize = areaImage, sourceLocation: SourceLocation = #_sourceLocation) {
    let style = AnnotationStyle(size: annotation.size)
    let ink = AnnotationGeometry.inkBounds(of: annotation, bounds: annotation.rect, style: style)
    #expect(ink.minX >= -0.000001 && ink.minY >= -0.000001, sourceLocation: sourceLocation)
    #expect(ink.maxX <= imageSize.width + 0.000001 && ink.maxY <= imageSize.height + 0.000001, sourceLocation: sourceLocation)
}

@Test(arguments: [AnnotationTool.rectangle, .spotlight], AnnotationSize.allCases)
func areaPlacementIncludesWholeStrokeAtEveryEdge(tool: AnnotationTool, size: AnnotationSize) {
    let style = AnnotationStyle(size: size)
    let inset = style.areaInset(for: tool)
    #expect(inset == (tool == .rectangle ? style.lineWidth / 2 + style.edge : style.lineWidth + style.edge * 2))
    for origin in [CGPoint.zero, CGPoint(x: 320, y: 0), CGPoint(x: 0, y: 240), CGPoint(x: 320, y: 240)] {
        let annotation = Annotation(tool: tool, start: origin, end: CGPoint(x: origin.x + 80, y: origin.y + 60), size: size)
        let placed = AnnotationGeometry.placed(annotation, bounds: annotation.rect, imageSize: areaImage)
        #expect(abs(placed.rect.width - annotation.rect.width) < 0.000001)
        #expect(abs(placed.rect.height - annotation.rect.height) < 0.000001)
        expectAreaInkInside(placed)
        #expect(AnnotationDocument(annotations: [placed]).exportLayout(imageSize: areaImage).bounds == CGRect(origin: .zero, size: areaImage))
    }
}

@Test(arguments: [AnnotationTool.rectangle, .spotlight], AnnotationSize.allCases)
func areaCreationClampsEndpointWithoutTranslatingAnchor(tool: AnnotationTool, size: AnnotationSize) {
    let anchor = CGPoint(x: 200, y: 150)
    let initial = Annotation(tool: tool, start: anchor, size: size)
    let area = AnnotationGeometry.areaDrawingRect(tool: tool, imageSize: areaImage, size: size)
    for point in [CGPoint(x: 410, y: 310), CGPoint(x: -10, y: -10), CGPoint(x: 410, y: -10), CGPoint(x: -10, y: 310)] {
        let created = AnnotationGeometry.creating(initial, to: point, shift: false, imageSize: areaImage)
        #expect(created.start == anchor)
        #expect(created.end.x == (point.x < anchor.x ? area.minX : area.maxX))
        #expect(created.end.y == (point.y < anchor.y ? area.minY : area.maxY))
        expectAreaInkInside(created)
        #expect(AnnotationGeometry.placed(created, bounds: created.rect, imageSize: areaImage) == created)
        let square = AnnotationGeometry.creating(initial, to: point, shift: true, imageSize: areaImage)
        #expect(square.start == anchor)
        #expect(abs(square.rect.width - square.rect.height) < 0.000001)
        expectAreaInkInside(square)
    }
}

@Test(arguments: [AnnotationTool.rectangle, .spotlight], AnnotationSize.allCases)
func areaResizeClampsDraggedPointAndKeepsOppositeCorner(tool: AnnotationTool, size: AnnotationSize) {
    let original = Annotation(tool: tool, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 200, y: 180), size: size)
    for (handle, point, fixed) in [(AnnotationResizeHandle.topLeft, CGPoint(x: -10, y: -10), original.end),
                                  (.topRight, CGPoint(x: 410, y: -10), CGPoint(x: 100, y: 180)),
                                  (.bottomRight, CGPoint(x: 410, y: 310), original.start),
                                  (.bottomLeft, CGPoint(x: -10, y: 310), CGPoint(x: 200, y: 100))] {
        for shift in [false, true] {
            let resized = AnnotationGeometry.resized(original, handle: handle, to: point, shift: shift, imageSize: areaImage)
            #expect(resized.start == fixed)
            if shift { #expect(abs(resized.rect.width - resized.rect.height) < 0.000001) }
            expectAreaInkInside(resized)
        }
    }
    for (handle, point) in [(AnnotationResizeHandle.top, CGPoint(x: 150, y: -10)), (.bottom, CGPoint(x: 150, y: 310)),
                            (.left, CGPoint(x: -10, y: 140)), (.right, CGPoint(x: 410, y: 140))] {
        let resized = AnnotationGeometry.resized(original, handle: handle, to: point, shift: false, imageSize: areaImage)
        if [.top, .bottom].contains(handle) { #expect(resized.rect.minX == 100 && resized.rect.width == 100) }
        else { #expect(resized.rect.minY == 100 && resized.rect.height == 80) }
        expectAreaInkInside(resized)
    }
}

@Test(arguments: [AnnotationTool.rectangle, .spotlight])
func areaMovementCopiesAndSizeChangeKeepFullInkInside(tool: AnnotationTool) {
    let inset = AnnotationStyle().areaInset(for: tool)
    let original = Annotation(tool: tool, start: CGPoint(x: inset, y: inset), end: CGPoint(x: areaImage.width - inset, y: areaImage.height - inset))
    var document = AnnotationDocument(annotations: [original])
    let larger = document.settingSize([original.id], size: .largest, imageSize: areaImage)
    expectAreaInkInside(larger.annotations[0])
    #expect(larger.annotations[0].rect.width < original.rect.width)
    var history = AnnotationHistory(document)
    history.commit(larger); history.undo(); #expect(history.document == document)
    for delta in [CGPoint(x: -50, y: -50), CGPoint(x: 50, y: 50)] {
        let moved = larger.moving([original.id], by: delta, imageSize: areaImage).annotations[0]
        expectAreaInkInside(moved)
        #expect(moved.rect.size == larger.annotations[0].rect.size)
    }
    var clipboard = AnnotationClipboard()
    clipboard.copy([original.id], from: larger)
    let pasted = clipboard.paste(into: &document, imageSize: areaImage)
    for annotation in document.annotations where pasted.contains(annotation.id) { expectAreaInkInside(annotation); #expect(annotation.size == .largest) }
    let copies = document.duplicate(pasted, imageSize: areaImage)
    for annotation in document.annotations where copies.contains(annotation.id) { expectAreaInkInside(annotation); #expect(annotation.size == .largest) }
}

@Test func areaOutsideRectangleKeepsMarginAndSpotAlwaysClampsStart() {
    let outside = Annotation(tool: .rectangle, start: CGPoint(x: -200, y: -100), end: CGPoint(x: -20, y: 100), size: .largest)
    #expect(AnnotationGeometry.placed(outside, bounds: outside.rect, imageSize: areaImage) == outside)
    #expect(AnnotationGeometry.creationStart(outside.start, tool: .rectangle, imageSize: areaImage) == outside.start)
    #expect(AnnotationDocument(annotations: [outside]).exportLayout(imageSize: areaImage).left > 200)
    let initial = Annotation(tool: .spotlight, start: AnnotationGeometry.creationStart(outside.start, tool: .spotlight, imageSize: areaImage, size: .largest), size: .largest)
    let created = AnnotationGeometry.creating(initial, to: CGPoint(x: 410, y: 310), shift: false, imageSize: areaImage)
    expectAreaInkInside(created)
    for tool in [AnnotationTool.rectangle, .spotlight] {
        let oversized = Annotation(tool: tool, start: CGPoint(x: -100, y: -100), end: CGPoint(x: 500, y: 400), size: .largest)
        let placed = AnnotationGeometry.placed(oversized, bounds: oversized.rect, imageSize: areaImage)
        #expect(placed.rect == AnnotationGeometry.areaDrawingRect(tool: tool, imageSize: areaImage, size: .largest))
        expectAreaInkInside(placed)
    }
}

@Test func areaConstraintLeavesMosaicAndHighlighterRulesUnchangedAndTinyRectsNonnegative() {
    for tool in [AnnotationTool.mosaic, .highlighter] {
        let annotation = Annotation(tool: tool, start: CGPoint(x: -10, y: -10), end: CGPoint(x: 100, y: 100))
        let placed = AnnotationGeometry.placed(annotation, bounds: annotation.rect, imageSize: areaImage)
        #expect(placed.rect.minX == 0 && placed.rect.minY == 0)
        #expect(AnnotationGeometry.creationStart(CGPoint(x: -10, y: -10), tool: tool, imageSize: areaImage) == CGPoint(x: -10, y: -10))
    }
    for tool in [AnnotationTool.rectangle, .spotlight] {
        let area = AnnotationGeometry.areaDrawingRect(tool: tool, imageSize: CGSize(width: 1, height: 1), size: .largest)
        #expect(area.width == 0 && area.height == 0)
    }
}
