import AppKit
import Testing
import UtsushieCore
@testable import Utsushie

@MainActor private func privacyImage(text: Bool = false) throws -> CGImage {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 500,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    NSColor.white.setFill(); NSBezierPath(rect: CGRect(x: 0, y: 0, width: 1000, height: 500)).fill()
    if text {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black]
        ("alice@example.com" as NSString).draw(at: CGPoint(x: 60, y: 350), withAttributes: attributes)
        ("山田 太郎" as NSString).draw(at: CGPoint(x: 60, y: 240), withAttributes: attributes)
    }
    context.flushGraphics()
    return try #require(bitmap.cgImage)
}
private func privacyResponse(_ ids: [Int]) -> Data {
    let items = ids.map { "{\"id\":\($0),\"reason\":\"秘密情報\"}" }.joined(separator: ",")
    return Data("{\"structured_output\":{\"sensitive\":[\(items)]}}".utf8)
}
@MainActor private func privacyKey(_ code: UInt16, flags: NSEvent.ModifierFlags = [], repeating: Bool = false) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, characters: code == 4 ? "h" : "", charactersIgnoringModifiers: code == 4 ? "h" : "",
        isARepeat: repeating, keyCode: code))
}
@MainActor private func waitForPrivacy(_ editor: AnnotationEditorController) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while editor.isFindingPrivacy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!editor.isFindingPrivacy)
}
private actor PrivacyCalls {
    var count = 0
    func increment() { count += 1 }
}
private final class PrivacyTimings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(PrivacyDiagnostics.Stage, Double)] = []
    func record(_ stage: PrivacyDiagnostics.Stage, _ seconds: Double) {
        lock.withLock { values.append((stage, seconds)) }
    }
    var events: [(PrivacyDiagnostics.Stage, Double)] { lock.withLock { values } }
}

@MainActor @Test func privacyVisionRecognizesJapaneseAndEnglishInPixelCoordinates() async throws {
    let image = try privacyImage(text: true)
    let timings = PrivacyTimings()
    let recognized = try await Task.detached {
        try PrivacyVision.recognize(image, diagnostics: PrivacyDiagnostics(record: timings.record))
    }.value
    #expect(timings.events.map { $0.0 } == [.textRecognition])
    #expect(timings.events[0].1 > 0)
    #expect(recognized.warning == nil && recognized.faces.isEmpty)
    let email = try #require(recognized.lines.first { $0.text.contains("alice@example.com") })
    let name = try #require(recognized.lines.first { $0.text.contains("山田") && $0.text.contains("太郎") })
    #expect(email.rect.minX > 40 && email.rect.maxX < 900 && email.rect.minY > 80 && email.rect.maxY < 160)
    #expect(name.rect.minY > email.rect.maxY && name.rect.maxY < 280)
    #expect(Set(recognized.lines.map(\.id)).count == recognized.lines.count)
}

@MainActor @Test func privacyVisionToFakeAIProducesOrdinaryMosaics() async throws {
    let image = try privacyImage(text: true)
    let service = PrivacyDetectionService(select: { lines, config in
        #expect(config.model == "sonnet" && config.effort == "low")
        let email = try #require(lines.first { $0.text.contains("alice@example.com") })
        return privacyResponse([email.id])
    })
    let result = try await service.detect(image: image, config: PrivacyConfig())
    #expect(result.warning == nil && result.annotations.count == 1)
    #expect(result.annotations[0].tool == .mosaic && result.annotations[0].rect.minY < 160)
    let rendered = try AnnotationRenderer.compose(image, document: AnnotationDocument(annotations: result.annotations))
    #expect(rendered.width == image.width && rendered.height == image.height)
}

