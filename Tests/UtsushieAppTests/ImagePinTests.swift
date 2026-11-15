import AppKit
import Testing
import UtsushieCore
@testable import Utsushie

@MainActor private func pinImage(width: Int = 64, height: Int = 40) throws -> CGImage {
    let context = try AnnotationRenderer.bitmap(width: width, height: height)
    context.setFillColor(CGColor(red: 0.26, green: 0.44, blue: 0.75, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

@MainActor private func pinKey(_ code: UInt16, window: NSWindow? = nil) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
}

@MainActor private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<400 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("待っている状態になりませんでした")
}

@MainActor @Test func pinShowsTheImageAtThePointSizeOverTheCapturedAreaAndIsExcludedFromCapture() throws {
    let controller = ImagePinController()
    // 浮かべると前面になる。試験ではアプリを前面へ出さない。
    controller.activate = {}
    defer { controller.closeAll() }
    let screen = try #require(NSScreen.main)
    let area = CGRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 60, width: 32, height: 20)
    let pin = controller.show(try pinImage(), scale: 2, anchor: area, screen: screen)
    // 画像は撮った範囲にぴったり重なり、台紙と影の余白はその外へ足す。
    #expect(pin.imageFrame == area)
    let chrome = ImagePinGeometry.mat + ImagePinGeometry.shadowMargin
    #expect(pin.panel.frame == area.insetBy(dx: -chrome, dy: -chrome))
    #expect(pin.panel.isVisible && pin.panel.level == .floating)
    // 撮影用UIとして除外し、次の撮影やウィンドウの強調に入れない。
    #expect(CaptureWindowExclusion.windows().contains { $0 === pin.panel })
    #expect(CaptureWindowExclusion.policy(for: CaptureWindowExclusion.windows()).excludes(windowID: CGWindowID(pin.panel.windowNumber)))
    #expect(controller.pins.count == 1)
}

@MainActor @Test func pinZoomsAroundTheCursorChangesOpacityAndClosesWithEsc() throws {
    let controller = ImagePinController()
    // 浮かべると前面になる。試験ではアプリを前面へ出さない。
    controller.activate = {}
    defer { controller.closeAll() }
    let screen = try #require(NSScreen.main)
    let pin = controller.show(try pinImage(width: 200, height: 100), scale: 1, anchor: nil, screen: screen)
    let start = pin.imageFrame
    pin.zoom(by: 2, around: CGPoint(x: start.midX, y: start.midY))
    #expect(pin.imageFrame.size == CGSize(width: 400, height: 200))
    #expect(abs(pin.imageFrame.midX - start.midX) < 0.001 && abs(pin.imageFrame.midY - start.midY) < 0.001)
    // ⌘0で中心を保ったまま100%へ戻し、もう一度拡大しておく。
    let zoomedCenter = CGPoint(x: pin.imageFrame.midX, y: pin.imageFrame.midY)
    let view0 = try #require(pin.panel.contentView as? ImagePinView)
    view0.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: pin.panel.windowNumber, context: nil, characters: "0", charactersIgnoringModifiers: "0", isARepeat: false, keyCode: 29)))
    #expect(pin.imageFrame.size == CGSize(width: 200, height: 100))
    #expect(abs(pin.imageFrame.midX - zoomedCenter.x) < 0.001 && abs(pin.imageFrame.midY - zoomedCenter.y) < 0.001)
    #expect(view0.label == "100%")
    pin.changeOpacity(scrollDelta: -10, precise: false)
    #expect(abs(pin.opacity - 0.5) < 0.001)
    let view = try #require(pin.panel.contentView as? ImagePinView)
    #expect(view.label == "不透明度 50%")
    // 任意のプレビュー出力先は検証用。ホバー中の×と値のバッジを描く。
    if let directory = ProcessInfo.processInfo.environment["UTSUSHIE_UI_PREVIEW_DIR"] {
        view.mouseEntered(with: try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: pin.panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("pin.png"))
    }
    view.keyDown(with: try pinKey(53))
    #expect(pin.closed && !pin.panel.isVisible && controller.pins.isEmpty)
}

