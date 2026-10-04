import AppKit
import ImageIO
import Testing
import UtsushieCore
@testable import Utsushie

private func annotationFixture(width: Int = 160, height: Int = 100, patterned: Bool = false) throws -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    if patterned {
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            bytes[i] = UInt8((x * 11) % 256); bytes[i + 1] = UInt8((y * 13) % 256); bytes[i + 2] = UInt8((x + y) % 256)
        }}
    }
    let data = Data(bytes)
    let provider = try #require(CGDataProvider(data: data as CFData))
    return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}
private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
    let bytes = try #require(image.dataProvider?.data) as Data
    let i = y * image.bytesPerRow + x * 4
    return bytes[i..<(i + 4)].map(Int.init)
}
@MainActor @Test func annotationCompositionPreservesOriginalOrientation() throws {
    let original = try annotationFixture(patterned: true)
    let image = try AnnotationRenderer.compose(original, document: AnnotationDocument())
    for (x, y) in [(0, 0), (40, 10), (10, 80), (159, 99)] {
        #expect(try pixel(image, x: x, y: y) == pixel(original, x: x, y: y))
    }
}
@MainActor @Test func annotationRectangleIsRedAtTopAndHasWhiteEdges() throws {
    let rectangle = Annotation(tool: .rectangle, start: CGPoint(x: 20, y: 15), end: CGPoint(x: 120, y: 45))
    let image = try AnnotationRenderer.compose(annotationFixture(), document: AnnotationDocument(annotations: [rectangle]))
    let red = try pixel(image, x: 70, y: 15)
    #expect(abs(red[0] - 229) <= 1 && abs(red[1] - 53) <= 1 && abs(red[2] - 42) <= 1)
    #expect(try pixel(image, x: 70, y: 12) == [255, 255, 255, 255])
    #expect(try pixel(image, x: 70, y: 80) == [255, 255, 255, 255])
}
@MainActor @Test func annotationSpotlightHolesFormUnionAndDoNotDimAnnotations() throws {
    let spots = [Annotation(tool: .spotlight, start: CGPoint(x: 20, y: 10), end: CGPoint(x: 90, y: 60)),
                 Annotation(tool: .spotlight, start: CGPoint(x: 60, y: 20), end: CGPoint(x: 140, y: 70))]
    let rectangle = Annotation(tool: .rectangle, start: CGPoint(x: 30, y: 80), end: CGPoint(x: 120, y: 95))
    let image = try AnnotationRenderer.compose(annotationFixture(), document: AnnotationDocument(annotations: spots + [rectangle]))
    #expect(try pixel(image, x: 40, y: 30) == [255, 255, 255, 255])
    #expect(try pixel(image, x: 75, y: 30) == [255, 255, 255, 255])
    #expect(try pixel(image, x: 120, y: 30) == [255, 255, 255, 255])
    let outside = try pixel(image, x: 5, y: 5)
    #expect(abs(outside[0] - 127) <= 1 && outside[0] == outside[1] && outside[1] == outside[2])
    #expect(try pixel(image, x: 70, y: 80)[0...2] == [229, 53, 42])
}
@MainActor @Test func annotationMosaicUsesBlockAverageAndLeavesOutsideUntouched() throws {
    let original = try annotationFixture(patterned: true)
    let mosaic = Annotation(tool: .mosaic, start: CGPoint(x: 16, y: 8), end: CGPoint(x: 41, y: 33))
    let image = try AnnotationRenderer.compose(original, document: AnnotationDocument(annotations: [mosaic]))
    var sum = [Int](repeating: 0, count: 4)
    for y in 8..<16 { for x in 16..<24 {
        let p = try pixel(original, x: x, y: y)
        for i in 0..<4 { sum[i] += p[i] }
    }}
    let average = sum.map { ($0 + 32) / 64 }
    #expect(try pixel(image, x: 16, y: 8) == average)
    #expect(try pixel(image, x: 23, y: 15) == average)
    #expect(try pixel(image, x: 2, y: 2) == pixel(original, x: 2, y: 2))
    #expect(try pixel(image, x: 16, y: 80) == pixel(original, x: 16, y: 80))
}
@MainActor @Test func annotationArrowPointsToEndpoint() throws {
    let arrow = Annotation(tool: .arrow, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 130, y: 20))
    let image = try AnnotationRenderer.compose(annotationFixture(), document: AnnotationDocument(annotations: [arrow]))
    #expect(try pixel(image, x: 60, y: 20)[0...2] == [229, 53, 42])
    #expect(try pixel(image, x: 124, y: 20)[0...2] == [229, 53, 42])
    #expect(try pixel(image, x: 60, y: 80) == [255, 255, 255, 255])
}
@MainActor @Test func annotationTextAndNumberRemainAboveSpotlight() throws {
    let style = AnnotationStyle(imageSize: CGSize(width: 160, height: 100))
    let size = AnnotationRenderer.textSize("手順\n次へ", style: style)
    #expect(size.height > AnnotationRenderer.textSize("手順", style: style).height)
    let label = Annotation(tool: .text, start: CGPoint(x: 20, y: 10), end: CGPoint(x: 20 + size.width, y: 10 + size.height), text: "手順\n次へ")
    let number = Annotation(tool: .number, start: CGPoint(x: 130, y: 30))
    let spot = Annotation(tool: .spotlight, start: CGPoint(x: 110, y: 70), end: CGPoint(x: 150, y: 95))
    let image = try AnnotationRenderer.compose(annotationFixture(), document: AnnotationDocument(annotations: [number, label, spot]))
    #expect(try pixel(image, x: 24, y: 25)[0...2] == [210, 49, 37])
    #expect(try pixel(image, x: 123, y: 30)[0...2] == [210, 49, 37])
    var whitePixels = 0
    for y in 18..<Int(label.end.y - style.verticalPadding) { for x in 31..<Int(label.end.x - style.horizontalPadding) {
        if try pixel(image, x: x, y: y)[0...2] == [255, 255, 255] { whitePixels += 1 }
    }}
    #expect(whitePixels > 10)
}
@MainActor @Test func annotationSaveReplacesSameNameAndProducesOnlyWebPClipboardTypes() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("capture.webp")
    let original = try annotationFixture()
    let originalData = try WebPEncoder.encode(original, quality: 80, lossless: true)
    try originalData.write(to: url)
    let artifact = SharedArtifact(url: url, kind: .webP, width: 160, height: 100, byteCount: originalData.count)
    let image = try AnnotationRenderer.compose(original, document: AnnotationDocument(annotations: [Annotation(tool: .rectangle, start: CGPoint(x: 20, y: 10), end: CGPoint(x: 140, y: 80))]))
    let data = try WebPEncoder.encode(image, quality: 80, lossless: true)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let updated = try AnnotationSave.commit(data: data, artifact: artifact, mode: .both) { artifact, data, mode in
        ClipboardWriter.copy(artifact, data: data, mode: mode, to: pasteboard, preservingOnFailure: true)
    }
    #expect(updated.url == url && updated.byteCount == data.count)
    #expect(try Data(contentsOf: url) == data && data != originalData)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["capture.webp"])
    // pasteboard.typesにはOSの変換サービスによる派生形式も現れる。アプリが書いたitemを検査する。
    let item = try #require(pasteboard.pasteboardItems?.first)
    #expect(Set(item.types) == [.fileURL, .init("org.webmproject.webp")])
    #expect(pasteboard.data(forType: .init("org.webmproject.webp")) == data)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    #expect(CGImageSourceGetCount(source) == 1)
}
@MainActor @Test func annotationSaveRestoresFileWhenCopyFails() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("capture.webp")
    try Data([1, 2, 3]).write(to: url)
    let artifact = SharedArtifact(url: url, kind: .webP, width: 160, height: 100, byteCount: 3)
    #expect(throws: AnnotationSaveError.self) {
        try AnnotationSave.commit(data: Data([4, 5]), artifact: artifact, mode: .both) { _, _, _ in false }
    }
    #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["capture.webp"])
}
@MainActor @Test func annotationSaveFailureDoesNotAttemptCopy() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("missing.webp")
    let artifact = SharedArtifact(url: url, kind: .webP, width: 160, height: 100, byteCount: 0)
    var copied = false
    #expect(throws: (any Error).self) {
        try AnnotationSave.commit(data: Data([1]), artifact: artifact, mode: .both) { _, _, _ in copied = true; return true }
    }
    #expect(!copied && !FileManager.default.fileExists(atPath: url.path))
}
@MainActor @Test func annotationTextDoesNotCommitMarkedInputOrShiftNewline() {
    let input = AnnotationTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
    input.isRichText = false
    var commits = 0
    input.onCommit = { commits += 1 }
    input.setMarkedText("へんかん", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(input.hasMarkedText())
    input.insertNewline(nil)
    #expect(commits == 0)
    input.unmarkText()
    input.insertNewlineIgnoringFieldEditor(nil)
    #expect(commits == 0 && input.string.contains("\n"))
    input.insertNewline(nil)
    #expect(commits == 1)
}
@MainActor @Test func annotationToolSwitchUsesPhysicalKeysDespiteDifferentCharacters() throws {
    let canvas = AnnotationCanvas(image: try annotationFixture(), document: AnnotationDocument(), tool: .number)
    let mappings: [(UInt16, AnnotationTool)] = [(15, .rectangle), (1, .spotlight), (17, .text), (45, .number), (0, .arrow), (46, .mosaic)]
    for (keyCode, tool) in mappings {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .function, timestamp: 0,
            windowNumber: 0, context: nil, characters: "す", charactersIgnoringModifiers: "す", isARepeat: false, keyCode: keyCode))
        canvas.keyDown(with: event)
        #expect(canvas.tool == tool)
    }
}
@MainActor @Test func annotationTextSelectAllUsesPhysicalKeyWithoutSwitchingTools() throws {
    let input = AnnotationTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
    input.string = "文字を選択"
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: 0, context: nil, characters: "あ", charactersIgnoringModifiers: "あ", isARepeat: false, keyCode: 0))
    #expect(input.performKeyEquivalent(with: event))
    #expect(input.selectedRange() == NSRange(location: 0, length: input.string.utf16.count))
}
@MainActor @Test func annotationNumberHasFullOuterWhiteEdgeForCircleAndCapsule() throws {
    let original = try annotationFixture(width: 960, height: 600, patterned: true)
    let numbers = (1...12).map { number in
        Annotation(tool: .number, start: CGPoint(x: number == 1 ? 100 : 300, y: number == 1 || number == 12 ? 100 : 400))
    }
    let document = AnnotationDocument(annotations: numbers)
    let style = AnnotationStyle(imageSize: CGSize(width: 960, height: 600))
    let image = try AnnotationRenderer.compose(original, document: document)
    for number in [numbers[0], numbers[11]] {
        let rect = document.bounds(of: number, style: style)
        let outer = try pixel(image, x: Int(floor(rect.maxX + style.edge - 1)), y: 100)
        #expect(outer[0...2] == [255, 255, 255])
        let inside = try pixel(image, x: Int(floor(rect.maxX - 2)), y: 100)
        #expect(inside[0...2] == [210, 49, 37])
    }
}
@MainActor
private func annotationMouseEvent(_ canvas: AnnotationCanvas, type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
    let viewPoint = CGPoint(x: canvas.imageRect.minX + point.x * canvas.displayScale, y: canvas.imageRect.minY + point.y * canvas.displayScale)
    return try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(viewPoint, to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
}
@MainActor @Test func annotationEscapeCommitsTextThenSelectsThenClearsWithoutDiscard() throws {
    let canvas = AnnotationCanvas(image: try annotationFixture(), document: AnnotationDocument(), tool: .text)
    canvas.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: CGPoint(x: 20, y: 20)))
    canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: CGPoint(x: 20, y: 20)))
    let input = try #require(canvas.subviews.compactMap { $0 as? AnnotationTextView }.first)
    input.string = "入力"
    input.cancelOperation(nil)
    #expect(!canvas.isEditingText && canvas.tool == .text)
    #expect(canvas.document.annotations.first?.text == "入力")
    #expect(canvas.selection != nil)
    canvas.escape()
    #expect(canvas.tool == .selection && canvas.selection != nil)
    canvas.escape()
    #expect(canvas.selection == nil)
    let document = canvas.document
    canvas.escape()
    #expect(canvas.document == document && canvas.tool == .selection)
}
@MainActor @Test func annotationSelectionDoesNotCreateAndSelectedEdgeResizesWhileHoldingTool() throws {
    let area = Annotation(tool: .spotlight, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 140, y: 80))
    let canvas = AnnotationCanvas(image: try annotationFixture(), document: AnnotationDocument(annotations: [area]), tool: .selection)
    canvas.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: CGPoint(x: 5, y: 5)))
    canvas.mouseDragged(with: try annotationMouseEvent(canvas, type: .leftMouseDragged, at: CGPoint(x: 15, y: 15)))
    canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: CGPoint(x: 15, y: 15)))
    #expect(canvas.document.annotations == [area])
    canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: CGPoint(x: 60, y: 40)))
    canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: CGPoint(x: 60, y: 40)))
    #expect(canvas.selection == area.id)
    canvas.tool = .rectangle
    canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: CGPoint(x: 80, y: 20)))
    canvas.mouseDragged(with: try annotationMouseEvent(canvas, type: .leftMouseDragged, at: CGPoint(x: 100, y: 10)))
    canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: CGPoint(x: 100, y: 10)))
    #expect(canvas.document.annotations.count == 1)
    #expect(canvas.document.annotations.first?.rect == CGRect(x: 20, y: 10, width: 120, height: 70))
}