@MainActor @Test func privacyFailureKeepsFacesAndNeverAddsText() async throws {
    let image = try privacyImage()
    let face = CGRect(x: 0, y: 0, width: 50, height: 60)
    let line = PrivacyTextLine(id: 1, text: "secret", rect: CGRect(x: 300, y: 100, width: 100, height: 30))
    let service = PrivacyDetectionService(recognize: { _ in PrivacyRecognition(lines: [line], faces: [face]) },
        select: { _, _ in throw PrivacyDetectionError.authentication })
    let result = try await service.detect(image: image, config: PrivacyConfig())
    #expect(result.annotations.count == 1 && result.annotations[0].rect.minX == 0)
    #expect(result.message.contains("1 か所") && result.message.contains("ログイン"))
    let invalid = PrivacyDetectionService(recognize: service.recognize, select: { _, _ in Data("broken".utf8) })
    let malformed = try await invalid.detect(image: image, config: PrivacyConfig())
    #expect(malformed.annotations.count == 1 && malformed.warning == "AIの応答を読み取れませんでした")
}

@MainActor @Test func privacyNoTextSkipsAIAndEmptyResultHasHint() async throws {
    let calls = PrivacyCalls()
    let service = PrivacyDetectionService(recognize: { _ in PrivacyRecognition() }, select: { _, _ in
        await calls.increment(); return privacyResponse([])
    })
    let result = try await service.detect(image: privacyImage(), config: PrivacyConfig())
    #expect(await calls.count == 0)
    #expect(result.annotations.isEmpty && result.message == "隠す箇所は見つかりませんでした")
}

@MainActor @Test func privacyHIsDisabledByDefaultAndIgnoresModifiers() throws {
    let calls = PrivacyCalls()
    let service = PrivacyDetectionService(select: { _, _ in await calls.increment(); return privacyResponse([]) })
    let editor = AnnotationEditorController(image: try privacyImage(), document: AnnotationDocument(), screen: nil, privacyService: service)
    defer { editor.window.close() }
    #expect(!editor.handlePrivacyKey(try privacyKey(4, flags: .shift)))
    #expect(editor.handlePrivacyKey(try privacyKey(4, flags: .function)))
    #expect(editor.hintText == AnnotationToolbarPresentation.aiDisabled && !editor.isFindingPrivacy)
    #expect(editor.canvas.document.annotations.isEmpty)
}

@MainActor @Test func privacyEditorAddsOnceAndUndoesTogetherWhileKeepingExistingAnnotations() async throws {
    let calls = PrivacyCalls()
    let lines = [PrivacyTextLine(id: 1, text: "secret", rect: CGRect(x: 100, y: 100, width: 200, height: 30)),
                 PrivacyTextLine(id: 2, text: "email", rect: CGRect(x: 100, y: 200, width: 200, height: 30))]
    let service = PrivacyDetectionService(recognize: { _ in PrivacyRecognition(lines: lines, faces: [CGRect(x: 10, y: 10, width: 50, height: 50)]) },
        select: { _, _ in
            await calls.increment(); try await Task.sleep(for: .milliseconds(50)); return privacyResponse([1, 2])
        })
    var config = PrivacyConfig(); config.ai = true
    let initial = AnnotationDocument(annotations: [Annotation(tool: .number, start: CGPoint(x: 800, y: 400))])
    let editor = AnnotationEditorController(image: try privacyImage(), document: initial, screen: nil, privacyConfig: config, privacyService: service)
    defer { editor.window.close() }
    editor.canvas.keyDown(with: try privacyKey(4))
    #expect(editor.isFindingPrivacy && editor.toolbar.aiButton.title == "探しています" && editor.toolbar.aiButton.key == "Esc")
    editor.canvas.keyDown(with: try privacyKey(4))
    editor.canvas.keyDown(with: try privacyKey(4, repeating: true))
    editor.canvas.keyDown(with: try privacyKey(15))
    #expect(editor.canvas.tool == .rectangle)
    try await waitForPrivacy(editor)
    #expect(await calls.count == 1)
    #expect(editor.canvas.document.annotations.count == 4 && editor.hintText == "3 か所にモザイクを入れました")
    editor.canvas.undoAnnotation()
    #expect(editor.canvas.document == initial)
    editor.canvas.redoAnnotation()
    #expect(editor.canvas.document.annotations.count == 4)
}

