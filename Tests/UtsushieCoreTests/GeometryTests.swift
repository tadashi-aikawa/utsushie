import Foundation
import CoreGraphics
import Testing
@testable import UtsushieCore

private let retina = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
private let left = DisplayGeometry(id: 2, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), scale: 1)

@Test func coordinateFlipIsReversible() {
    let cg = CGRect(x: -300, y: -200, width: 200, height: 120)
    let appKit = CaptureGeometry.flip(cg, primaryHeight: 900)
    #expect(appKit == CGRect(x: -300, y: 980, width: 200, height: 120))
    #expect(CaptureGeometry.flip(appKit, primaryHeight: 900) == cg)
}
@Test func localSourceOnOffsetDisplay() {
    let rect = CGRect(x: -300, y: 100, width: 200, height: 120)
    #expect(CaptureGeometry.localSource(rect, display: left) == CGRect(x: 1620, y: 860, width: 200, height: 120))
}
@Test func retinaOneXAndNativeDimensions() {
    let points = CGSize(width: 1280, height: 720)
    let oneX = CaptureGeometry.outputSize(points: points, scale: 2, downscale: true)
    let native = CaptureGeometry.outputSize(points: points, scale: 2, downscale: false)
    #expect(oneX.width == 1280 && oneX.height == 720)
    #expect(native.width == 2560 && native.height == 1440)
}
@Test func selectionInAllDragDirections() {
    let a = CGPoint(x: 100, y: 200), b = CGPoint(x: -200, y: 40)
    #expect(CaptureGeometry.selection(from: a, to: b) == CaptureGeometry.selection(from: b, to: a))
    #expect(CaptureGeometry.selection(from: a, to: b) == CGRect(x: -200, y: 40, width: 300, height: 160))
}
@Test func mixedDPISpanning() {
    let rect = CGRect(x: -200, y: 10, width: 400, height: 300)
    #expect(CaptureGeometry.isVisible(rect, displays: [retina, left]))
    #expect(CaptureGeometry.scale(for: rect, displays: [retina, left], downscale: true) == 1)
    #expect(CaptureGeometry.scale(for: rect, displays: [retina, left], downscale: false) == 2)
    #expect(!CaptureGeometry.isVisible(rect, displays: [retina]))
}
@Test func invalidPreviousArea() {
    #expect(!CaptureGeometry.isVisible(CGRect(x: 1430, y: 0, width: 100, height: 100), displays: [retina]))
    #expect(!CaptureGeometry.isVisible(.zero, displays: [retina]))
    #expect(!CaptureGeometry.isVisible(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 20), displays: [retina]))
    #expect(CaptureGeometry.isVisible(retina.frame, displays: [retina]))
}
@Test func previousAreaPersistence() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("last-area.json")
    let area = LastArea(rect: CGRect(x: -100, y: 20, width: 400, height: 300))
    try area.save(to: file)
    #expect(LastArea.load(from: file) == area)
    try Data("invalid".utf8).write(to: file)
    #expect(LastArea.load(from: file) == nil)
}