@MainActor
private func annotationKeyEvent(keyCode: UInt16, characters: String = "q", flags: NSEvent.ModifierFlags = [], repeating: Bool = false) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeating, keyCode: keyCode))
}

@MainActor @Test func annotationEditorUsesNonactivatingPanelAndInputViewsRequestKeys() throws {
    _ = NSApplication.shared
    let editor = AnnotationEditorController(image: try annotationFixture(), document: AnnotationDocument(), screen: nil)
    defer { editor.window.close() }
    #expect(editor.window.styleMask.contains(.nonactivatingPanel))
    #expect(editor.window.canBecomeKey && !editor.window.canBecomeMain)
    #expect(!editor.window.becomesKeyOnlyIfNeeded && !editor.window.hidesOnDeactivate)
    #expect(editor.window.level == .floating && editor.window.acceptsMouseMovedEvents)
    #expect(editor.canvas.needsPanelToBecomeKey && editor.canvas.acceptsFirstMouse(for: nil))
    editor.canvas.tool = .text
    editor.canvas.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    editor.canvas.mouseDown(with: try annotationMouseEvent(editor.canvas, type: .leftMouseDown, at: CGPoint(x: 20, y: 20)))
    editor.canvas.mouseUp(with: try annotationMouseEvent(editor.canvas, type: .leftMouseUp, at: CGPoint(x: 20, y: 20)))
    let input = try #require(editor.canvas.subviews.compactMap { $0 as? AnnotationTextView }.first)
    #expect(input.needsPanelToBecomeKey && input.acceptsFirstMouse(for: nil))
    #expect(editor.window.firstResponder === input)
    input.setMarkedText("へんかん", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    input.insertNewline(nil)
    #expect(editor.canvas.isEditingText)
    // IMEが確定した文字を入力クライアントへ渡す経路を再現する。
    input.insertText("変換", replacementRange: NSRange(location: NSNotFound, length: 0))
    input.unmarkText()
    input.insertNewline(nil)
    #expect(!editor.canvas.isEditingText && editor.window.firstResponder === editor.canvas)
    #expect(editor.canvas.document.annotations.first?.text.contains("変換") == true)
}

@MainActor @Test func annotationDiscardUsesUnmodifiedPhysicalQAndIgnoresRepeat() throws {
    let canvas = AnnotationCanvas(image: try annotationFixture(), document: AnnotationDocument(), tool: .rectangle)
    var discards = 0
    canvas.onDiscard = { discards += 1 }
    canvas.keyDown(with: try annotationKeyEvent(keyCode: 12, characters: "た", flags: .function))
    #expect(discards == 1)
    canvas.keyDown(with: try annotationKeyEvent(keyCode: 12, repeating: true))
    canvas.keyDown(with: try annotationKeyEvent(keyCode: 12, flags: .shift))
    #expect(discards == 1 && canvas.tool == .rectangle)
    canvas.isEnabled = false
    canvas.keyDown(with: try annotationKeyEvent(keyCode: 12))
    #expect(discards == 1)
}

@MainActor @Test func annotationQIsTextDuringInputAndCommandQIsNotDiscard() throws {
    _ = NSApplication.shared
    let editor = AnnotationEditorController(image: try annotationFixture(), document: AnnotationDocument(), screen: nil)
    defer { editor.window.close() }
    editor.canvas.tool = .text
    editor.canvas.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    editor.canvas.mouseDown(with: try annotationMouseEvent(editor.canvas, type: .leftMouseDown, at: CGPoint(x: 20, y: 20)))
    editor.canvas.mouseUp(with: try annotationMouseEvent(editor.canvas, type: .leftMouseUp, at: CGPoint(x: 20, y: 20)))
    let input = try #require(editor.canvas.subviews.compactMap { $0 as? AnnotationTextView }.first)
    var discards = 0
    editor.canvas.onDiscard = { discards += 1 }
    let event = try annotationKeyEvent(keyCode: 12)
    editor.canvas.keyDown(with: event)
    input.keyDown(with: event)
    #expect(discards == 0 && editor.canvas.isEditingText && input.string == "q")
    #expect(!editor.handleEquivalent(try annotationKeyEvent(keyCode: 12, flags: .command)))
}

@MainActor @Test func annotationQDiscardsUnchangedImmediatelyAndChangedOnSecondPress() throws {
    _ = NSApplication.shared
    for changed in [false, true] {
        let editor = AnnotationEditorController(image: try annotationFixture(), document: AnnotationDocument(), screen: nil)
        var closed = false
        editor.onClose = { closed = true }
        if changed {
            editor.canvas.tool = .number
            editor.canvas.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
            editor.canvas.mouseDown(with: try annotationMouseEvent(editor.canvas, type: .leftMouseDown, at: CGPoint(x: 20, y: 20)))
            editor.canvas.mouseUp(with: try annotationMouseEvent(editor.canvas, type: .leftMouseUp, at: CGPoint(x: 20, y: 20)))
            #expect(editor.window.performKeyEquivalent(with: try annotationKeyEvent(keyCode: 6, characters: "つ", flags: .command)))
            #expect(editor.canvas.document.annotations.isEmpty)
            #expect(editor.window.performKeyEquivalent(with: try annotationKeyEvent(keyCode: 6, characters: "つ", flags: [.command, .shift])))
            #expect(editor.canvas.document.annotations.count == 1)
        }
        let event = try annotationKeyEvent(keyCode: 12)
        editor.canvas.keyDown(with: event)
        #expect(closed == !changed)
        if changed {
            editor.canvas.keyDown(with: try annotationKeyEvent(keyCode: 12, repeating: true))
            #expect(!closed)
            editor.canvas.keyDown(with: event)
            #expect(closed)
        }
    }
}

@MainActor @Test func annotationSpotFrameStaysOutsideUnionIncludingNestedAndTouchingHoles() throws {
    let original = try annotationFixture(width: 960, height: 600, patterned: true)
    let first = Annotation(tool: .spotlight, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 300, y: 260))
    let overlap = Annotation(tool: .spotlight, start: CGPoint(x: 240, y: 160), end: CGPoint(x: 440, y: 320))
    let nested = Annotation(tool: .spotlight, start: CGPoint(x: 140, y: 140), end: CGPoint(x: 200, y: 200))
    let touching = Annotation(tool: .spotlight, start: CGPoint(x: 440, y: 200), end: CGPoint(x: 500, y: 280))
    let image = try AnnotationRenderer.compose(original, document: AnnotationDocument(annotations: [first, overlap, nested, touching]))
    for (x, y) in [(180, 96), (444, 300), (270, 324)] {
        #expect(try pixel(image, x: x, y: y)[0...2] == [229, 53, 42])
    }
    for (x, y) in [(180, 98), (180, 93)] {
        #expect(try pixel(image, x: x, y: y)[0...2] == [255, 255, 255])
    }
    for (x, y) in [(180, 100), (240, 200), (300, 200), (170, 140), (200, 170), (440, 240)] {
        #expect(try pixel(image, x: x, y: y) == pixel(original, x: x, y: y))
    }
}

