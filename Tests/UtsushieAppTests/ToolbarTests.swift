import AppKit
import Testing
import UtsushieCore
@testable import Utsushie

@MainActor private func toolbarImage() throws -> CGImage {
    let context = try AnnotationRenderer.bitmap(width: 960, height: 600)
    return try #require(context.makeImage())
}
@MainActor private func toolbarKey(_ code: UInt16) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
}
@MainActor private func toolbarMouse(_ canvas: AnnotationCanvas, type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
    let location = canvas.convert(CGPoint(x: canvas.imageRect.minX + point.x * canvas.displayScale,
                                         y: canvas.imageRect.minY + point.y * canvas.displayScale), to: nil)
    return try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
        windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
}

@MainActor private func toolbarBitmap(width: Int, height: Int, draw: () -> Void) throws -> CGImage {
    let context = try AnnotationRenderer.bitmap(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    UITheme.ink.setFill(); CGRect(x: 0, y: 0, width: width, height: height).fill()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return try #require(context.makeImage())
}

private func brightToolbarColumns(_ image: CGImage) throws -> [Int] {
    let bytes = try #require(image.dataProvider?.data) as Data
    return (0..<image.width).filter { x in
        (0..<image.height).contains { y in
            let offset = y * image.bytesPerRow + x * 4
            return bytes[offset] > 190 && bytes[offset + 1] > 190 && bytes[offset + 2] > 190
        }
    }
}

@MainActor @Test func toolbarKeyGlyphsHavePaddingOnBothSides() throws {
    for key in ["Tab", "W", "C", "Esc", "R", "S", "A", "T", "N", "M", "H", "Q", "⏎", "⇧⏎", "⌘↩"] {
        let rect = CGRect(x: 8, y: 8, width: ToolbarDrawing.keyWidth(key), height: 17)
        #expect(rect.width >= ToolbarDrawing.width(key, size: 10.5) + 8)
        for strong in [false, true] {
            let bitmap = try toolbarBitmap(width: Int(ceil(rect.maxX + 8)), height: 33) {
                ToolbarDrawing.key(key, in: rect, strong: strong)
            }
            let columns = try brightToolbarColumns(bitmap)
            let first = try #require(columns.first), last = try #require(columns.last)
            #expect(CGFloat(first) - rect.minX >= 3)
            #expect(rect.maxX - CGFloat(last + 1) >= 3)
            #expect(abs(CGFloat(first + last + 1) / 2 - rect.midX) <= 2)
        }
    }
}

@MainActor @Test func fixedAIButtonCentersNormalAndSearchingContent() throws {
    let button = AnnotationToolbarView().aiButton
    let width = button.naturalWidth
    for (title, key) in [("AIで隠す", "H"), ("探しています", "Esc")] {
        button.title = title; button.key = key
        #expect(button.naturalWidth == width)
        let image = try toolbarBitmap(width: Int(ceil(width)), height: 28) {
            ToolbarDrawing.item(title: title, key: key, in: CGRect(x: 0, y: 0, width: width, height: 28), style: .outline, centered: true)
        }
        let columns = try brightToolbarColumns(image)
        let first = try #require(columns.first), last = try #require(columns.last)
        #expect(abs(CGFloat(first + last + 1) / 2 - width / 2) <= 3)
    }
}

@MainActor @Test func toolbarVideoIndicatorIsRedAndOnlyDrawnWhenSelected() throws {
    for output in [CaptureOutput.image, .video] {
        let item = try #require(OverlayPresentation.items(output: output, target: .area, hasLast: false).first { $0.title == "動画" })
        let image = try toolbarBitmap(width: 80, height: 28) {
            ToolbarDrawing.item(title: item.title, key: nil, in: CGRect(x: 0, y: 0, width: 80, height: 28), selected: item.selected, recording: item.recording)
        }
        let bytes = try #require(image.dataProvider?.data) as Data
        let offset = 14 * image.bytesPerRow + 10 * 4
        let dot = Array(bytes[offset..<(offset + 4)])
        if output == .video { #expect(dot == [229, 53, 42, 255]) }
        else { #expect(dot[0] == dot[1]) }
    }
}

@MainActor @Test func annotationToolbarGroupsFitAtMinimumWidthAndKeepCanvasHeight() throws {
    let editor = AnnotationEditorController(image: try toolbarImage(), document: AnnotationDocument(), screen: nil)
    defer { editor.window.close() }
    let bar = editor.toolbar
    bar.frame = CGRect(x: 0, y: 0, width: 1040, height: 75)
    bar.layoutSubtreeIfNeeded()
    #expect(bar.trays.map { $0.buttons.map(\.title) } == [["選択"], ["枠", "スポット", "矢印"], ["文字", "番号"], ["モザイク", "AIで隠す"]])
    #expect(bar.trays.last!.frame.maxX + 10 <= bar.undoButton.frame.minX)
    #expect(bar.finishButton.frame.maxX <= bar.bounds.maxX - 14)
    #expect(bar.hintView.frame.maxX < bar.dimensions.frame.minX)
    for tray in bar.trays { for button in tray.buttons {
        #expect(tray.bounds.contains(button.frame))
        #expect(button.acceptsFirstMouse(for: nil) && button.needsPanelToBecomeKey)
    }}
    #expect(bar.toolButtons[.selection]?.key == "Esc")
    #expect(bar.aiButton.face == .outline && bar.aiButton.dimmed && bar.aiButton.isEnabled)
    let root = try #require(editor.window.contentView)
    root.frame.size = CGSize(width: 1200, height: 915)
    root.layoutSubtreeIfNeeded()
    #expect(editor.canvas.frame == CGRect(x: 0, y: 75, width: 1200, height: 840))
    #expect(editor.canvas.displayScale == 1)
}

@MainActor @Test func annotationToolbarButtonsClearAIMessageAndArmDiscardWithoutChangingName() throws {
    let editor = AnnotationEditorController(image: try toolbarImage(), document: AnnotationDocument(), screen: nil)
    defer { editor.window.close() }
    editor.toolbar.aiButton.performClick(nil)
    #expect(editor.hintText == AnnotationToolbarPresentation.aiDisabled)
    editor.toolbar.toolButtons[.number]?.performClick(nil)
    #expect(editor.canvas.tool == .number && editor.hintText == "クリックで1 ・ 指す点からドラッグで引き出し線")
    editor.canvas.appendPrivacyAnnotations([Annotation(tool: .number, start: CGPoint(x: 100, y: 100))])
    editor.toolbar.discardButton.performClick(nil)
    #expect(editor.toolbar.discardButton.title == "破棄" && editor.toolbar.discardButton.armed)
    #expect(editor.hintText == "もう一度 Q で、注釈を捨てて閉じます")
    editor.toolbar.toolButtons[.rectangle]?.performClick(nil)
    #expect(!editor.toolbar.discardButton.armed && editor.hintText.isEmpty)
}

@MainActor @Test func annotationToolbarDimensionsFollowOutsideArrowDuringDrag() throws {
    let editor = AnnotationEditorController(image: try toolbarImage(), document: AnnotationDocument(), screen: nil)
    defer { editor.window.close() }
    editor.canvas.frame = CGRect(x: 0, y: 75, width: 1200, height: 840)
    #expect(editor.toolbar.dimensions.stringValue == "書き出し 960 × 600")
    editor.toolbar.toolButtons[.arrow]?.performClick(nil)
    editor.canvas.mouseDown(with: try toolbarMouse(editor.canvas, type: .leftMouseDown, at: CGPoint(x: 900, y: 300)))
    editor.canvas.mouseDragged(with: try toolbarMouse(editor.canvas, type: .leftMouseDragged, at: CGPoint(x: 1040, y: 300)))
    let size = editor.canvas.exportLayout.bounds.size
    #expect(size.width > 960)
    #expect(editor.toolbar.dimensions.stringValue == "書き出し \(Int(size.width)) × \(Int(size.height))")
    editor.canvas.mouseUp(with: try toolbarMouse(editor.canvas, type: .leftMouseUp, at: CGPoint(x: 1040, y: 300)))
    editor.canvas.undoAnnotation()
    #expect(editor.toolbar.dimensions.stringValue == "書き出し 960 × 600")
}

@MainActor @Test func annotationToolbarZoomMenuUsesSameViewportOperations() throws {
    let editor = AnnotationEditorController(image: try toolbarImage(), document: AnnotationDocument(), screen: nil)
    defer { editor.window.close() }
    editor.canvas.frame = CGRect(x: 0, y: 75, width: 1200, height: 840)
    let initial = editor.canvas.document
    let item = NSMenuItem()
    for (tag, scale) in [(3, 1.0), (0, 1.25), (1, 1.0), (2, 1.0)] {
        item.tag = tag; editor.changeZoom(item)
        #expect(editor.canvas.displayScale == scale)
    }
    #expect(editor.canvas.document == initial)
    #expect(editor.toolbar.zoomButton.title == "100%")
}

@MainActor @Test func annotationAIButtonKeepsWidthAcrossSearchAndClearsResultOnNextOperation() async throws {
    let service = PrivacyDetectionService(recognize: { _ in
        PrivacyRecognition(faces: [CGRect(x: 50, y: 50, width: 30, height: 30)])
    })
    var config = PrivacyConfig(); config.ai = true
    let editor = AnnotationEditorController(image: try toolbarImage(), document: AnnotationDocument(), screen: nil,
        privacyConfig: config, privacyService: service)
    defer { editor.window.close() }
    editor.toolbar.toolButtons[.rectangle]?.performClick(nil)
    let width = editor.toolbar.aiButton.naturalWidth
    editor.toolbar.aiButton.performClick(nil)
    #expect(editor.toolbar.aiButton.title == "探しています" && editor.toolbar.aiButton.key == "Esc")
    #expect(editor.hintText.isEmpty && editor.toolbar.aiButton.naturalWidth == width)
    for _ in 0..<100 where editor.isFindingPrivacy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!editor.isFindingPrivacy && editor.hintText == "1 か所にモザイクを入れました")
    #expect(editor.toolbar.aiButton.title == "AIで隠す" && editor.toolbar.aiButton.naturalWidth == width)
    // スペースは注釈を変えない操作でも結果を消す。
    editor.canvas.keyDown(with: try toolbarKey(49))
    #expect(editor.hintText.isEmpty)
    editor.canvas.releaseSpace()
    editor.toolbar.aiButton.performClick(nil)
    editor.toolbar.aiButton.performClick(nil)
    #expect(!editor.isFindingPrivacy && editor.hintText == "隠す箇所の検索を中止しました")
}

/// 通常のテストでは画面を開かない。指定時だけ同じ描画部品から状態別PNGを出す。
@MainActor @Test func annotationToolbarStatePreviews() throws {
    guard let directory = ProcessInfo.processInfo.environment["UTSUSHIE_UI_PREVIEW_DIR"] else { return }
    let url = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let states: [(String, AnnotationTool, Bool, Bool, Bool, ToolbarHint?)] = [
        ("number", .number, false, false, false, nil),
        ("rectangle", .rectangle, false, false, false, nil),
        ("selection", .selection, false, false, false, nil),
        ("text", .text, false, false, false, nil),
        ("editing-text", .text, true, false, false, nil),
        ("ai-searching", .rectangle, false, false, true, nil),
        ("ai-result", .rectangle, false, false, false, ToolbarHint("3 か所にモザイクを入れました")),
        ("ai-error", .rectangle, false, false, false, ToolbarHint("隠す箇所を探せませんでした", isError: true)),
        ("ai-disabled", .rectangle, false, false, false, ToolbarHint(AnnotationToolbarPresentation.aiDisabled)),
        ("discard", .rectangle, false, true, false, nil)
    ]
    for width: CGFloat in [1040, 1200] {
        for (name, tool, editing, armed, searching, message) in states {
            let bar = AnnotationToolbarView()
            bar.appearance = NSAppearance(named: .darkAqua)
            bar.frame = CGRect(x: 0, y: 0, width: width, height: AnnotationToolbarPresentation.height)
            bar.toolButtons[tool]?.state = .on
            bar.aiButton.title = searching ? "探しています" : "AIで隠す"
            bar.aiButton.key = searching ? "Esc" : "H"
            bar.aiButton.dimmed = name == "ai-disabled"
            bar.redoButton.isEnabled = false
            bar.discardButton.armed = armed
            bar.dimensions.stringValue = "書き出し 960 × 600"
            bar.zoomButton.title = "100%"
            bar.hintView.hint = AnnotationToolbarPresentation.hint(tool: tool, nextNumber: 4,
                editingText: editing, discardArmed: armed, findingPrivacy: searching, message: message)
            bar.layoutSubtreeIfNeeded()
            let bitmap = try #require(bar.bitmapImageRepForCachingDisplay(in: bar.bounds))
            bar.cacheDisplay(in: bar.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("annotation-toolbar-\(name)-\(Int(width)).png"))
        }
    }
}
