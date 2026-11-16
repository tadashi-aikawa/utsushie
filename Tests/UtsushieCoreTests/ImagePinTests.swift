import Foundation
import CoreGraphics
import Testing
@testable import UtsushieCore

@Test func pinUsesTheCapturedPointSize() {
    #expect(ImagePinGeometry.pointSize(pixels: CGSize(width: 640, height: 400), scale: 2) == CGSize(width: 320, height: 200))
    #expect(ImagePinGeometry.pointSize(pixels: CGSize(width: 640, height: 400), scale: nil) == CGSize(width: 640, height: 400))
}

@Test func pinOverlapsTheCapturedAreaExactlyWhenSizesMatch() {
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let area = CGRect(x: 100, y: 500, width: 320, height: 200)
    #expect(ImagePinGeometry.initialFrame(size: area.size, anchor: area, visible: visible) == area)
    // 注釈の余白で大きくなった画像は、撮った範囲の中心に置く。
    let grown = ImagePinGeometry.initialFrame(size: CGSize(width: 368, height: 248), anchor: area, visible: visible)
    #expect(grown.midX == area.midX && grown.midY == area.midY)
}

@Test func pinWithoutAnAreaIsCenteredAndFitsTheScreen() {
    let visible = CGRect(x: -1000, y: 0, width: 1000, height: 600)
    let centered = ImagePinGeometry.initialFrame(size: CGSize(width: 200, height: 100), anchor: nil, visible: visible)
    #expect(centered == CGRect(x: -600, y: 250, width: 200, height: 100))
    // スクロール撮影の縦長の画像は、縦横比を保って画面の高さへ縮める。
    let tall = ImagePinGeometry.initialFrame(size: CGSize(width: 400, height: 4000), anchor: CGRect(x: -900, y: 100, width: 400, height: 400), visible: visible)
    #expect(abs(tall.height - 584) < 0.001 && abs(tall.width - 58.4) < 0.001)
    #expect(visible.insetBy(dx: 8, dy: 8).contains(tall))
}

@Test func pinNearTheEdgeIsPushedBackOnScreen() {
    let visible = CGRect(x: 0, y: 0, width: 800, height: 600)
    let frame = ImagePinGeometry.initialFrame(size: CGSize(width: 200, height: 100), anchor: CGRect(x: 750, y: 580, width: 100, height: 40), visible: visible)
    #expect(frame == CGRect(x: 592, y: 492, width: 200, height: 100))
}

@Test func pinZoomKeepsThePointUnderTheCursorAndTheAspectRatio() {
    let natural = CGSize(width: 300, height: 200)
    let frame = CGRect(x: 100, y: 100, width: 300, height: 200)
    let zoomed = ImagePinGeometry.zoomed(frame, by: 2, around: CGPoint(x: 175, y: 150), natural: natural)
    #expect(zoomed == CGRect(x: 25, y: 50, width: 600, height: 400))
    // 上限は元の8倍、下限は短辺48pt。
    #expect(ImagePinGeometry.zoomed(frame, by: 100, around: .zero, natural: natural).width == 2400)
    let small = ImagePinGeometry.zoomed(frame, by: 0.01, around: .zero, natural: natural)
    #expect(small.height == 48 && small.width == 72)
    // 元から小さい画像は元の大きさより縮めない。
    let icon = CGSize(width: 32, height: 20)
    #expect(ImagePinGeometry.zoomed(CGRect(origin: .zero, size: icon), by: 0.5, around: .zero, natural: icon).size == icon)
    #expect(ImagePinGeometry.zoomed(frame, by: .nan, around: .zero, natural: natural) == frame)
}

@Test func pinActualSizeKeepsTheCenter() {
    let frame = CGRect(x: 100, y: 100, width: 600, height: 400)
    #expect(ImagePinGeometry.actualSize(frame, natural: CGSize(width: 300, height: 200)) == CGRect(x: 250, y: 200, width: 300, height: 200))
}

