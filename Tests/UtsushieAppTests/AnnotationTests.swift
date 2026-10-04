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
    canvas.frame = CGRect(x: 0, y: 0, width: 240, height: 180)
    canvas.mouseDown(with: try annotationMouseEvent(canvas, type: .leftMouseDown, at: CGPoint(x: 20, y: 20)))
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
    canvas.frame = CGRect(x: 0, y: 0, width: 240, height: 180)
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
    editor.canvas.frame = CGRect(x: 0, y: 0, width: 240, height: 180)
    editor.canvas.mouseDown(with: try annotationMouseEvent(editor.canvas, type: .leftMouseDown, at: CGPoint(x: 20, y: 20)))
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
    editor.canvas.frame = CGRect(x: 0, y: 0, width: 240, height: 180)
    editor.canvas.mouseDown(with: try annotationMouseEvent(editor.canvas, type: .leftMouseDown, at: CGPoint(x: 20, y: 20)))
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
            editor.canvas.frame = CGRect(x: 0, y: 0, width: 240, height: 180)
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