@MainActor @Test func annotationMarginsHavePaperBoundaryAndOriginalOrientationWithoutCurtain() throws {
    let original = try annotationFixture(width: 960, height: 600, patterned: true)
    let labels = [
        Annotation(tool: .text, start: CGPoint(x: 984, y: 100), end: CGPoint(x: 1219, y: 134)),
        Annotation(tool: .text, start: CGPoint(x: -100, y: -100), end: CGPoint(x: -20, y: -60)),
        Annotation(tool: .text, start: CGPoint(x: 300, y: 620), end: CGPoint(x: 380, y: 660))
    ]
    let spot = Annotation(tool: .spotlight, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 300, y: 260))
    let document = AnnotationDocument(annotations: labels + [spot])
    let layout = document.exportLayout(imageSize: CGSize(width: 960, height: 600))
    let image = try AnnotationRenderer.compose(original, document: document)
    #expect(image.width == 1371 && image.height == 812)
    for (x, y) in [(970, 20), (-10, 20), (20, -10), (20, 610)] {
        #expect(try pixel(image, x: x + layout.left, y: y + layout.top) == [243, 235, 218, 255])
    }
    for (x, y) in [(960, 20), (-1, 20), (20, -1), (20, 600)] {
        let seam = try pixel(image, x: x + layout.left, y: y + layout.top)
        #expect(abs(seam[0] - 209) <= 1 && abs(seam[1] - 202) <= 1 && abs(seam[2] - 187) <= 1)
    }
    #expect(try pixel(image, x: 150 + layout.left, y: 120 + layout.top) == pixel(original, x: 150, y: 120))
    let outside = try pixel(image, x: 30 + layout.left, y: 480 + layout.top)
    let base = try pixel(original, x: 30, y: 480)
    for channel in 0..<3 { #expect(abs(outside[channel] - base[channel] / 2) <= 1) }
}