@Test func pinScrollChangesZoomAndOpacityInTheScrolledDirection() {
    #expect(ImagePinGeometry.zoomFactor(scrollDelta: 10, precise: true) > 1)
    #expect(ImagePinGeometry.zoomFactor(scrollDelta: -1, precise: false) < 1)
    #expect(abs(ImagePinGeometry.opacity(1, scrollDelta: -40, precise: true) - 0.8) < 0.0001)
    #expect(ImagePinGeometry.opacity(0.3, scrollDelta: -10, precise: false) == ImagePinGeometry.minimumOpacity)
    #expect(ImagePinGeometry.opacity(0.9, scrollDelta: 10, precise: false) == 1)
}

@Test func pinPanelAddsTheMatAndShadowOutsideTheImage() {
    let image = CGRect(x: 100, y: 200, width: 320, height: 180)
    let panel = ImagePinGeometry.panelFrame(image: image)
    #expect(panel.contains(image) && panel.width - image.width == 2 * (ImagePinGeometry.mat + ImagePinGeometry.shadowMargin))
    #expect(ImagePinGeometry.imageFrame(panel: panel) == image)
    // 画面の端へ押し戻しても、台紙が切れない余白を残す。
    #expect(ImagePinGeometry.margin >= ImagePinGeometry.mat)
}

@Test func pinEntranceDrivesThePinInFromTheFrontThenLiftsAndSwellsTheImage() {
    typealias E = ImagePinEntrance
    // 出した瞬間は、ピンが手前で大きく見えず、画像は影なしで撮った範囲にぴったり重なる。
    let start = E.frame(at: 0)
    #expect(start.pinScale == E.startScale && start.pinOpacity == 0 && start.pinNear == 0)
    #expect(start.lift == 0 && start.imageScale == 1)
    // 近づく間は加速して縮み、影はまだ出さない。
    let early = E.frame(at: E.approach * 0.3), late = E.frame(at: E.approach * 0.9)
    #expect(early.pinScale > late.pinScale && late.pinScale > 1)
    let middle = E.frame(at: E.approach / 2).pinScale
    #expect(E.startScale - middle < middle - 1)
    #expect(early.lift == 0 && late.lift == 0 && late.pinOpacity == 1)
    // 刺さった瞬間に少し沈んで戻る。
    let impact = E.frame(at: E.approach + E.settle / 2)
    #expect(abs(impact.pinScale - E.impactScale) < 0.0001 && impact.pinNear == 1)
    #expect(E.frame(at: E.approach + E.settle + 0.001).pinScale == 1)
    // 刺さった瞬間から影が広がり、画像は途中で膨らんで元へ戻る。
    let lifts = stride(from: E.approach, through: E.duration, by: 0.02).map { E.frame(at: $0) }
    #expect(zip(lifts, lifts.dropFirst()).allSatisfy { $0.lift <= $1.lift })
    let peak = E.frame(at: E.approach + E.lift * 0.45)
    #expect(abs(peak.imageScale - E.swell) < 0.0001)
    #expect(lifts.allSatisfy { $0.imageScale >= 1 && $0.imageScale <= E.swell })
    // 止まったときの見た目は、演出の無い浮かべた画像と同じ。
    #expect(E.frame(at: E.duration) == .rest && E.frame(at: 10) == .rest && E.frame(at: .nan) == .rest)
    #expect(abs(E.duration - 0.6) < 0.0001)
}

@Test func pinMarginHoldsThePinWhileItComesFromTheFront() {
    // 針の先は画像の上端から3pt内側。頭は30ptの長さで30°傾き、手前では2.4倍になる。
    let head = 30 * (22 * cos(Double.pi / 6) + 4.5 * sin(Double.pi / 6)) / 22
    #expect(head * ImagePinEntrance.startScale - 3 < ImagePinGeometry.shadowMargin)
}

@Test func pinCloseButtonStaysInsideSmallPins() {
    #expect(ImagePinGeometry.closeButton(in: CGSize(width: 300, height: 200)) == CGRect(x: 270, y: 8, width: 22, height: 22))
    let small = ImagePinGeometry.closeButton(in: CGSize(width: 48, height: 30))
    #expect(CGRect(x: 0, y: 0, width: 48, height: 30).contains(small))
    #expect(ImagePinGeometry.zoomLabel(frame: CGRect(x: 0, y: 0, width: 450, height: 300), natural: CGSize(width: 300, height: 200)) == "150%")
    #expect(ImagePinGeometry.opacityLabel(0.604) == "不透明度 60%")
}
