import AppKit
import Testing
import UtsushieCore
@testable import Utsushie

@MainActor
private func uiBitmap(width: Int = 160, height: Int = 100, draw: () -> Void) throws -> CGImage {
    let context = try AnnotationRenderer.bitmap(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return try #require(context.makeImage())
}
private func uiPixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
    let data = try #require(image.dataProvider?.data) as Data
    let offset = (image.height - 1 - y) * image.bytesPerRow + x * 4
    return data[offset..<(offset + 4)].map(Int.init)
}

@MainActor @Test func selectionKeepsAllPixelsInsideClearAndUsesIndigoWithPaperOutside() throws {
    let rect = CGRect(x: 30, y: 20, width: 90, height: 50)
    let image = try uiBitmap { UIDrawing.selection(rect, video: false) }
    for y in 20..<70 { for x in 30..<120 {
        #expect(try uiPixel(image, x: x, y: y)[3] == 0)
    }}
    #expect(try uiPixel(image, x: 26, y: 25) == [66, 112, 192, 255])
    #expect(try uiPixel(image, x: 23, y: 30) == [243, 235, 218, 255])
    let video = try uiBitmap { UIDrawing.selection(rect, video: true) }
    #expect(try uiPixel(video, x: 26, y: 25) == [229, 53, 42, 255])
    #expect(try uiPixel(video, x: 23, y: 30) == [255, 255, 255, 255])
}

@MainActor @Test func overlayCurtainOnlyDimsOutsideSelectionIncludingAcrossScreenEdge() throws {
    let selected = CGRect(x: -20, y: 20, width: 100, height: 50)
    let image = try uiBitmap {
        NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 160, height: 100).fill()
        UIDrawing.curtain(CGRect(x: 0, y: 0, width: 160, height: 100), selection: selected)
    }
    #expect(try uiPixel(image, x: 20, y: 40) == [255, 255, 255, 255])
    let outside = try uiPixel(image, x: 120, y: 40)
    #expect(abs(outside[0] - 148) <= 1 && outside[0] == outside[1] && outside[1] == outside[2])
}

@MainActor @Test func recordingBorderIsSolidRedAndWhiteAndStaysOutside() throws {
    let rect = CGRect(x: 30, y: 20, width: 90, height: 50)
    let image = try uiBitmap { UIDrawing.recordingBorder(rect) }
    #expect(try uiPixel(image, x: 60, y: 17) == [229, 53, 42, 255])
    #expect(try uiPixel(image, x: 60, y: 15) == [255, 255, 255, 255])
    for y in 20..<70 { for x in 30..<120 {
        #expect(try uiPixel(image, x: x, y: y)[3] == 0)
    }}
}

@MainActor @Test func cardButtonsUsePresentationFramesAndEnableVideoEditing() throws {
    let artifact = SharedArtifact(url: URL(fileURLWithPath: "/tmp/test.mp4"), kind: .mp4, width: 330, height: 210, byteCount: 88_064, duration: 12)
    let card = ThumbnailCard(artifact: artifact, image: nil, copied: true, seconds: 5, finalizing: false)
    defer { card.panel.close() }
    let view = try #require(card.panel.contentView as? ThumbnailView)
    let buttons = view.subviews.compactMap { $0 as? NSButton }.sorted { $0.frame.minX < $1.frame.minX }
    #expect(buttons.count == 4)
    for (index, action) in CardAction.allCases.enumerated() {
        #expect(buttons[index].frame == CardPresentation.button(action))
        #expect(buttons[index].acceptsFirstMouse(for: nil))
    }
    #expect(buttons[0].isEnabled)
    #expect(buttons[1...3].allSatisfy { $0.isEnabled })
    // 任意のプレビュー出力先は検証用。実際のカードを表示せずに描画する。
    if let directory = ProcessInfo.processInfo.environment["UTSUSHIE_UI_PREVIEW_DIR"] {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("card.png"))
        let overlay = OverlayView(frame: CGRect(x: 0, y: 0, width: 1000, height: 350))
        let controller = OverlayController()
        overlay.controller = controller
        let mouse = NSEvent.mouseLocation
        overlay.screenFrame = CGRect(x: mouse.x - 500, y: mouse.y - 175, width: 1000, height: 350)
        let overlayBitmap = try #require(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
        overlay.cacheDisplay(in: overlay.bounds, to: overlayBitmap)
        try overlayBitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("overlay.png"))
        var videoState = CaptureState()
        _ = videoState.key(48, hasLast: false)
        let videoController = OverlayController(state: videoState)
        overlay.controller = videoController
        let videoBitmap = try #require(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
        overlay.cacheDisplay(in: overlay.bounds, to: videoBitmap)
        try videoBitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("overlay-video.png"))
        overlay.controller = controller
        controller.showError(CaptureError.unavailable("Chrome撮影にはアクセシビリティの許可が必要です。Escで閉じ、システム設定で許可してください。"))
        let errorBitmap = try #require(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
        overlay.cacheDisplay(in: overlay.bounds, to: errorBitmap)
        try errorBitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("overlay-error.png"))
    }
}