@MainActor @Test func annotationMosaicKeepsPixelAveragesWhenExportOriginShifts() throws {
    let original = try annotationFixture(patterned: true)
    let mosaic = Annotation(tool: .mosaic, start: CGPoint(x: 16, y: 8), end: CGPoint(x: 41, y: 33))
    let label = Annotation(tool: .text, start: CGPoint(x: -90, y: -60), end: CGPoint(x: -20, y: -20))
    let plain = try AnnotationRenderer.compose(original, document: AnnotationDocument(annotations: [mosaic]))
    let doc = AnnotationDocument(annotations: [label, mosaic])
    let layout = doc.exportLayout(imageSize: CGSize(width: 160, height: 100))
    let expanded = try AnnotationRenderer.compose(original, document: doc)
    for (x, y) in [(16, 8), (23, 15), (2, 2), (16, 80), (159, 99)] {
        #expect(try pixel(expanded, x: x + layout.left, y: y + layout.top) == pixel(plain, x: x, y: y))
    }
}

@MainActor @Test func annotationSpotAtImageEdgeUsesExistingMarginWithoutGrowingOne() throws {
    let original = try annotationFixture(width: 960, height: 600)
    let spot = Annotation(tool: .spotlight, start: CGPoint(x: 800, y: 100), end: CGPoint(x: 960, y: 200))
    let spotOnly = try AnnotationRenderer.compose(original, document: AnnotationDocument(annotations: [spot]))
    #expect(spotOnly.width == 960 && spotOnly.height == 600)
    let label = Annotation(tool: .text, start: CGPoint(x: 1000, y: 300), end: CGPoint(x: 1100, y: 340))
    let expanded = try AnnotationRenderer.compose(original, document: AnnotationDocument(annotations: [spot, label]))
    #expect(try pixel(expanded, x: 963, y: 150)[0...2] == [229, 53, 42])
    #expect(try pixel(expanded, x: 968, y: 150) == [243, 235, 218, 255])
    #expect(try pixel(expanded, x: 959, y: 150) == [255, 255, 255, 255])
}

@MainActor @Test func annotationLeaderHasDotThinLineOuterWhiteEdgeAndCorrectLayer() throws {
    let original = try annotationFixture(width: 960, height: 600, patterned: true)
    let label = Annotation(tool: .text, start: CGPoint(x: 300, y: 100), end: CGPoint(x: 440, y: 140), leaderTarget: CGPoint(x: 100, y: 120))
    let arrow = Annotation(tool: .arrow, start: CGPoint(x: 200, y: 70), end: CGPoint(x: 200, y: 170))
    let otherLabel = Annotation(tool: .text, start: CGPoint(x: 240, y: 100), end: CGPoint(x: 280, y: 140))
    let image = try AnnotationRenderer.compose(original, document: AnnotationDocument(annotations: [label, arrow, otherLabel]))
    for (x, y) in [(100, 120), (100, 123), (160, 120), (200, 120)] {
        #expect(try pixel(image, x: x, y: y)[0...2] == [229, 53, 42])
    }
    #expect(try pixel(image, x: 100, y: 125)[0...2] == [255, 255, 255])
    #expect(try pixel(image, x: 160, y: 122)[0...2] == [255, 255, 255])
    #expect(try pixel(image, x: 160, y: 124) == pixel(original, x: 160, y: 124))
    #expect(try pixel(image, x: 250, y: 120)[0...2] == [210, 49, 37])
    #expect(try pixel(image, x: 310, y: 120)[0...2] == [210, 49, 37])
    let hidden = Annotation(tool: .text, start: label.start, end: label.end, leaderTarget: CGPoint(x: 320, y: 120))
    let hiddenImage = try AnnotationRenderer.compose(original, document: AnnotationDocument(annotations: [hidden]))
    #expect(try pixel(hiddenImage, x: 160, y: 120) == pixel(original, x: 160, y: 120))
}

@MainActor @Test func annotationTextWhiteEdgeIsOutsideRedFace() throws {
    let label = Annotation(tool: .text, start: CGPoint(x: 50, y: 40), end: CGPoint(x: 130, y: 80))
    let image = try AnnotationRenderer.compose(annotationFixture(patterned: true), document: AnnotationDocument(annotations: [label]))
    for (x, y) in [(80, 38), (48, 60), (131, 60), (80, 81)] {
        #expect(try pixel(image, x: x, y: y)[0...2] == [255, 255, 255])
    }
    #expect(try pixel(image, x: 80, y: 40)[0...2] == [210, 49, 37])
}

@MainActor @Test func annotationExpandedSaveUpdatesDimensionsAndWebPThenShrinksFromOriginal() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let original = try annotationFixture()
    let url = dir.appendingPathComponent("capture.webp")
    try WebPEncoder.encode(original, quality: 80, lossless: true).write(to: url)
    let artifact = SharedArtifact(url: url, kind: .webP, width: 160, height: 100, byteCount: 0)
    let label = Annotation(tool: .text, start: CGPoint(x: 180, y: 20), end: CGPoint(x: 260, y: 60))
    let image = try AnnotationRenderer.compose(original, document: AnnotationDocument(annotations: [label]))
    let data = try WebPEncoder.encode(image, quality: 80, lossless: true)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let updated = try AnnotationSave.commit(data: data, artifact: artifact, mode: .both, imageSize: CGSize(width: image.width, height: image.height)) { item, data, mode in
        #expect(item.width == image.width && item.height == image.height)
        return ClipboardWriter.copy(item, data: data, mode: mode, to: board)
    }
    #expect(updated.width == 266 && updated.height == 100 && updated.url == artifact.url)
    let copied = try #require(board.data(forType: .init("org.webmproject.webp")))
    let source = try #require(CGImageSourceCreateWithData(copied as CFData, nil))
    let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(decoded.width == 266 && decoded.height == 100)
    let shrink = try AnnotationRenderer.compose(original, document: AnnotationDocument())
    let shrinkData = try WebPEncoder.encode(shrink, quality: 80, lossless: true)
    let restored = try AnnotationSave.commit(data: shrinkData, artifact: updated, mode: .both, imageSize: CGSize(width: shrink.width, height: shrink.height)) { _, _, _ in true }
    #expect(restored.width == 160 && restored.height == 100)
}