/// 任意のプレビュー出力先は検証用。押しピンを、明るい画面を撮った画像に付けて描く。
@MainActor @Test func pinLookPreviews() throws {
    guard let directory = ProcessInfo.processInfo.environment["UTSUSHIE_UI_PREVIEW_DIR"] else { return }
    let context = try AnnotationRenderer.bitmap(width: 320, height: 180)
    context.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
    context.setFillColor(CGColor(red: 0.9, green: 0.91, blue: 0.92, alpha: 1)); context.fill(CGRect(x: 0, y: 152, width: 320, height: 28))
    context.setFillColor(CGColor(red: 0.6, green: 0.64, blue: 0.69, alpha: 1))
    for (y, width) in [(116, 120), (88, 180), (60, 90)] { context.fill(CGRect(x: 18, y: y, width: width, height: 12)) }
    context.setFillColor(CGColor(red: 0.26, green: 0.44, blue: 0.75, alpha: 1)); context.fill(CGRect(x: 220, y: 18, width: 82, height: 28))
    let light = try #require(context.makeImage())
    // 暗いエディタと写真を撮った画像。浮かべた画像を、撮った範囲の同じ絵の上に重ねて見せるために使う。
    let darkContext = try AnnotationRenderer.bitmap(width: 320, height: 180)
    darkContext.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)); darkContext.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
    for (index, color) in [(0.78, 0.47, 0.87), (0.38, 0.69, 0.94), (0.6, 0.76, 0.47), (0.9, 0.75, 0.48), (0.67, 0.7, 0.75)].enumerated() {
        darkContext.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 0.85))
        darkContext.fill(CGRect(x: 16 + (index % 3) * 14, y: 150 - index * 28, width: 120 + (index * 37) % 120, height: 10))
    }
    let dark = try #require(darkContext.makeImage())
    let photoContext = try AnnotationRenderer.bitmap(width: 320, height: 180)
    let gradient = try #require(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        CGColor(red: 0.91, green: 0.7, blue: 0.44, alpha: 1), CGColor(red: 0.79, green: 0.47, blue: 0.35, alpha: 1),
        CGColor(red: 0.25, green: 0.44, blue: 0.66, alpha: 1)] as CFArray, locations: [0, 0.5, 1]))
    photoContext.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 180), end: CGPoint(x: 320, y: 0), options: [])
    let photo = try #require(photoContext.makeImage())
    let url = URL(fileURLWithPath: directory)
    // 今の橙の台紙と、比べるための前の白い台紙。
    let variants: [(String, (ImagePinView) -> Void)] = [
        ("now", { _ in }),
        ("white", { $0.paper = .white; $0.edgeColor = UITheme.ink.withAlphaComponent(0.2) }),
    ]
    for (sourceName, source) in [("light", light), ("dark", dark), ("photo", photo)] {
        try NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:])?
            .write(to: url.appendingPathComponent("source-\(sourceName).png"))
        for (name, apply) in variants {
            let controller = ImagePinController()
            // 浮かべると前面になる。試験ではアプリを前面へ出さない。
            controller.activate = {}
            defer { controller.closeAll() }
            let pin = controller.show(source, scale: 2, anchor: nil, screen: NSScreen.main)
            let view = try #require(pin.panel.contentView as? ImagePinView)
            apply(view)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("frame-\(name)-\(sourceName).png"))
        }
    }
}

