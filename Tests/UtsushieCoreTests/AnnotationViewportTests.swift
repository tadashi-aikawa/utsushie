import Foundation
import Testing
@testable import UtsushieCore

@Test func annotationViewportZoomKeepsImagePointUnderCursor() {
    let viewport = AnnotationViewport.fit(content: CGRect(x: -100, y: -60, width: 1245, height: 800), in: CGRect(x: 0, y: 0, width: 1000, height: 700))
    let cursor = CGPoint(x: 740, y: 260)
    let imagePoint = viewport.imagePoint(at: cursor)
    for scale in [0.25, 1, 4, 16] {
        let zoomed = viewport.zoomed(to: scale, around: cursor)
        #expect(zoomed.scale == scale)
        let result = zoomed.imagePoint(at: cursor)
        #expect(abs(result.x - imagePoint.x) < 0.000001 && abs(result.y - imagePoint.y) < 0.000001)
        let display = zoomed.viewPoint(at: imagePoint)
        #expect(abs(display.x - cursor.x) < 0.000001 && abs(display.y - cursor.y) < 0.000001)
    }
}

@Test func annotationViewportFitReservesWorkbenchAndNeverUpscales() {
    let view = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let content = CGRect(x: -100, y: -60, width: 1245, height: 800)
    let fit = AnnotationViewport.fit(content: content, in: view)
    let topLeft = fit.viewPoint(at: content.origin)
    let bottomRight = fit.viewPoint(at: CGPoint(x: content.maxX, y: content.maxY))
    #expect(topLeft.x >= 120 && topLeft.y >= 120)
    #expect(view.maxX - bottomRight.x >= 120 && view.maxY - bottomRight.y >= 120)
    #expect(AnnotationViewport.fit(content: CGRect(x: 0, y: 0, width: 160, height: 100), in: view).scale == 1)
}

@Test func annotationViewportPanUsesDisplayPointsAndLimitsZoom() {
    let viewport = AnnotationViewport(scale: 4, origin: CGPoint(x: -200, y: -100))
    let moved = viewport.translated(by: CGPoint(x: 80, y: -30))
    #expect(moved.scale == 4 && moved.origin == CGPoint(x: -120, y: -130))
    #expect(viewport.zoomed(to: 100, around: .zero).scale == 16)
    #expect(viewport.zoomed(to: 0.001, around: .zero).scale == 0.01)
    #expect(viewport.zoomed(to: .infinity, around: .zero) == viewport)
    #expect(viewport.zoomed(to: -1, around: .zero) == viewport)
    #expect(viewport.percentage == "400%")
}