@MainActor @Test func annotationTextDragCreatesLeaderAndClickThresholdDoesNot() throws {
    for distance in [4.0, 5.0, 200.0] {
        let canvas = AnnotationCanvas(image: try annotationFixture(), document: AnnotationDocument(), tool: .text)
        canvas.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        let start = CGPoint(x: 80, y: 50), end = CGPoint(x: 80 + distance, y: 50)
        canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: start))
        #expect(!canvas.isEditingText)
        canvas.mouseDragged(with: try annotationMouseEvent(canvas, type: .leftMouseDragged, at: end))
        canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: end))
        #expect(canvas.isEditingText)
        let input = try #require(canvas.subviews.compactMap { $0 as? AnnotationTextView }.first)
        input.string = "説明"; canvas.commitText()
        let label = try #require(canvas.document.annotations.first)
        #expect(label.leaderTarget == (distance > 4 ? start : nil))
        if distance == 200 { #expect(abs(label.rect.midX - end.x) < 0.0001) }
        #expect(canvas.document.annotations.count == 1)
        canvas.undoAnnotation()
        #expect(canvas.document.annotations.isEmpty && canvas.exportLayout.right == 0)
        canvas.redoAnnotation()
        #expect(canvas.document.annotations.first == label)
    }
}

@MainActor @Test func annotationCanvasFreezesTransformDuringDragAndFitsExportWithWorkbenchOnRelease() throws {
    let label = Annotation(tool: .text, start: CGPoint(x: 60, y: 30), end: CGPoint(x: 100, y: 70), text: "説明", leaderTarget: CGPoint(x: 20, y: 50))
    let canvas = AnnotationCanvas(image: try annotationFixture(), document: AnnotationDocument(annotations: [label]), tool: .selection)
    canvas.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
    let initialRect = canvas.imageRect
    canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: CGPoint(x: 80, y: 50)))
    canvas.mouseDragged(with: try annotationMouseEvent(canvas, type: .leftMouseDragged, at: CGPoint(x: 320, y: 50)))
    #expect(canvas.imageRect == initialRect && canvas.displayScale == 1)
    #expect(canvas.exportLayout.right > 0 && canvas.document.annotations.first?.leaderTarget == label.leaderTarget)
    canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: CGPoint(x: 320, y: 50)))
    #expect(canvas.displayScale < 1)
    let export = canvas.exportLayout.bounds, image = canvas.imageRect, scale = canvas.displayScale
    #expect(image.minX + export.minX * scale >= 120 - 0.001)
    #expect(canvas.bounds.maxX - (image.minX + export.maxX * scale) >= 120 - 0.001)
    #expect(image.minY + export.minY * scale >= 120 - 0.001)
    #expect(canvas.bounds.maxY - (image.minY + export.maxY * scale) >= 120 - 0.001)
    canvas.undoAnnotation()
    #expect(canvas.imageRect == initialRect && canvas.exportLayout.right == 0)
}

@MainActor @Test func annotationLeaderHandleClampsTargetAndDeleteRemovesLabelAndLine() throws {
    let label = Annotation(tool: .text, start: CGPoint(x: 80, y: 30), end: CGPoint(x: 130, y: 70), leaderTarget: CGPoint(x: 20, y: 50))
    let canvas = AnnotationCanvas(image: try annotationFixture(), document: AnnotationDocument(annotations: [label]), tool: .selection)
    canvas.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: CGPoint(x: 100, y: 50)))
    canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: CGPoint(x: 100, y: 50)))
    canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: CGPoint(x: 20, y: 50)))
    canvas.mouseDragged(with: try annotationMouseEvent(canvas, type: .leftMouseDragged, at: CGPoint(x: -20, y: 130)))
    canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: CGPoint(x: -20, y: 130)))
    let adjusted = try #require(canvas.document.annotations.first)
    #expect(adjusted.leaderTarget == CGPoint(x: 0, y: 100) && adjusted.rect == label.rect)
    canvas.deleteBackward(nil)
    #expect(canvas.document.annotations.isEmpty)
    canvas.undoAnnotation()
    #expect(canvas.document.annotations.first == adjusted)
}

@MainActor @Test func annotationUndoDuringDragCancelsPreviewAndRestoresFittedTransform() throws {
    let canvas = AnnotationCanvas(image: try annotationFixture(), document: AnnotationDocument(), tool: .number)
    canvas.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: CGPoint(x: 80, y: 50)))
    canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: CGPoint(x: 80, y: 50)))
    canvas.tool = .selection
    canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: CGPoint(x: 80, y: 50)))
    canvas.mouseDragged(with: try annotationMouseEvent(canvas, type: .leftMouseDragged, at: CGPoint(x: 320, y: 50)))
    #expect(canvas.exportLayout.right > 0)
    canvas.undoAnnotation()
    canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: CGPoint(x: 320, y: 50)))
    #expect(canvas.document.annotations.isEmpty && canvas.exportLayout.right == 0)
    canvas.redoAnnotation()
    #expect(canvas.document.annotations.first?.start == CGPoint(x: 80, y: 50))
}

@MainActor @Test func annotationArrowCreateResizeAndMoveKeepOutsideEndpointDespiteInsideCenter() throws {
    let canvas = AnnotationCanvas(image: try annotationFixture(), document: AnnotationDocument(), tool: .arrow)
    canvas.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    let start = CGPoint(x: 20, y: 50), end = CGPoint(x: 180, y: 50)
    canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: start))
    canvas.mouseDragged(with: try annotationMouseEvent(canvas, type: .leftMouseDragged, at: end))
    canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: end))
    let created = try #require(canvas.document.annotations.first)
    #expect(created.start == start && created.end == end && canvas.exportLayout.right > 20)
    canvas.escape(); canvas.escape() // 選択モードへ戻し、選択も外す。
    #expect(canvas.selection == nil)
    canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: end))
    canvas.mouseDragged(with: try annotationMouseEvent(canvas, type: .leftMouseDragged, at: CGPoint(x: 200, y: 50)))
    canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: CGPoint(x: 200, y: 50)))
    #expect(canvas.document.annotations.first?.start == start && canvas.document.annotations.first?.end == CGPoint(x: 200, y: 50))
    canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: CGPoint(x: 100, y: 50)))
    canvas.mouseDragged(with: try annotationMouseEvent(canvas, type: .leftMouseDragged, at: CGPoint(x: 110, y: 60)))
    canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: CGPoint(x: 110, y: 60)))
    #expect(canvas.document.annotations.first?.start == CGPoint(x: 30, y: 60))
    #expect(canvas.document.annotations.first?.end == CGPoint(x: 210, y: 60))
    canvas.undoAnnotation(); canvas.undoAnnotation(); canvas.undoAnnotation()
    #expect(canvas.document.annotations.isEmpty && canvas.exportLayout.right == 0)
}

@MainActor @Test func annotationNumberClickAndDragThresholdAreDisplayPointsAtEveryZoom() throws {
    for scale in [0.5, 2.0, 4.0] {
        for distance in [4.0, 5.0] {
            let canvas = AnnotationCanvas(image: try annotationFixture(), document: AnnotationDocument(), tool: .number)
            canvas.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
            canvas.zoom(to: scale, around: CGPoint(x: 320, y: 240))
            let start = CGPoint(x: 80, y: 50), end = CGPoint(x: 80 + distance / scale, y: 50)
            canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: start))
            canvas.mouseDragged(with: try annotationMouseEvent(canvas, type: .leftMouseDragged, at: end))
            #expect(canvas.displayScale == scale)
            canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: end))
            let number = try #require(canvas.document.annotations.first)
            #expect(number.start == (distance > 4 ? end : start))
            #expect(number.leaderTarget == (distance > 4 ? start : nil))
            #expect(!canvas.isEditingText && canvas.document.nextNumber == 2)
            canvas.undoAnnotation(); #expect(canvas.document.annotations.isEmpty)
            canvas.redoAnnotation(); #expect(canvas.document.annotations.first == number)
        }
    }
}