@MainActor @Test func privacyEscapeAndCloseDiscardLateResults() async throws {
    let line = PrivacyTextLine(id: 1, text: "secret", rect: CGRect(x: 100, y: 100, width: 200, height: 30))
    let service = PrivacyDetectionService(recognize: { _ in PrivacyRecognition(lines: [line]) }, select: { _, _ in
        // キャンセルを無視する差し替えでも、遅れて返った結果を追加してはいけない。
        try? await Task.sleep(for: .milliseconds(100)); return privacyResponse([1])
    })
    var config = PrivacyConfig(); config.ai = true
    for close in [false, true] {
        let editor = AnnotationEditorController(image: try privacyImage(), document: AnnotationDocument(), screen: nil, privacyConfig: config, privacyService: service)
        editor.findPrivacy()
        try await Task.sleep(for: .milliseconds(30))
        if close { editor.window.close() }
        else { #expect(editor.handlePrivacyKey(try privacyKey(53))) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!editor.isFindingPrivacy && editor.canvas.document.annotations.isEmpty)
        editor.window.close()
    }
}

@Test func privacyProcessDrainsBothPipesWithoutBlocking() async throws {
    let result = try await PrivacyProcess.run(executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "i=0; while [ $i -lt 20000 ]; do printf 'output'; printf 'error' >&2; i=$((i+1)); done"],
        deadline: .now.advanced(by: .seconds(10)))
    #expect(result.status == 0 && result.output.count == 120000 && result.error.count == 100000)
}
@Test func privacyProcessTimeoutStopsSIGTERMIgnoringProcess() async throws {
    do {
        _ = try await PrivacyProcess.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do :; done"], deadline: .now.advanced(by: .milliseconds(150)))
        Issue.record("時間切れにならなかった")
    } catch let error as PrivacyDetectionError { #expect(error == .timedOut) }
}
@Test func privacyProcessCancellationStopsOnlyItsProcess() async throws {
    let task = Task {
        try await PrivacyProcess.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "while :; do :; done"], deadline: .now.advanced(by: .seconds(10)))
    }
    try await Task.sleep(for: .milliseconds(100)); task.cancel()
    do { _ = try await task.value; Issue.record("キャンセルされなかった") }
    catch is CancellationError { }
}

@Test(arguments: ["low", "medium", "high"])
func privacyClientInvokesConfiguredExecutableWithTextOnlyAndRequiredFlags(_ effort: String) async throws {
    var config = PrivacyConfig(); config.claude = "/mock/claude"; config.effort = effort
    let line = PrivacyTextLine(id: 7, text: "private@example.com", rect: CGRect(x: 314, y: 271, width: 628, height: 542))
    let response = try await ClaudePrivacyClient.select(lines: [line], config: config, run: { executable, arguments, deadline in
        #expect(executable.path == "/mock/claude")
        #expect(arguments[0] == "-p" && arguments[1].contains("private@example.com"))
        #expect(!arguments[1].contains("314") && !arguments[1].contains("rect"))
        #expect(Array(arguments.dropFirst(2)) == ["--model", "sonnet", "--effort", effort, "--output-format", "json", "--json-schema",
            PrivacySelection.schema, "--no-session-persistence", "--tools", "", "--setting-sources", "local"])
        #expect(ContinuousClock.now.duration(to: deadline) <= .seconds(60))
        return PrivacyProcessResult(output: privacyResponse([7]), error: Data(), status: 0)
    }, isExecutable: { $0 == "/mock/claude" })
    #expect(try PrivacySelection.rectangles(response: response, lines: [line]) == [line.rect])
}