@MainActor @Test func pinActivatesWhenShownAndOnClickSoPinchReachesIt() throws {
    let controller = ImagePinController()
    defer { controller.closeAll() }
    var activations = 0
    controller.activate = { activations += 1 }
    let pin = controller.show(try pinImage(width: 200, height: 100), scale: 1, anchor: nil, screen: NSScreen.main)
    // 浮かべた直後に前面にし、クリックせずにピンチを受ける。キーになるかは前面にならない試験では確かめない。
    #expect(activations == 1)
    let view = try #require(pin.panel.contentView as? ImagePinView)
    let close = view.closeRect
    #expect(view.imageRect.contains(close))
    // 台紙の上は開いた手。影の余白はカーソルを変えない。
    #expect(view.cursor(at: CGPoint(x: view.imageRect.midX, y: view.imageRect.midY)) == .openHand)
    #expect(view.cursor(at: CGPoint(x: view.matRect.minX + 2, y: view.matRect.midY)) == .openHand)
    #expect(view.cursor(at: CGPoint(x: 2, y: 2)) == nil)
    // ×を押す位置で、performDragのループに入らずに確かめる。
    view.mouseEntered(with: try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: pin.panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
    let point = CGPoint(x: close.midX, y: view.bounds.height - close.midY)
    view.mouseDown(with: try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: pin.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
    // 別のアプリへ移った後でも、クリックで前面に戻す。
    #expect(activations == 2)
    // ホバー中の×は押すボタンなので矢印。
    #expect(view.cursor(at: CGPoint(x: close.midX, y: close.midY)) == .arrow)
}

@MainActor @Test func pinWaitsForTheRecordingFilterAndClosesWhenItIsRefused() async throws {
    let controller = ImagePinController()
    // 浮かべると前面になる。試験ではアプリを前面へ出さない。
    controller.activate = {}
    defer { controller.closeAll() }
    var seen: [NSWindow] = []
    controller.beforeShowing = { window in seen.append(window); return false }
    let pin = controller.show(try pinImage(), scale: 1, anchor: nil, screen: NSScreen.main)
    #expect(!pin.panel.isVisible)
    try await waitFor { pin.closed }
    #expect(seen.first === pin.panel && controller.pins.isEmpty)
}

@MainActor @Test func cardPinsTheSavedImageWithPAndRefusesVideos() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("utsushie-pin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let image = try pinImage()
    let url = try ArtifactStore.save(data: WebPEncoder.encode(image, quality: 80, lossless: true), kind: .webP, directory: directory).url
    let thumbnails = ThumbnailController()
    thumbnails.pins.activate = {}
    defer { for card in thumbnails.cards { thumbnails.remove(card.id) }; thumbnails.pins.closeAll() }
    let screen = try #require(NSScreen.main)
    let area = CGRect(x: screen.visibleFrame.minX + 100, y: screen.visibleFrame.minY + 100, width: 32, height: 20)
    thumbnails.add(SharedArtifact(url: url, kind: .webP, width: 64, height: 40, byteCount: 1, pixelScale: 2, captureFrame: area),
        image: image, copied: false, seconds: 100, screen: screen)
    let card = try #require(thumbnails.card(for: url))
    #expect(card.handleKey(try pinKey(35)))
    try await waitFor { !thumbnails.pins.pins.isEmpty }
    #expect(thumbnails.pins.pins.first?.imageFrame == area)
    // カードを閉じても浮かべた画像は残る。
    thumbnails.remove(card.id)
    #expect(thumbnails.pins.pins.count == 1)

    let video = directory.appendingPathComponent("clip.mp4")
    try Data([0]).write(to: video)
    do { try await thumbnails.pin(video, screen: screen); Issue.record("動画を浮かべてしまいました") }
    catch { #expect(error.localizedDescription == "浮かべられるのは画像だけです") }
    thumbnails.add(SharedArtifact(url: video, kind: .mp4, width: 64, height: 40, byteCount: 1, duration: 1),
        image: nil, copied: false, seconds: 100, screen: screen)
    let videoCard = try #require(thumbnails.card(for: video))
    let p = try pinKey(35)
    #expect(!videoCard.canPin && videoCard.handleKey(p))
    try await Task.sleep(for: .milliseconds(50))
    #expect(thumbnails.pins.pins.count == 1)
}

@MainActor @Test func libraryPinsTheSelectedImageAtTheCenterOfTheScreen() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("utsushie-pin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try ArtifactStore.save(data: WebPEncoder.encode(try pinImage(), quality: 80, lossless: true), kind: .webP, directory: directory).url
    let thumbnails = ThumbnailController()
    thumbnails.pins.activate = {}
    defer { thumbnails.pins.closeAll() }
    let library = CaptureLibraryController(directory: { directory }, config: { UtsushieConfig() }, thumbnails: thumbnails, remembersFrame: false)
    defer { library.close() }
    await library.reload()
    library.select(url)
    #expect(library.handleKey(try pinKey(35)))
    try await waitFor { !thumbnails.pins.pins.isEmpty }
    let frame = try #require(thumbnails.pins.pins.first?.imageFrame)
    // 倍率の分からない保存済みファイルは1x。
    #expect(frame.size == CGSize(width: 64, height: 40))
    let visible = try #require(NSScreen.main?.visibleFrame)
    #expect(abs(frame.midX - visible.midX) < 1 && abs(frame.midY - visible.midY) < 1)
}