@MainActor @Test func annotationUnselectedNumberTargetCanResizeAndBadgeMovesIndependently() throws {
    let number = Annotation(tool: .number, start: CGPoint(x: 120, y: 50), leaderTarget: CGPoint(x: 20, y: 50))
    let canvas = AnnotationCanvas(image: try annotationFixture(), document: AnnotationDocument(annotations: [number]), tool: .rectangle)
    canvas.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    #expect(canvas.selection == nil)
    canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: number.leaderTarget!))
    canvas.mouseDragged(with: try annotationMouseEvent(canvas, type: .leftMouseDragged, at: CGPoint(x: -30, y: 150)))
    canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: CGPoint(x: -30, y: 150)))
    #expect(canvas.document.annotations.first?.leaderTarget == CGPoint(x: 0, y: 100))
    #expect(canvas.document.annotations.first?.start == number.start)
    canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: number.start))
    canvas.mouseDragged(with: try annotationMouseEvent(canvas, type: .leftMouseDragged, at: CGPoint(x: 200, y: 50)))
    canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: CGPoint(x: 200, y: 50)))
    #expect(canvas.document.annotations.first?.start == CGPoint(x: 200, y: 50))
    #expect(canvas.document.annotations.first?.leaderTarget == CGPoint(x: 0, y: 100))
    canvas.deleteBackward(nil); #expect(canvas.document.annotations.isEmpty)
    canvas.undoAnnotation(); #expect(canvas.document.annotations.first?.leaderTarget == CGPoint(x: 0, y: 100))
}

@MainActor @Test func annotationNumberLeaderRendersBelowAllBadgesAndAboveArrows() throws {
    let original = try annotationFixture(width: 960, height: 600, patterned: true)
    let number = Annotation(tool: .number, start: CGPoint(x: 400, y: 120), leaderTarget: CGPoint(x: 100, y: 120))
    let label = Annotation(tool: .text, start: CGPoint(x: 240, y: 100), end: CGPoint(x: 280, y: 140))
    let arrow = Annotation(tool: .arrow, start: CGPoint(x: 200, y: 70), end: CGPoint(x: 200, y: 170))
    let image = try AnnotationRenderer.compose(original, document: AnnotationDocument(annotations: [label, number, arrow]))
    for (x, y) in [(100, 120), (100, 123), (150, 120), (200, 120)] {
        #expect(try pixel(image, x: x, y: y)[0...2] == [229, 53, 42])
    }
    #expect(try pixel(image, x: 150, y: 122)[0...2] == [255, 255, 255])
    #expect(try pixel(image, x: 250, y: 120)[0...2] == [210, 49, 37])
    #expect(try pixel(image, x: 389, y: 120)[0...2] == [210, 49, 37])
}

@MainActor @Test func annotationUnselectedAreaEdgeResizesWithoutMovingAndInteriorMovesOnlyInSelection() throws {
    for tool in [AnnotationTool.rectangle, .spotlight, .mosaic] {
        let area = Annotation(tool: tool, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 140, y: 80))
        let canvas = AnnotationCanvas(image: try annotationFixture(), document: AnnotationDocument(annotations: [area]), tool: .text)
        canvas.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        canvas.zoom(to: 2, around: CGPoint(x: 320, y: 240))
        canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: CGPoint(x: 80, y: 20)))
        canvas.mouseDragged(with: try annotationMouseEvent(canvas, type: .leftMouseDragged, at: CGPoint(x: 100, y: 10)))
        canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: CGPoint(x: 100, y: 10)))
        let resized = try #require(canvas.document.annotations.first)
        #expect(resized.id == area.id && resized.rect == CGRect(x: 20, y: 10, width: 120, height: 70))
        #expect(!canvas.isEditingText && canvas.selection == area.id)
        canvas.tool = .selection
        canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: CGPoint(x: 80, y: 40)))
        canvas.mouseDragged(with: try annotationMouseEvent(canvas, type: .leftMouseDragged, at: CGPoint(x: 90, y: 45)))
        canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: CGPoint(x: 90, y: 45)))
        #expect(canvas.document.annotations.first?.rect == CGRect(x: 30, y: 15, width: 120, height: 70))
        #expect(canvas.displayScale == 2)
    }
}

@MainActor @Test func annotationZoomKeysUpdateToolbarAndPreserveDocumentAndExport() throws {
    _ = NSApplication.shared
    let arrow = Annotation(tool: .arrow, start: CGPoint(x: 20, y: 50), end: CGPoint(x: 180, y: 50))
    let doc = AnnotationDocument(annotations: [arrow])
    let editor = AnnotationEditorController(image: try annotationFixture(), document: doc, screen: nil)
    defer { editor.window.close() }
    editor.canvas.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    editor.canvas.layout()
    let fit = editor.canvas.imageRect, output = editor.canvas.exportLayout
    let initialImage = try AnnotationRenderer.compose(editor.canvas.original, document: doc)
    #expect(editor.handleEquivalent(try annotationKeyEvent(keyCode: 24, characters: "=", flags: [.command, .shift])))
    #expect(editor.canvas.displayScale == 1.25 && editor.zoomLabel.stringValue == "125%")
    #expect(editor.handleEquivalent(try annotationKeyEvent(keyCode: 27, characters: "-", flags: .command)))
    #expect(editor.canvas.displayScale == 1)
    editor.canvas.pan(by: CGPoint(x: -120, y: 40))
    #expect(editor.handleEquivalent(try annotationKeyEvent(keyCode: 29, characters: "0", flags: .command)))
    #expect(editor.canvas.imageRect == fit)
    editor.canvas.zoom(to: 4, around: CGPoint(x: 260, y: 160))
    #expect(editor.handleEquivalent(try annotationKeyEvent(keyCode: 18, characters: "1", flags: .command)))
    #expect(editor.canvas.displayScale == 1 && editor.zoomLabel.stringValue == "100%")
    #expect(editor.canvas.document == doc && editor.canvas.exportLayout == output)
    #expect(!editor.canvas.history.canUndo)
    let after = try AnnotationRenderer.compose(editor.canvas.original, document: editor.canvas.document)
    #expect(after.width == initialImage.width && after.height == initialImage.height)
    #expect(try pixel(after, x: 30, y: 50) == pixel(initialImage, x: 30, y: 50))
}

@MainActor
private func annotationViewMouseEvent(_ canvas: AnnotationCanvas, type: NSEvent.EventType, at viewPoint: CGPoint) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(viewPoint, to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
}