@Test func privacyClientFallsBackToLoginShellAndNeverFallsBackFromExplicitPath() async throws {
    let calls = PrivacyCalls()
    let response = try await ClaudePrivacyClient.select(lines: [], config: PrivacyConfig(), run: { executable, arguments, _ in
        await calls.increment()
        if executable.path == "/mock/shell" {
            #expect(arguments == ["-lc", "command -v claude"])
            return PrivacyProcessResult(output: Data("/custom/bin/claude\n".utf8), error: Data(), status: 0)
        }
        #expect(executable.path == "/custom/bin/claude")
        return PrivacyProcessResult(output: privacyResponse([]), error: Data(), status: 0)
    }, isExecutable: { $0 == "/custom/bin/claude" }, home: URL(fileURLWithPath: "/mock/home"), shell: "/mock/shell")
    #expect(response == privacyResponse([]))
    #expect(await calls.count == 2)
    var config = PrivacyConfig(); config.claude = "/missing/claude"
    do {
        _ = try await ClaudePrivacyClient.select(lines: [], config: config, run: { _, _, _ in
            Issue.record("明示パスがない場合に別の実行ファイルを起動した")
            return PrivacyProcessResult(output: Data(), error: Data(), status: 1)
        }, isExecutable: { _ in false })
        Issue.record("実行ファイル不在を通知しなかった")
    } catch let error as PrivacyDetectionError { #expect(error == .notFound) }
}

@Test(arguments: [true, false]) func privacyClientReportsAuthenticationAndExecutionFailures(_ authentication: Bool) async throws {
    var config = PrivacyConfig(); config.claude = "/mock/claude"
    do {
        _ = try await ClaudePrivacyClient.select(lines: [], config: config, run: { _, _, _ in
            PrivacyProcessResult(output: Data(authentication ? #"{"is_error":true,"result":"Not logged in"}"#.utf8 : "failed".utf8),
                error: Data(), status: authentication ? 0 : 1)
        }, isExecutable: { _ in true })
        Issue.record("失敗を通知しなかった")
    } catch let error as PrivacyDetectionError { #expect(error == (authentication ? .authentication : .failed)) }
}

@Test func privacyTimingsSeparateLoginShellSearchFromClaudeExecution() async throws {
    let timings = PrivacyTimings()
    _ = try await ClaudePrivacyClient.select(lines: [], config: PrivacyConfig(), run: { executable, _, _ in
        if executable.path == "/mock/shell" {
            try await Task.sleep(for: .milliseconds(40))
            return PrivacyProcessResult(output: Data("/mock/claude\n".utf8), error: Data(), status: 0)
        }
        try await Task.sleep(for: .milliseconds(80))
        return PrivacyProcessResult(output: privacyResponse([]), error: Data(), status: 0)
    }, isExecutable: { $0 == "/mock/claude" }, home: URL(fileURLWithPath: "/mock/home"), shell: "/mock/shell",
        diagnostics: PrivacyDiagnostics(record: timings.record))
    let events = timings.events
    #expect(events.map { $0.0 } == [.claudeSearch, .claudeExecution])
    #expect(events[0].1 >= 0.03 && events[1].1 >= 0.07)
}

@Test(arguments: [true, false]) func privacyTimingsRecordFailedSearchAndTimedOutExecution(_ failSearch: Bool) async throws {
    let timings = PrivacyTimings()
    var config = PrivacyConfig(); config.claude = "/mock/claude"
    do {
        _ = try await ClaudePrivacyClient.select(lines: [], config: config, run: { _, _, _ in
            throw PrivacyDetectionError.timedOut
        }, isExecutable: { _ in !failSearch }, diagnostics: PrivacyDiagnostics(record: timings.record))
        Issue.record("失敗を通知しなかった")
    } catch let error as PrivacyDetectionError { #expect(error == (failSearch ? .notFound : .timedOut)) }
    #expect(timings.events.map { $0.0 } == (failSearch ? [.claudeSearch] : [.claudeSearch, .claudeExecution]))
    #expect(timings.events.allSatisfy { $0.1 >= 0 && $0.1.isFinite })
}

@MainActor private func privacyMouse(_ canvas: AnnotationCanvas, type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
    let location = canvas.convert(CGPoint(x: canvas.imageRect.minX + point.x * canvas.displayScale,
                                         y: canvas.imageRect.minY + point.y * canvas.displayScale), to: nil)
    return try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
        windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
}

@MainActor @Test func privacyHRemainsTextAndMarkedEscapeRemainsIMEInput() async throws {
    let line = PrivacyTextLine(id: 1, text: "secret", rect: CGRect(x: 100, y: 100, width: 200, height: 30))
    let service = PrivacyDetectionService(recognize: { _ in PrivacyRecognition(lines: [line]) }, select: { _, _ in
        try await Task.sleep(for: .seconds(2)); return privacyResponse([1])
    })
    var config = PrivacyConfig(); config.ai = true
    let editor = AnnotationEditorController(image: try privacyImage(), document: AnnotationDocument(), screen: nil, privacyConfig: config, privacyService: service)
    defer { editor.window.close() }
    editor.findPrivacy()
    editor.canvas.tool = .text
    editor.canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    editor.canvas.mouseDown(with: try privacyMouse(editor.canvas, type: .leftMouseDown, at: CGPoint(x: 100, y: 100)))
    editor.canvas.mouseUp(with: try privacyMouse(editor.canvas, type: .leftMouseUp, at: CGPoint(x: 100, y: 100)))
    let input = try #require(editor.canvas.subviews.compactMap { $0 as? AnnotationTextView }.first)
    #expect(!editor.handlePrivacyKey(try privacyKey(4)))
    input.keyDown(with: try privacyKey(4))
    #expect(input.string == "h" && editor.canvas.isEditingText)
    input.setMarkedText("変換", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(!editor.handlePrivacyKey(try privacyKey(53)) && editor.isFindingPrivacy)
    input.unmarkText()
    #expect(editor.handlePrivacyKey(try privacyKey(53)) && !editor.isFindingPrivacy && editor.canvas.isEditingText)
}

@MainActor @Test func privacyResultWaitsForDragAndKeepsSeparateUndoSteps() async throws {
    let line = PrivacyTextLine(id: 1, text: "secret", rect: CGRect(x: 100, y: 100, width: 200, height: 30))
    let service = PrivacyDetectionService(recognize: { _ in PrivacyRecognition(lines: [line]) }, select: { _, _ in privacyResponse([1]) })
    var config = PrivacyConfig(); config.ai = true
    let editor = AnnotationEditorController(image: try privacyImage(), document: AnnotationDocument(), screen: nil, privacyConfig: config, privacyService: service)
    defer { editor.window.close() }
    editor.canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600); editor.canvas.tool = .rectangle
    editor.findPrivacy()
    editor.canvas.mouseDown(with: try privacyMouse(editor.canvas, type: .leftMouseDown, at: CGPoint(x: 400, y: 100)))
    editor.canvas.mouseDragged(with: try privacyMouse(editor.canvas, type: .leftMouseDragged, at: CGPoint(x: 600, y: 200)))
    try await Task.sleep(for: .milliseconds(100))
    #expect(editor.isFindingPrivacy && editor.canvas.document.annotations.count == 1 && !editor.canvas.history.canUndo)
    editor.canvas.mouseUp(with: try privacyMouse(editor.canvas, type: .leftMouseUp, at: CGPoint(x: 600, y: 200)))
    try await waitForPrivacy(editor)
    #expect(editor.canvas.document.annotations.map(\.tool) == [.rectangle, .mosaic])
    editor.canvas.undoAnnotation()
    #expect(editor.canvas.document.annotations.map(\.tool) == [.rectangle])
    editor.canvas.undoAnnotation()
    #expect(editor.canvas.document.annotations.isEmpty)
}