@MainActor @Test func annotationSpaceDragPansInDisplayPointsAndSpaceTypesDuringTextInput() throws {
    let number = Annotation(tool: .number, start: CGPoint(x: 80, y: 50))
    let doc = AnnotationDocument(annotations: [number])
    let canvas = AnnotationCanvas(image: try annotationFixture(), document: doc, tool: .rectangle)
    canvas.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    canvas.zoom(to: 2, around: CGPoint(x: 320, y: 240))
    let initial = canvas.imageRect
    canvas.keyDown(with: try annotationKeyEvent(keyCode: 49, characters: " "))
    canvas.mouseDown(with: try annotationViewMouseEvent(canvas, type: .leftMouseDown, at: CGPoint(x: 100, y: 120)))
    canvas.mouseDragged(with: try annotationViewMouseEvent(canvas, type: .leftMouseDragged, at: CGPoint(x: 180, y: 150)))
    canvas.mouseUp(with: try annotationViewMouseEvent(canvas, type: .leftMouseUp, at: CGPoint(x: 180, y: 150)))
    let keyUp = try #require(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
    canvas.keyUp(with: keyUp)
    #expect(canvas.imageRect.origin == CGPoint(x: initial.minX + 80, y: initial.minY + 30))
    #expect(canvas.displayScale == 2 && canvas.document == doc && !canvas.history.canUndo)
    canvas.tool = .text
    canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: CGPoint(x: 20, y: 20)))
    canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: CGPoint(x: 20, y: 20)))
    let input = try #require(canvas.subviews.compactMap { $0 as? AnnotationTextView }.first)
    input.insertText("前", replacementRange: NSRange(location: NSNotFound, length: 0))
    input.keyDown(with: try annotationKeyEvent(keyCode: 49, characters: " "))
    #expect(input.string == "前 " && canvas.isEditingText)
    canvas.commitText()
    #expect(canvas.document.annotations.last?.text == "前 ")
}

private final class AnnotationNavigationEvent: NSEvent {
    var eventWindow: NSWindow?
    var eventWindowNumber = 0
    var eventKind: NSEvent.EventType = .magnify
    var eventLocation: CGPoint = .zero
    var eventFlags: NSEvent.ModifierFlags = []
    var amount: CGFloat = 0
    var scrollX: CGFloat = 0
    var scrollY: CGFloat = 0
    var precise = true
    var eventPhase: NSEvent.Phase = []
    var eventMomentum: NSEvent.Phase = []
    override var type: NSEvent.EventType { eventKind }
    override var window: NSWindow? { eventWindow }
    override var windowNumber: Int { eventWindowNumber }
    override var locationInWindow: NSPoint { eventLocation }
    override var modifierFlags: NSEvent.ModifierFlags { eventFlags }
    override var magnification: CGFloat { amount }
    override var scrollingDeltaX: CGFloat { scrollX }
    override var scrollingDeltaY: CGFloat { scrollY }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var phase: NSEvent.Phase { eventPhase }
    override var momentumPhase: NSEvent.Phase { eventMomentum }
}

private final class AnnotationRunningApplication: NSRunningApplication, @unchecked Sendable {
    let identifier: pid_t
    var mockTerminated = false
    init(identifier: pid_t) { self.identifier = identifier; super.init() }
    override var processIdentifier: pid_t { identifier }
    override var isTerminated: Bool { mockTerminated }
    override var bundleIdentifier: String? { identifier == ProcessInfo.processInfo.processIdentifier ? "com.tadashi-aikawa.utsushie" : "com.test.previous" }
}

@MainActor @Test func annotationActivationUsesFrontmostPIDEvenWhenIsActiveDisagrees() throws {
    _ = NSApplication.shared
    let previous = AnnotationRunningApplication(identifier: -2)
    let current = AnnotationRunningApplication(identifier: ProcessInfo.processInfo.processIdentifier)
    var front: NSRunningApplication? = previous
    var active = false
    var requests = 0
    var restores = 0
    let focus = AnnotationApplicationFocus(isActive: { active }, frontmostApplication: { front },
        activate: { requests += 1 }, restore: { _ in restores += 1 })
    let editor = AnnotationEditorController(image: try annotationFixture(), document: AnnotationDocument(), screen: nil, applicationFocus: focus)
    defer { editor.window.close() }
    editor.show()
    #expect(requests == 1 && editor.window.isVisible)
    #expect(editor.window.firstResponder === editor.canvas)
    // 開いた後にisActiveだけがtrueになっても、前面が別アプリなら再要求する。
    active = true
    let root = try #require(editor.window.contentView)
    root.layoutSubtreeIfNeeded()
    // ツールバーの空き領域でもユーザー操作による要求を出す。
    let mouse = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: root.convert(CGPoint(x: 5, y: 20), to: nil),
        modifierFlags: [], timestamp: 0, windowNumber: editor.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    editor.window.sendEvent(mouse)
    #expect(requests == 2)
    let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0))
    let scroll = try #require(NSEvent(cgEvent: wheel))
    editor.window.sendEvent(scroll)
    #expect(requests == 3)
    editor.window.sendEvent(mouse)
    #expect(requests == 4)
    // 逆のずれでも、前面が自分なら追加の要求は出さない。
    front = current; active = false
    editor.window.sendEvent(scroll)
    editor.window.sendEvent(mouse)
    #expect(requests == 4)
    front = previous; active = true
    editor.window.sendEvent(scroll)
    #expect(requests == 5)
    // 前面アプリが取得できない場合も自分が前面とは扱わない。
    front = nil
    editor.window.sendEvent(mouse)
    #expect(requests == 6)
    front = previous
    editor.window.close()
    #expect(restores == 0)
}

@MainActor @Test func annotationCloseRestoresOpeningApplicationOnlyWhileFrontmost() throws {
    _ = NSApplication.shared
    for (activeAtClose, frontmostAtClose, terminated, isSelf) in [
        (true, true, false, false), (false, true, false, false),
        (true, false, false, false), (false, false, false, false),
        (true, true, true, false), (true, true, false, true)
    ] {
        let previous = AnnotationRunningApplication(identifier: isSelf ? ProcessInfo.processInfo.processIdentifier : -2)
        let other = AnnotationRunningApplication(identifier: -3)
        let current = AnnotationRunningApplication(identifier: ProcessInfo.processInfo.processIdentifier)
        var front: NSRunningApplication = previous
        var active = false
        var restored: NSRunningApplication?
        var closed = false
        let focus = AnnotationApplicationFocus(isActive: { active }, frontmostApplication: { front },
            activate: {}, restore: { restored = $0 })
        let editor = AnnotationEditorController(image: try annotationFixture(), document: AnnotationDocument(), screen: nil, applicationFocus: focus)
        editor.onClose = { closed = true }
        editor.show()
        // 編集中に前面アプリが変わっても、復帰先は開く直前のアプリを保つ。
        front = frontmostAtClose ? current : other; active = activeAtClose; previous.mockTerminated = terminated
        editor.window.close()
        #expect(closed)
        if frontmostAtClose && !terminated && !isSelf { #expect(restored === previous) }
        else { #expect(restored == nil) }
    }
}

@MainActor @Test func annotationApplicationMagnifyDiagnosticPreservesEventAndDoesNotZoom() throws {
    _ = NSApplication.shared
    let editor = AnnotationEditorController(image: try annotationFixture(), document: AnnotationDocument(), screen: nil)
    defer { editor.window.close() }
    editor.window.contentView?.layoutSubtreeIfNeeded()
    let event = AnnotationNavigationEvent()
    event.eventWindow = editor.window; event.eventWindowNumber = editor.window.windowNumber
    event.eventLocation = editor.canvas.convert(CGPoint(x: editor.canvas.bounds.midX, y: editor.canvas.bounds.midY), to: nil)
    event.amount = 0.25
    let before = editor.canvas.displayScale
    let observed = AnnotationNavigationDiagnostics.observeMagnify(event)
    #expect(observed === event && editor.canvas.displayScale == before)
    editor.window.sendEvent(observed)
    #expect(editor.canvas.displayScale == before + 0.25)
    event.eventWindow = nil; event.eventWindowNumber = 0
    #expect(AnnotationNavigationDiagnostics.observeMagnify(event) === event)
}

@MainActor @Test func annotationPanelDeliversPinchToCanvasAndTextInput() throws {
    _ = NSApplication.shared
    // 合成イベントでパネル以降の配送を検証する。OSからの実ピンチ到達は受入試験で確かめる。
    let wasActive = NSApp.isActive
    let editor = AnnotationEditorController(image: try annotationFixture(), document: AnnotationDocument(), screen: nil)
    defer { editor.window.close() }
    let root = try #require(editor.window.contentView)
    root.layoutSubtreeIfNeeded()
    let canvas = editor.canvas
    let cursor = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
    let event = AnnotationNavigationEvent()
    event.eventWindow = editor.window
    event.eventWindowNumber = editor.window.windowNumber
    event.eventLocation = canvas.convert(cursor, to: nil)
    event.eventPhase = .began; event.amount = 0.25
    #expect(root.hitTest(root.superview!.convert(event.eventLocation, from: nil)) === canvas)
    let imagePoint = CGPoint(x: (cursor.x - canvas.imageRect.minX) / canvas.displayScale,
                             y: (cursor.y - canvas.imageRect.minY) / canvas.displayScale)
    editor.window.sendEvent(event)
    #expect(canvas.displayScale == 1.25)
    #expect(NSApp.isActive == wasActive)
    #expect(abs(canvas.imageRect.minX + imagePoint.x * canvas.displayScale - cursor.x) < 0.0001)
    #expect(abs(canvas.imageRect.minY + imagePoint.y * canvas.displayScale - cursor.y) < 0.0001)
    canvas.tool = .text
    let click = try annotationMouseEvent(canvas, type: .leftMouseDown, at: CGPoint(x: 80, y: 50))
    canvas.mouseDown(with: click)
    canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: CGPoint(x: 80, y: 50)))
    let input = try #require(canvas.subviews.compactMap { $0 as? AnnotationTextView }.first)
    event.eventLocation = input.convert(CGPoint(x: input.bounds.midX, y: input.bounds.midY), to: nil)
    #expect(root.hitTest(root.superview!.convert(event.eventLocation, from: nil)) === input)
    editor.window.sendEvent(event)
    #expect(canvas.displayScale == 1.5)
    #expect(canvas.isEditingText && !canvas.history.canUndo)
    #expect(editor.window.firstResponder === input)
    event.eventLocation = root.convert(CGPoint(x: 5, y: 20), to: nil)
    editor.window.sendEvent(event)
    #expect(canvas.displayScale == 1.5)
    event.eventLocation = canvas.convert(cursor, to: nil)
    canvas.isEnabled = false
    editor.window.sendEvent(event)
    #expect(canvas.displayScale == 1.5)
}

@MainActor @Test func annotationCanvasClipsZoomedImageAndTextBelowToolbar() throws {
    _ = NSApplication.shared
    let editor = AnnotationEditorController(image: try annotationFixture(), document: AnnotationDocument(), screen: nil)
    defer { editor.window.close() }
    let root = try #require(editor.window.contentView)
    root.layoutSubtreeIfNeeded()
    let canvas = editor.canvas
    #expect(canvas.clipsToBounds)
    #expect(root.subviews.first === canvas)
    let bar = try #require(root.subviews.last as? NSStackView)
    let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
    root.cacheDisplay(in: root.bounds, to: bitmap)
    let scaleX = CGFloat(bitmap.pixelsWide) / root.bounds.width
    let scaleY = CGFloat(bitmap.pixelsHigh) / root.bounds.height
    let x = Int(5 * scaleX), y = Int(20 * scaleY)
    let toolbarBefore = try #require(bitmap.colorAt(x: x, y: y))
    canvas.zoom(to: 16, around: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
    canvas.pan(by: CGPoint(x: -canvas.imageRect.minX, y: -100 - canvas.imageRect.minY))
    #expect(canvas.imageRect.minY < 0)
    root.cacheDisplay(in: root.bounds, to: bitmap)
    #expect(bitmap.colorAt(x: x, y: y) == toolbarBefore)
    let imageColor = try #require(bitmap.colorAt(x: x, y: Int(72 * scaleY))?.usingColorSpace(.sRGB))
    #expect(imageColor.redComponent > 0.99 && imageColor.greenComponent > 0.99 && imageColor.blueComponent > 0.99)
    canvas.tool = .text
    canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: CGPoint(x: 80, y: 50)))
    canvas.mouseUp(with: try annotationMouseEvent(canvas, type: .leftMouseUp, at: CGPoint(x: 80, y: 50)))
    let input = try #require(canvas.subviews.compactMap { $0 as? AnnotationTextView }.first)
    root.cacheDisplay(in: root.bounds, to: bitmap)
    let textToolbarX = Int(60 * scaleX), textToolbarY = Int(14 * scaleY)
    let textToolbarBefore = try #require(bitmap.colorAt(x: textToolbarX, y: textToolbarY))
    canvas.pan(by: CGPoint(x: 50 - input.frame.minX, y: -40 - input.frame.minY))
    #expect(input.frame.minY < 0)
    root.cacheDisplay(in: root.bounds, to: bitmap)
    #expect(bitmap.colorAt(x: textToolbarX, y: textToolbarY) == textToolbarBefore)
    let outside = root.superview!.convert(canvas.convert(CGPoint(x: 60, y: -30), to: nil), from: nil)
    #expect(root.hitTest(outside) !== input)
    #expect(bar.frame.maxY == canvas.frame.minY)
}

@MainActor @Test func annotationPinchAndCommandScrollKeepCursorAnchorAndOrdinaryScrollPans() throws {
    let canvas = AnnotationCanvas(image: try annotationFixture(), document: AnnotationDocument(), tool: .text)
    canvas.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    let cursor = CGPoint(x: 380, y: 230)
    let initial = canvas.imageRect
    let point = CGPoint(x: (cursor.x - initial.minX) / canvas.displayScale, y: (cursor.y - initial.minY) / canvas.displayScale)
    let event = AnnotationNavigationEvent()
    event.eventLocation = canvas.convert(cursor, to: nil); event.amount = 0.5
    canvas.magnify(with: event)
    #expect(canvas.displayScale == 1.5)
    #expect(abs(canvas.imageRect.minX + point.x * canvas.displayScale - cursor.x) < 0.0001)
    #expect(abs(canvas.imageRect.minY + point.y * canvas.displayScale - cursor.y) < 0.0001)
    event.eventKind = .scrollWheel; event.eventFlags = .command; event.scrollY = 10; event.eventPhase = .began
    canvas.scrollWheel(with: event)
    #expect(canvas.displayScale > 1.5)
    #expect(abs(canvas.imageRect.minX + point.x * canvas.displayScale - cursor.x) < 0.0001)
    #expect(abs(canvas.imageRect.minY + point.y * canvas.displayScale - cursor.y) < 0.0001)
    let zoomed = canvas.imageRect
    event.eventFlags = []; event.eventPhase = []; event.eventMomentum = .changed
    canvas.scrollWheel(with: event)
    #expect(canvas.imageRect == zoomed)
    event.eventMomentum = []; event.eventPhase = .began; event.scrollX = 30; event.scrollY = -20
    canvas.scrollWheel(with: event)
    #expect(canvas.imageRect.origin == CGPoint(x: zoomed.minX + 30, y: zoomed.minY - 20))
    #expect(canvas.imageRect.size == zoomed.size && !canvas.history.canUndo)
}
