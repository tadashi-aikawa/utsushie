import AppKit
import OSLog
import UtsushieCore

/// OSのアクティベーションは要求であり、成功を同期的には保証しない。
/// テストでは実際の前面アプリを変更せず、要求と復帰の条件を確かめる。
@MainActor
struct AnnotationApplicationFocus {
    var isActive: () -> Bool = { NSApp.isActive }
    var frontmostApplication: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    var activate: () -> Void = { NSApp.activate() }
    var restore: (NSRunningApplication) -> Void = { application in
        NSApp.yieldActivation(to: application)
        _ = application.activate(options: [])
    }
}

@MainActor
final class AnnotationEditorController: NSObject, NSWindowDelegate {
    // アプリ起動中だけ共有する。設定ファイルへ書き戻さない。
    private static var lastTool: AnnotationTool = .rectangle
    let window: AnnotationPanel
    let canvas: AnnotationCanvas
    let toolbar = AnnotationToolbarView()
    private var toolButtons: [AnnotationTool: ToolbarButton] { toolbar.toolButtons }
    private var undoButton: ToolbarButton { toolbar.undoButton }
    private var redoButton: ToolbarButton { toolbar.redoButton }
    private var finishButton: ToolbarButton { toolbar.finishButton }
    private var saving = false
    private var closing = false
    private let initial: AnnotationDocument
    private let applicationFocus: AnnotationApplicationFocus
    private let privacyConfig: PrivacyConfig
    private let privacyService: PrivacyDetectionService
    private var privacyTask: Task<Void, Never>?
    private var privacyOperation: UUID?
    private var privacyMessage: ToolbarHint?
    var isFindingPrivacy: Bool { privacyOperation != nil }
    var hintText: String { toolbar.hintView.hint.text }
    private var previousApplication: NSRunningApplication?
    var onComplete: ((CGImage, AnnotationDocument) async throws -> Void)?
    var onClose: (() -> Void)?

    init(image: CGImage, document: AnnotationDocument, screen: NSScreen?, applicationFocus: AnnotationApplicationFocus = AnnotationApplicationFocus(),
         privacyConfig: PrivacyConfig = PrivacyConfig(), privacyService: PrivacyDetectionService = PrivacyDetectionService(),
         history: AnnotationHistory? = nil) {
        initial = history?.document ?? document
        self.applicationFocus = applicationFocus
        self.privacyConfig = privacyConfig; self.privacyService = privacyService
        canvas = AnnotationCanvas(image: image, document: document, tool: Self.lastTool, history: history)
        let visible = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: min(max(CGFloat(image.width) + 240, 1180), visible.width - 40),
                          height: min(max(CGFloat(image.height) + 292, 420), visible.height - 80) + AnnotationToolbarPresentation.height - 52)
        window = AnnotationPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.title = "UTSUSHIE — 注釈"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.becomesKeyOnlyIfNeeded = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.acceptsMouseMovedEvents = true
        let toolbarWidth = toolbar.minimumWidth
        window.minSize = CGSize(width: toolbarWidth, height: 383)
        if size.width < toolbarWidth { window.setContentSize(CGSize(width: toolbarWidth, height: size.height)) }
        window.delegate = self
        window.editor = self
        let root = AnnotationEditorLayout(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true; root.layer?.backgroundColor = UITheme.ink.cgColor
        for button in toolButtons.values { button.target = self; button.action = #selector(selectTool(_:)) }
        configure(undoButton, title: "↶", action: #selector(undoAnnotation))
        configure(redoButton, title: "↷", action: #selector(redoAnnotation))
        undoButton.toolTip = "取り消し ⌘Z"; redoButton.toolTip = "やり直し ⇧⌘Z"
        configure(finishButton, title: "完了", action: #selector(finish))
        configure(toolbar.aiButton, title: "AIで隠す", action: #selector(privacyButtonPressed))
        configure(toolbar.zoomButton, title: "100%", action: #selector(showZoomMenu))
        for button in toolbar.highlighterControls.colorButtons.values {
            button.target = self; button.action = #selector(selectHighlighterColor(_:))
        }
        toolbar.highlighterControls.darkButton.target = self
        toolbar.highlighterControls.darkButton.action = #selector(toggleHighlighterBackground)
        for button in toolbar.inkControls.colorButtons.values {
            button.target = self; button.action = #selector(selectInkColor(_:))
        }
        toolbar.zoomButton.toolTip = "倍率メニュー ・ ピンチでも拡大縮小"
        root.bar = toolbar; root.canvas = canvas
        root.addSubview(canvas)
        root.addSubview(toolbar, positioned: .above, relativeTo: canvas)
        window.contentView = root
        window.setFrameOrigin(CGPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
        canvas.onChange = { [weak self] in
            guard let self else { return }
            if !isFindingPrivacy { privacyMessage = nil }
            update()
        }
        canvas.onToolChange = { tool in Self.lastTool = tool }
        canvas.onFinish = { [weak self] in self?.finish() }
        canvas.onPrivacy = { [weak self] in self?.findPrivacy() }
        canvas.onCancelPrivacy = { [weak self] in self?.cancelPrivacy() ?? false }
        canvas.onUserOperation = { [weak self] in self?.clearPrivacyMessage() }
        update()
    }
    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title; button.target = self; button.action = action
    }
    func show() {
        if let application = applicationFocus.frontmostApplication(),
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = application
        }
        requestActivation(reason: "editor open")
        // アクティベーション要求が断られても、キーとクリックの従来の経路は保つ。
        window.orderFrontRegardless(); window.makeKey(); window.makeFirstResponder(canvas)
        AnnotationNavigationDiagnostics.observeFocus("editor shown", isActive: applicationFocus.isActive(),
                                                     frontmostApplication: applicationFocus.frontmostApplication())
    }
    func requestActivation(reason: String) {
        let front = applicationFocus.frontmostApplication()
        let active = applicationFocus.isActive()
        AnnotationNavigationDiagnostics.observeFocus(reason, isActive: active, frontmostApplication: front)
        // isActiveだけで再要求を止めず、前面のPIDが自分になるまではユーザー操作のたびに要求する。
        guard !closing, front?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        AnnotationNavigationDiagnostics.observeFocus("activation before: \(reason)", isActive: active, frontmostApplication: front)
        applicationFocus.activate()
        AnnotationNavigationDiagnostics.observeFocus("activation after: \(reason)", isActive: applicationFocus.isActive(),
                                                     frontmostApplication: applicationFocus.frontmostApplication())
    }
    private func update() {
        toolbar.zoomButton.title = canvas.zoomPercentage
        let size = canvas.exportLayout.bounds.size
        toolbar.dimensions.stringValue = "書き出し \(Int(size.width)) × \(Int(size.height))"
        for (tool, button) in toolButtons {
            button.state = tool == canvas.tool ? .on : .off
            button.needsDisplay = true
        }
        undoButton.isEnabled = canvas.history.canUndo && !saving
        redoButton.isEnabled = canvas.history.canRedo && !saving
        toolbar.aiButton.title = isFindingPrivacy ? "探しています" : "AIで隠す"
        toolbar.aiButton.key = isFindingPrivacy ? "Esc" : "H"
        toolbar.aiButton.dimmed = !privacyConfig.ai
        toolbar.aiButton.isEnabled = !saving && (isFindingPrivacy || !canvas.isEditingText)
        toolbar.aiButton.setAccessibilityLabel(toolbar.aiButton.title)
        toolbar.aiButton.setAccessibilityHelp(isFindingPrivacy ? "Escで中止" : privacyConfig.ai ? "Hで隠す箇所を探す" : AnnotationToolbarPresentation.aiDisabled)
        toolbar.zoomButton.isEnabled = !saving
        toolbar.hintView.hint = AnnotationToolbarPresentation.hint(tool: canvas.tool, nextNumber: canvas.document.nextNumber,
            editingText: canvas.isEditingText, findingPrivacy: isFindingPrivacy, message: privacyMessage, saving: saving)
        // 状態と文字入力の手引きは、色の部品より優先する。
        let colorControls: AnnotationColorControls = saving || privacyMessage != nil || isFindingPrivacy || canvas.isEditingText ? .none : canvas.colorControls
        toolbar.highlighterControls.isHidden = colorControls != .highlighter
        toolbar.inkControls.isHidden = colorControls != .ink
        toolbar.hintView.isHidden = colorControls != .none
        toolbar.highlighterControls.update(color: canvas.highlighterColor, darkBackground: canvas.highlighterDarkBackground,
                                          enabled: !saving && canvas.isEnabled && !canvas.isInteracting)
        toolbar.inkControls.update(color: canvas.inkColor, enabled: !saving && canvas.isEnabled && !canvas.isInteracting)
        [undoButton, redoButton, finishButton, toolbar.aiButton, toolbar.zoomButton].forEach { $0.needsDisplay = true }
        toolbar.needsLayout = true
    }
    func clearPrivacyMessage() {
        guard privacyMessage != nil else { return }
        privacyMessage = nil; update()
    }
    @objc private func privacyButtonPressed() {
        if !cancelPrivacy() { findPrivacy() }
        window.makeFirstResponder(canvas.isEditingText ? window.firstResponder : canvas)
    }
    @objc private func showZoomMenu() {
        clearPrivacyMessage()
        let menu = NSMenu()
        for (title, key, tag) in [("拡大", "+", 0), ("縮小", "-", 1), ("全体を表示", "0", 2), ("実寸で表示", "1", 3)] {
            if tag == 2 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: #selector(changeZoom(_:)), keyEquivalent: key)
            item.target = self; item.tag = tag; item.keyEquivalentModifierMask = .command
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: toolbar.zoomButton.bounds.maxY), in: toolbar.zoomButton)
    }
    @objc func changeZoom(_ sender: NSMenuItem) {
        let anchor = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        switch sender.tag {
        case 0: canvas.zoom(to: canvas.displayScale * 1.25, around: anchor)
        case 1: canvas.zoom(to: canvas.displayScale / 1.25, around: anchor)
        case 2: canvas.fitAll()
        case 3: canvas.zoom(to: 1, around: anchor)
        default: return
        }
    }
    func handlePrivacyKey(_ event: NSEvent) -> Bool {
        guard !saving, !closing, window.attachedSheet == nil else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.isEmpty else { return false }
        if event.keyCode == 53, isFindingPrivacy {
            // IME変換中のEscは従来どおりinput contextへ渡す。
            if let input = window.firstResponder as? NSTextView, input.hasMarkedText() { return false }
            return cancelPrivacy()
        }
        guard event.keyCode == 4, !canvas.isEditingText else { return false }
        if !event.isARepeat { findPrivacy() }
        return true
    }
    func findPrivacy() {
        guard !saving, !closing, !isFindingPrivacy, !canvas.isEditingText else { return }
        guard privacyConfig.ai else {
            privacyMessage = ToolbarHint(AnnotationToolbarPresentation.aiDisabled); update(); return
        }
        let operation = UUID()
        privacyOperation = operation; privacyMessage = nil; update()
        privacyTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await privacyService.detect(image: canvas.original, config: privacyConfig)
                // 進行中のドラッグや文字入力の履歴へ割り込まない。通常操作の完了後に一括で置く。
                while canvas.isInteracting { try await Task.sleep(for: .milliseconds(50)) }
                try Task.checkCancellation()
                guard privacyOperation == operation, !closing, !saving else { return }
                canvas.appendPrivacyAnnotations(result.annotations)
                privacyMessage = ToolbarHint(result.message, isError: result.warning != nil)
            } catch is CancellationError {
                guard privacyOperation == operation else { return }
                privacyMessage = ToolbarHint("隠す箇所の検索を中止しました")
            }
            catch {
                guard privacyOperation == operation else { return }
                privacyMessage = ToolbarHint("隠す箇所を探せませんでした", isError: true)
            }
            guard privacyOperation == operation else { return }
            privacyOperation = nil; privacyTask = nil; update()
        }
    }
    @discardableResult func cancelPrivacy() -> Bool {
        guard isFindingPrivacy else { return false }
        privacyTask?.cancel(); privacyTask = nil; privacyOperation = nil
        privacyMessage = ToolbarHint("隠す箇所の検索を中止しました"); update()
        return true
    }
    @objc private func selectTool(_ sender: NSButton) {
        guard !saving, let tool = toolButtons.first(where: { $0.value === sender })?.key else { return }
        clearPrivacyMessage()
        canvas.commitText(); canvas.tool = tool; Self.lastTool = tool
        update(); window.makeFirstResponder(canvas)
    }
    @objc private func selectHighlighterColor(_ sender: HighlighterColorButton) {
        guard !saving else { return }
        canvas.applyHighlighterAction(.color(sender.color))
        window.makeFirstResponder(canvas)
    }
    @objc private func selectInkColor(_ sender: InkColorButton) {
        guard !saving else { return }
        canvas.applyInkColor(sender.color)
        window.makeFirstResponder(canvas)
    }
    @objc private func toggleHighlighterBackground() {
        guard !saving else { return }
        canvas.applyHighlighterAction(.toggleDarkBackground)
        window.makeFirstResponder(canvas)
    }
    @objc private func undoAnnotation() { guard !saving else { return }; canvas.commitText(); canvas.undoAnnotation() }
    @objc private func redoAnnotation() { guard !saving else { return }; canvas.commitText(); canvas.redoAnnotation() }
    func handleEquivalent(_ event: NSEvent) -> Bool {
        guard window.attachedSheet == nil else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .command, event.keyCode == 13 { finish(); return true } // W
        if flags == .command, event.keyCode == 36 || event.keyCode == 76 { finish(); return true }
        if canvas.handleZoomKey(event) { return true }
        if canvas.isEditingText { return false }
        if canvas.handleClipboardKey(event) { return true }
        if flags == .command, event.keyCode == 6 { undoAnnotation(); return true }
        if flags == [.command, .shift], event.keyCode == 6 { redoAnnotation(); return true }
        return false
    }
    @objc private func finish() {
        guard !saving, !closing, window.attachedSheet == nil else { return }
        cancelPrivacy()
        canvas.commitText()
        canvas.finishGesture()
        let document = canvas.document
        guard document != initial else { close(); return }
        saving = true; canvas.isEnabled = false
        finishButton.isEnabled = false
        toolButtons.values.forEach { $0.isEnabled = false }; update()
        Task { [self] in
            do {
                let image = try AnnotationRenderer.compose(canvas.original, document: document)
                try await onComplete?(image, document)
                close()
            } catch {
                saving = false; canvas.isEnabled = true
                finishButton.isEnabled = true
                toolButtons.values.forEach { $0.isEnabled = true }; update()
                let alert = NSAlert(); alert.messageText = "注釈を保存できませんでした"; alert.informativeText = error.localizedDescription
                await alert.beginSheetModal(for: window)
            }
        }
    }
    private func close() { cancelPrivacy(); closing = true; window.close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing { return true }
        finish(); return false
    }
    func windowWillClose(_ notification: Notification) {
        cancelPrivacy()
        let application = previousApplication
        previousApplication = nil
        let front = applicationFocus.frontmostApplication()
        AnnotationNavigationDiagnostics.observeFocus("editor close", isActive: applicationFocus.isActive(), frontmostApplication: front)
        if front?.processIdentifier == ProcessInfo.processInfo.processIdentifier, let application, !application.isTerminated,
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            applicationFocus.restore(application)
        }
        onClose?(); onClose = nil; onComplete = nil
    }
    func windowDidResignKey(_ notification: Notification) { canvas.releaseSpace() }
}

@MainActor
final class AnnotationPanel: NSPanel {
    weak var editor: AnnotationEditorController?
    private let navigationLog = Logger(subsystem: "com.tadashi-aikawa.utsushie", category: "AnnotationNavigation")
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .magnify:
            editor?.clearPrivacyMessage()
        default: break
        }
        if event.type == .keyDown, editor?.handlePrivacyKey(event) == true { return }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            editor?.requestActivation(reason: "panel mouseDown")
        case .scrollWheel:
            editor?.requestActivation(reason: "panel scrollWheel")
        default: break
        }
        if event.type == .magnify, let canvas = editor?.canvas {
            let location = canvas.convert(event.locationInWindow, from: nil)
            // 非アクティブパネルでも、first responderによらずキャンバス内のピンチを1回だけ処理する。
            // 文字入力ビューの上でも同じ経路にし、ツールバー・シートのイベントは横取りしない。
            let inCanvas = canvas.bounds.contains(location) && attachedSheet == nil
            let hitPoint = canvas.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            let target = inCanvas ? canvas.hitTest(hitPoint) : nil
            let targetName = target.map { String(describing: type(of: $0)) } ?? "outsideCanvas"
            let before = canvas.displayScale
            if inCanvas { canvas.magnify(with: event) }
            let front = NSWorkspace.shared.frontmostApplication
            let frontBundle = front?.bundleIdentifier ?? "nil"
            let frontPID = front?.processIdentifier ?? -1
            navigationLog.debug("magnify received: active=\(NSApp.isActive) frontmost=\(frontBundle, privacy: .public) frontmostPID=\(frontPID) key=\(self.isKeyWindow) target=\(targetName, privacy: .public) delta=\(event.magnification) scale=\(before)->\(canvas.displayScale)")
            if inCanvas { return }
        }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if editor?.handleEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class AnnotationEditorLayout: NSView {
    var bar: AnnotationToolbarView!
    var canvas: AnnotationCanvas!
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let height = AnnotationToolbarPresentation.height
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        canvas.frame = CGRect(x: 0, y: height, width: bounds.width, height: max(0, bounds.height - height))
    }
}

@MainActor
final class AnnotationCanvas: NSView, NSTextViewDelegate {
    // lastToolと同じく、プロセス内だけで次に描く蛍光ペンの設定を共有する。
    private static var lastHighlighterColor: HighlighterColor = .yellow
    private static var lastHighlighterDarkBackground = false
    private static var lastInkColor: InkColor = .red
    let original: CGImage
    private(set) var history: AnnotationHistory
    var tool: AnnotationTool { didSet { updateCursor(); needsDisplay = true } }
    var onChange: (() -> Void)?
    var onUserOperation: (() -> Void)?
    var onFinish: (() -> Void)?
    var onPrivacy: (() -> Void)?
    var onCancelPrivacy: (() -> Bool)?
    var isEnabled = true
    private(set) var selection: Set<UUID> = []
    private var gesture: Gesture?
    private var selectionBeforeGesture: Set<UUID> = []
    private var viewportBeforeGesture: AnnotationViewport?
    private var preview: AnnotationDocument?
    private var composed: CGImage?
    private var renderedDocument: AnnotationDocument?
    private var cursorPoint: CGPoint?
    private var textInput: AnnotationTextView?
    private var textAnnotation: Annotation?
    private var textAnchor: CGPoint?
    private var frozenImageRect: CGRect?
    private var manualViewport: AnnotationViewport?
    private var spacePressed = false
    private var scrollZooming = false
    private var highlighterStraight = false
    private var clipboard = AnnotationClipboard()
    private enum Gesture {
        case create(Annotation)
        case label(Annotation)
        case move(Set<UUID>, CGPoint, UUID)
        case resize(Annotation, AnnotationResizeHandle)
        case marquee(CGPoint, Set<UUID>)
        case pan(AnnotationViewport, CGPoint)
    }
    private var marqueeRect: CGRect?
    private var marqueeSelection: Set<UUID>?
    var displayedSelection: Set<UUID> {
        switch gesture {
        case .create, .label: return []
        default: return marqueeSelection ?? selection
        }
    }
    private var toggleOnClick: (id: UUID, previous: Set<UUID>)?
    var document: AnnotationDocument {
        var result = preview ?? history.document
        if let textAnnotation { result.replace(textAnnotation) }
        return result
    }
    var isEditingText: Bool { textInput != nil }
    var isInteracting: Bool { gesture != nil || isEditingText }
    private var selectedHighlighters: [Annotation] {
        history.document.annotations.filter { selection.contains($0.id) && $0.tool == .highlighter }
    }
    var colorControls: AnnotationColorControls {
        AnnotationToolbarPresentation.colorControls(tool: tool,
            selectedTools: history.document.annotations.filter { selection.contains($0.id) }.map(\.tool))
    }
    var showsHighlighterControls: Bool { colorControls == .highlighter }
    var showsInkControls: Bool { colorControls == .ink }
    private var selectedInkAnnotations: [Annotation] {
        history.document.annotations.filter { selection.contains($0.id) && $0.tool.usesInkColor }
    }
    var inkColor: InkColor? {
        let colors = Set(selectedInkAnnotations.map(\.inkColor))
        return colors.isEmpty ? Self.lastInkColor : colors.count == 1 ? colors.first : nil
    }
    func applyInkColor(_ color: InkColor) {
        guard isEnabled, !isInteracting, window?.attachedSheet == nil, showsInkControls else { return }
        onUserOperation?()
        Self.lastInkColor = color
        if !selectedInkAnnotations.isEmpty { history.commit(history.document.settingInk(selection, color: color)) }
        changed()
    }
    var highlighterColor: HighlighterColor? {
        let colors = Set(selectedHighlighters.map(\.highlighterColor))
        return colors.isEmpty ? Self.lastHighlighterColor : colors.count == 1 ? colors.first : nil
    }
    var highlighterDarkBackground: Bool? {
        let backgrounds = Set(selectedHighlighters.map(\.darkBackground))
        return backgrounds.isEmpty ? Self.lastHighlighterDarkBackground : backgrounds.count == 1 ? backgrounds.first : nil
    }
    func applyHighlighterAction(_ action: HighlighterAction) {
        guard isEnabled, !isInteracting, window?.attachedSheet == nil, showsHighlighterControls else { return }
        onUserOperation?()
        let next: AnnotationDocument
        switch action {
        case .color(let color):
            Self.lastHighlighterColor = color
            next = history.document.settingHighlighter(selection, color: color)
        case .toggleDarkBackground:
            let dark = highlighterDarkBackground != true
            Self.lastHighlighterDarkBackground = dark
            next = history.document.settingHighlighter(selection, darkBackground: dark)
        }
        if !selectedHighlighters.isEmpty { history.commit(next) }
        changed()
    }
    func appendPrivacyAnnotations(_ annotations: [Annotation]) {
        guard !annotations.isEmpty else { return }
        var next = history.document
        next.annotations += annotations
        history.commit(next); changed()
    }
    private var imageSize: CGSize { CGSize(width: original.width, height: original.height) }
    private var style: AnnotationStyle { AnnotationStyle(imageSize: imageSize) }
    var exportLayout: AnnotationExportLayout { document.exportLayout(imageSize: imageSize) }
    private var viewport: AnnotationViewport {
        if let frozenImageRect { return AnnotationViewport(scale: frozenImageRect.width / imageSize.width, origin: frozenImageRect.origin) }
        return manualViewport ?? AnnotationViewport.fit(content: exportLayout.bounds, in: bounds)
    }
    var imageRect: CGRect {
        CGRect(origin: viewport.origin, size: CGSize(width: imageSize.width * viewport.scale, height: imageSize.height * viewport.scale))
    }
    var displayScale: Double { viewport.scale }
    var zoomPercentage: String { viewport.percentage }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(image: CGImage, document: AnnotationDocument, tool: AnnotationTool, history: AnnotationHistory? = nil) {
        original = image; self.history = history ?? AnnotationHistory(document); self.tool = tool
        super.init(frame: .zero)
        // macOS 14以降のNSViewは既定でクリップしない。文字入力の子ビューも領域内に留める。
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); layoutText(); needsDisplay = true; onChange?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    private func point(_ event: NSEvent) -> CGPoint {
        viewport.imagePoint(at: convert(event.locationInWindow, from: nil))
    }
    private func viewPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + p.x * displayScale, y: imageRect.minY + p.y * displayScale)
    }
    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(origin: viewPoint(r.origin), size: CGSize(width: r.width * displayScale, height: r.height * displayScale))
    }
    private func changed() { updateCursor(); needsDisplay = true; onChange?() }
    private func viewChanged(anchor: CGPoint? = nil) {
        if let anchor { cursorPoint = viewport.imagePoint(at: anchor) }
        else if let window { cursorPoint = viewport.imagePoint(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
        layoutText(); changed()
    }
    func zoom(to scale: Double, around anchor: CGPoint) {
        guard isEnabled, window?.attachedSheet == nil, gesture == nil else { return }
        manualViewport = viewport.zoomed(to: scale, around: anchor)
        viewChanged(anchor: anchor)
    }
    func pan(by delta: CGPoint) {
        guard isEnabled, window?.attachedSheet == nil, gesture == nil else { return }
        guard delta != .zero else { return }
        manualViewport = viewport.translated(by: delta)
        viewChanged()
    }
    func fitAll() {
        guard isEnabled, window?.attachedSheet == nil, gesture == nil else { return }
        manualViewport = nil; viewChanged()
    }
    func handleZoomKey(_ event: NSEvent) -> Bool {
        guard isEnabled, window?.attachedSheet == nil else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags == .command || flags == [.command, .shift] else { return false }
        let anchor = CGPoint(x: bounds.midX, y: bounds.midY)
        switch event.charactersIgnoringModifiers {
        case "+", "=": zoom(to: displayScale * 1.25, around: anchor)
        case "-": zoom(to: displayScale / 1.25, around: anchor)
        case "0": fitAll()
        case "1": zoom(to: 1, around: anchor)
        default: return false
        }
        return true
    }
    override func magnify(with event: NSEvent) {
        guard event.magnification != 0 else { return }
        zoom(to: max(0.01, displayScale + event.magnification), around: convert(event.locationInWindow, from: nil))
    }
    override func scrollWheel(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        if event.phase.contains(.began) { scrollZooming = command }
        if !event.momentumPhase.isEmpty, scrollZooming { return }
        if command {
            scrollZooming = true
            let amount = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10)
            guard amount != 0 else { return }
            zoom(to: displayScale * pow(1.01, amount), around: convert(event.locationInWindow, from: nil))
        } else {
            let factor = event.hasPreciseScrollingDeltas ? 1.0 : 20.0
            pan(by: CGPoint(x: event.scrollingDeltaX * factor, y: event.scrollingDeltaY * factor))
        }
    }
    func releaseSpace() {
        spacePressed = false
        if case .pan = gesture { cancelGesture() }
        updateCursor()
    }
    private func cancelGesture() { gesture = nil; preview = nil; frozenImageRect = nil; marqueeRect = nil; marqueeSelection = nil; toggleOnClick = nil }
    func finishGesture() {
        if let preview { history.commit(preview) }
        cancelGesture(); changed()
    }
    func undoAnnotation() { cancelGesture(); history.undo(); selection = []; changed() }
    func redoAnnotation() { cancelGesture(); history.redo(); selection = []; changed() }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        cursorPoint = bounds.contains(p) ? point(event) : nil
        updateCursor(); needsDisplay = true
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func cursorUpdate(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { cursorPoint = nil; if window?.isKeyWindow == true { NSCursor.arrow.set() }; needsDisplay = true }
    private func updateCursor() {
        guard window?.isKeyWindow == true, window?.attachedSheet == nil, !isEditingText else { return }
        if case .pan = gesture { NSCursor.closedHand.set(); return }
        if spacePressed { NSCursor.openHand.set(); return }
        guard let cursorPoint else { return }
        let interaction: AnnotationInteraction
        switch gesture {
        case .create, .label: interaction = .create
        case .move(_, _, let id): interaction = .move(id)
        case .resize(let annotation, let handle): interaction = .resize(annotation.id, handle)
        case .pan, .marquee: return
        case nil: interaction = document.interaction(at: cursorPoint, selected: selection, tool: tool, style: style, tolerance: 7 / displayScale)
        }
        let cursor: NSCursor
        switch interaction.cursor(tool: tool) {
        case .arrow: cursor = .arrow
        case .crosshair: cursor = .crosshair
        case .move:
            if case .move = gesture { cursor = .closedHand } else { cursor = .openHand }
        case .horizontal: cursor = .frameResize(position: .left, directions: .all)
        case .vertical: cursor = .frameResize(position: .top, directions: .all)
        case .diagonalDown: cursor = .frameResize(position: .topLeft, directions: .all)
        case .diagonalUp: cursor = .frameResize(position: .topRight, directions: .all)
        }
        cursor.set()
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onUserOperation?()
        commitText(); window?.makeFirstResponder(self)
        selectionBeforeGesture = selection
        viewportBeforeGesture = manualViewport
        if spacePressed {
            gesture = .pan(viewport, convert(event.locationInWindow, from: nil)); updateCursor(); return
        }
        let p = point(event)
        cursorPoint = p
        toggleOnClick = nil
        if event.modifierFlags.contains(.shift),
           let id = document.hit(at: p, style: style, tolerance: 7 / displayScale, includeAreaInterior: true) {
            toggleOnClick = (id, selection)
        }
        let interaction = document.interaction(at: p, selected: selection, tool: toggleOnClick == nil ? tool : .selection, style: style, tolerance: 7 / displayScale)
        switch interaction {
        case .resize(let id, let handle):
            guard let annotation = document.annotations.first(where: { $0.id == id }) else { return }
            selection = [id]; frozenImageRect = imageRect; gesture = .resize(annotation, handle); changed(); return
        case .move(let id):
            guard let annotation = document.annotations.first(where: { $0.id == id }) else { return }
            if !selection.contains(id) {
                if toggleOnClick != nil { selection.insert(id) } else { selection = [id] }
            }
            if selection.count == 1, event.clickCount == 2, annotation.tool == .text { beginText(annotation); return }
            frozenImageRect = imageRect; gesture = .move(selection, p, id); changed(); return
        case .none:
            let previous = event.modifierFlags.contains(.shift) ? selection : []
            selection = previous; frozenImageRect = imageRect; gesture = .marquee(p, previous)
            changed(); return
        case .create:
            if tool == .text, event.clickCount == 2, selection.count <= 1,
               let id = document.hit(at: p, style: style, tolerance: 7 / displayScale),
               let annotation = document.annotations.first(where: { $0.id == id && $0.tool == .text }),
               annotation.rect.insetBy(dx: -style.edge, dy: -style.edge).contains(p) {
                beginText(annotation); return
            }
        }
        selection = []
        guard tool.allowsMargin || CGRect(origin: .zero, size: imageSize).contains(p) else { changed(); return }
        let annotation = Annotation(tool: tool, start: p, highlighterColor: Self.lastHighlighterColor,
                                    darkBackground: Self.lastHighlighterDarkBackground, inkColor: Self.lastInkColor)
        highlighterStraight = event.modifierFlags.contains(.shift)
        frozenImageRect = imageRect
        gesture = [.text, .number].contains(tool) ? .label(annotation) : .create(annotation)
        changed()
    }
    private func placed(_ annotation: Annotation) -> Annotation {
        AnnotationGeometry.placed(annotation, bounds: history.document.bounds(of: annotation, style: style), imageSize: imageSize)
    }
    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let gesture else { return }
        if case .pan(let initial, let anchor) = gesture {
            let p = convert(event.locationInWindow, from: nil)
            manualViewport = initial.translated(by: CGPoint(x: p.x - anchor.x, y: p.y - anchor.y))
            viewChanged(anchor: p); return
        }
        let p = point(event)
        cursorPoint = p
        let shift = event.modifierFlags.contains(.shift)
        var annotation: Annotation
        switch gesture {
        case .marquee(let anchor, let previous):
            let rect = Annotation(tool: .rectangle, start: anchor, end: p).rect
            marqueeRect = rect
            marqueeSelection = previous.union(history.document.intersecting(rect, style: style))
            needsDisplay = true; return
        case .label(let initial):
            let anchor = initial.start
            guard AnnotationGeometry.isValidDrag(tool: initial.tool, from: anchor, to: p, displayScale: displayScale) else { preview = nil; changed(); return }
            if initial.tool == .number {
                annotation = Annotation(id: initial.id, tool: .number, start: p, leaderTarget: anchor, inkColor: initial.inkColor)
                break
            }
            let size = AnnotationRenderer.textSize("入力", style: style)
            let rect = CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height)
            annotation = Annotation(id: initial.id, tool: .text, start: rect.origin,
                                    end: CGPoint(x: rect.maxX, y: rect.maxY), text: "入力", leaderTarget: anchor, inkColor: initial.inkColor)
        case .create(let initial):
            annotation = initial.tool == .highlighter ? (preview?.annotations.first { $0.id == initial.id } ?? initial) : initial
            annotation.end = AnnotationGeometry.creationPoint(p, from: initial.start, tool: initial.tool, shift: shift, imageSize: imageSize)
            if initial.tool == .highlighter {
                if highlighterStraight { annotation.points = [initial.start, annotation.end] }
                else { annotation.points.append(annotation.end) }
            }
        case .move(let ids, let anchor, _):
            var delta = CGPoint(x: p.x - anchor.x, y: p.y - anchor.y)
            if shift { delta = AnnotationGeometry.axisConstrained(delta) }
            preview = history.document.moving(ids, by: delta, imageSize: imageSize)
            changed(); return
        case .resize(let initial, let handle):
            annotation = AnnotationGeometry.resized(initial, handle: handle, to: p, shift: shift, imageSize: imageSize)
        case .pan: return
        }
        annotation = placed(annotation)
        var next = history.document; next.replace(annotation); preview = next
        selection = [annotation.id]; changed()
    }
    override func mouseUp(with event: NSEvent) {
        guard let gesture else { return }
        if case .pan = gesture { cancelGesture(); viewChanged(); return }
        if let toggleOnClick, preview == nil {
            selection = toggleOnClick.previous
            if !selection.insert(toggleOnClick.id).inserted { selection.remove(toggleOnClick.id) }
            cancelGesture(); changed(); return
        }
        if case .marquee(let anchor, let previous) = gesture {
            let rect = Annotation(tool: .rectangle, start: anchor, end: point(event)).rect
            selection = previous.union(history.document.intersecting(rect, style: style))
            cancelGesture(); changed(); return
        }
        if case .move(_, let anchor, let id) = gesture, preview == nil,
           hypot(point(event).x - anchor.x, point(event).y - anchor.y) * displayScale <= 4 {
            selection = [id]
        }
        if case .label(let initial) = gesture {
            let anchor = initial.start
            let p = point(event)
            let leader = AnnotationGeometry.isValidDrag(tool: initial.tool, from: anchor, to: p, displayScale: displayScale)
            if initial.tool == .number {
                let annotation = placed(Annotation(id: initial.id, tool: .number, start: leader ? p : anchor, leaderTarget: leader ? anchor : nil, inkColor: initial.inkColor))
                var next = history.document; next.replace(annotation); history.commit(next); selection = [annotation.id]
                cancelGesture(); changed(); return
            }
            let size = AnnotationRenderer.textSize("入力", style: style)
            let origin = leader ? CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2) : anchor
            let annotation = placed(Annotation(id: initial.id, tool: .text, start: origin, end: CGPoint(x: origin.x + size.width, y: origin.y + size.height), leaderTarget: leader ? anchor : nil, inkColor: initial.inkColor))
            cancelGesture()
            beginText(annotation)
            return
        }
        defer { cancelGesture(); changed(); layoutText() }
        guard let next = preview else { return }
        let annotation: Annotation?
        switch gesture {
        case .create(let initial), .resize(let initial, _): annotation = next.annotations.first { $0.id == initial.id }
        case .move, .label, .pan, .marquee: annotation = nil
        }
        if let annotation, ![.text, .number].contains(annotation.tool),
           !(annotation.tool == .highlighter
             ? annotation.points.contains { hypot($0.x - annotation.start.x, $0.y - annotation.start.y) * displayScale > 4 }
             : AnnotationGeometry.isValidDrag(tool: annotation.tool, from: annotation.start, to: annotation.end, displayScale: displayScale)) {
            if case .create = gesture { selection = [] }
            return
        }
        history.commit(next)
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled, !isEditingText, window?.attachedSheet == nil else { return }
        onUserOperation?()
        if handleZoomKey(event) { return }
        if handleClipboardKey(event) { return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if showsInkControls, let color = InkColor(keyCode: event.keyCode, modified: !flags.isEmpty, editingText: isEditingText) {
            if !event.isARepeat { applyInkColor(color) }
            return
        }
        if showsHighlighterControls, let action = HighlighterAction(keyCode: event.keyCode, modified: !flags.isEmpty, editingText: isEditingText) {
            if !event.isARepeat { applyHighlighterAction(action) }
            return
        }
        if flags.isEmpty, event.keyCode == 49 { spacePressed = true; updateCursor(); return }
        if flags.isEmpty, event.keyCode == 4 {
            if !event.isARepeat { onPrivacy?() }
            return
        }
        if flags.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
            if !event.isARepeat { onFinish?() }
            return
        }
        if flags.isEmpty, event.keyCode == 53 { if !event.isARepeat { escape() }; return }
        if flags.isEmpty, let next = AnnotationTool.allCases.first(where: { $0.keyCode == event.keyCode }) {
            tool = next; rememberTool(); changed(); return
        }
        interpretKeyEvents([event])
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { releaseSpace(); return }
        super.keyUp(with: event)
    }
    private func rememberTool() {
        // ボタンとキーの持ち替えを同じ経路へ通す。
        onToolChange?(tool)
    }
    var onToolChange: ((AnnotationTool) -> Void)?
    override func cancelOperation(_ sender: Any?) { escape() }
    func escape() {
        guard isEnabled else { return }
        if onCancelPrivacy?() == true { return }
        if isEditingText { commitText(); return }
        if let gesture {
            if case .pan = gesture { manualViewport = viewportBeforeGesture }
            selection = selectionBeforeGesture
            cancelGesture(); changed(); layoutText(); return
        }
        if !selection.isEmpty { selection = []; changed() }
        else { onFinish?() }
    }
    override func deleteBackward(_ sender: Any?) { deleteSelected() }
    override func deleteForward(_ sender: Any?) { deleteSelected() }
    private func deleteSelected() {
        guard !selection.isEmpty else { return }
        cancelGesture()
        var next = history.document; next.remove(selection); history.commit(next); self.selection = []; changed()
    }
    func handleClipboardKey(_ event: NSEvent) -> Bool {
        guard isEnabled, !isEditingText, gesture == nil, window?.attachedSheet == nil,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command else { return false }
        var next = history.document
        let pasted: Set<UUID>
        switch event.keyCode {
        case 8: clipboard.copy(selection, from: next); return true // C
        case 9: pasted = clipboard.paste(into: &next, imageSize: imageSize) // V
        case 2: pasted = next.duplicate(selection, imageSize: imageSize) // D
        default: return false
        }
        guard !pasted.isEmpty else { return true }
        history.commit(next); selection = pasted; changed()
        return true
    }
    func reeditTextOnDoubleClick(with event: NSEvent) -> Bool {
        // 最初のクリックで開いた空の入力欄が、2回目のクリックを受ける場合も再編集へ渡す。
        guard isEnabled, tool == .text, event.clickCount == 2,
              let pending = textAnnotation, let input = textInput, input.string.isEmpty, !input.hasMarkedText(),
              !history.document.annotations.contains(where: { $0.id == pending.id }) else { return false }
        let p = point(event)
        guard let id = history.document.hit(at: p, style: style, tolerance: 7 / displayScale),
              let annotation = history.document.annotations.first(where: { $0.id == id && $0.tool == .text }),
              annotation.rect.insetBy(dx: -style.edge, dy: -style.edge).contains(p) else { return false }
        commitText(); beginText(annotation)
        return true
    }
    private func beginText(_ annotation: Annotation) {
        spacePressed = false
        textAnnotation = annotation; selection = [annotation.id]
        textAnchor = annotation.leaderTarget == nil ? annotation.start : CGPoint(x: annotation.rect.midX, y: annotation.rect.midY)
        let input = AnnotationTextView(frame: .zero)
        input.isRichText = false; input.allowsUndo = true; input.drawsBackground = true
        input.backgroundColor = UITheme.inkFace(annotation.inkColor); input.textColor = UITheme.inkText(annotation.inkColor)
        input.wantsLayer = true; input.layer?.masksToBounds = true
        input.navigationCanvas = self
        input.textContainerInset = CGSize(width: style.horizontalPadding * displayScale, height: style.verticalPadding * displayScale)
        input.textContainer?.lineFragmentPadding = 0
        input.isHorizontallyResizable = false; input.isVerticallyResizable = false
        input.autoresizingMask = []
        input.string = annotation.text
        input.delegate = self
        input.onCommit = { [weak self] in self?.commitText() }
        input.onEscape = { [weak self] in self?.escape() }
        textInput = input; addSubview(input); layoutText()
        window?.makeFirstResponder(input); input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0))
        changed()
    }
    private func layoutText() {
        guard let input = textInput, var annotation = textAnnotation, let anchor = textAnchor else { return }
        let measured = AnnotationRenderer.textSize(input.string.isEmpty ? "入力" : input.string, style: style)
        let size = CGSize(width: max(input.string.isEmpty ? 100 : 0, measured.width), height: measured.height)
        annotation.start = annotation.leaderTarget == nil ? anchor : CGPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2)
        annotation.end = CGPoint(x: annotation.start.x + size.width, y: annotation.start.y + size.height)
        annotation = placed(annotation)
        textAnnotation = annotation
        let font = NSFont.systemFont(ofSize: style.fontSize * displayScale, weight: .bold)
        if input.font != font { input.font = font }
        input.textContainerInset = CGSize(width: style.horizontalPadding * displayScale, height: style.verticalPadding * displayScale)
        input.layer?.cornerRadius = style.radius * displayScale
        input.frame = viewRect(annotation.rect)
        input.textContainer?.containerSize = CGSize(width: input.bounds.width - input.textContainerInset.width * 2, height: CGFloat.greatestFiniteMagnitude)
    }
    func textDidChange(_ notification: Notification) { layoutText(); changed() }
    func commitText() {
        guard let input = textInput, textAnnotation != nil else { return }
        input.unmarkText()
        layoutText()
        guard var annotation = textAnnotation else { return }
        annotation.text = input.string
        var next = history.document
        if annotation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { next.remove(annotation.id); selection = [] }
        else {
            next.replace(annotation)
        }
        input.removeFromSuperview(); textInput = nil; textAnnotation = nil; textAnchor = nil
        history.commit(next); window?.makeFirstResponder(self); changed()
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        var drawnDocument = document
        if var textAnnotation { textAnnotation.text = ""; drawnDocument.replace(textAnnotation) }
        if renderedDocument != drawnDocument {
            composed = try? AnnotationRenderer.compose(original, document: drawnDocument)
            renderedDocument = drawnDocument
        }
        let raster = composed ?? original
        let image = NSImage(cgImage: raster, size: CGSize(width: raster.width, height: raster.height))
        let outputRect = viewRect(composed == nil ? CGRect(origin: .zero, size: imageSize) : exportLayout.bounds)
        image.draw(in: outputRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        var selectionBounds: CGRect?
        let displayedSelection = self.displayedSelection
        for selected in document.annotations where displayedSelection.contains(selected.id) && !isEditingText {
            let bounds = document.bounds(of: selected, style: style)
            var inkBounds = selected.tool == .spotlight
                ? bounds.insetBy(dx: -style.lineWidth - style.edge * 2, dy: -style.lineWidth - style.edge * 2)
                : AnnotationGeometry.inkBounds(of: selected, bounds: bounds, style: style)
            if selected.tool == .highlighter {
                inkBounds = bounds.insetBy(dx: -style.highlighterWidth * 0.8, dy: -style.highlighterWidth * 0.8)
                    .intersection(CGRect(origin: .zero, size: imageSize))
            }
            let rect = viewRect(inkBounds).insetBy(dx: -4, dy: -4)
            selectionBounds = selectionBounds.map { $0.union(rect) } ?? rect
            let border = NSBezierPath(rect: rect)
            NSColor.white.setStroke(); border.lineWidth = 3; border.stroke()
            UITheme.indigo.setStroke(); border.lineWidth = 2; border.stroke()
            for handle in displayedSelection.count == 1 && marqueeRect == nil ? AnnotationGeometry.handles(for: selected) : [] {
                let p = viewPoint(handle), r = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
                let circle = NSBezierPath(ovalIn: r)
                NSColor.white.setFill(); circle.fill()
                UITheme.indigo.setStroke(); circle.lineWidth = 2; circle.stroke()
            }
        }
        if displayedSelection.count > 1, let selectionBounds {
            let border = NSBezierPath(rect: selectionBounds)
            UITheme.indigo.setStroke(); border.lineWidth = 1
            border.setLineDash([4, 3], count: 2, phase: 0); border.stroke()
        }
        if let marqueeRect {
            let path = NSBezierPath(rect: viewRect(marqueeRect))
            UITheme.indigo.withAlphaComponent(0.12).setFill(); path.fill()
            UITheme.indigo.setStroke(); path.lineWidth = 1; path.stroke()
        }
        if tool == .number, let cursorPoint, !isEditingText, gesture == nil {
            let string = String(document.nextNumber) as NSString
            let r = viewRect(style.numberRect(at: cursorPoint, number: document.nextNumber))
            UITheme.inkFace(Self.lastInkColor).withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: style.fontSize * displayScale, weight: .bold), .foregroundColor: UITheme.inkText(Self.lastInkColor).withAlphaComponent(0.6)]
            let size = string.size(withAttributes: attributes)
            string.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attributes)
        }
    }
    private var isPanning: Bool { if case .pan = gesture { return true }; return false }
}

/// IMEのEnterはinput contextに任せ、未変換文字がないEnterだけ注釈として確定する。
@MainActor
final class AnnotationTextView: NSTextView {
    weak var navigationCanvas: AnnotationCanvas?
    var onCommit: (() -> Void)?
    var onEscape: (() -> Void)?
    private var markedAtKeyDown = false
    // 確定済みの文字編集を、次に開いた文字の⌘Zへ持ち越さない。
    private let textUndoManager = UndoManager()
    override var undoManager: UndoManager? { textUndoManager }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if navigationCanvas?.reeditTextOnDoubleClick(with: event) == true { return }
        super.mouseDown(with: event)
    }
    override func magnify(with event: NSEvent) { navigationCanvas?.magnify(with: event) }
    override func scrollWheel(with event: NSEvent) { navigationCanvas?.scrollWheel(with: event) }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { navigationCanvas?.releaseSpace() }
        super.keyUp(with: event)
    }
    override func keyDown(with event: NSEvent) {
        markedAtKeyDown = hasMarkedText()
        super.keyDown(with: event)
        markedAtKeyDown = false
    }
    override func insertNewline(_ sender: Any?) {
        if hasMarkedText() || markedAtKeyDown || NSApp.currentEvent?.modifierFlags.contains(.shift) == true { super.insertNewline(sender) }
        else { onCommit?() }
    }
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { super.insertNewline(sender) }
    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() || markedAtKeyDown { super.cancelOperation(sender) }
        else { onEscape?() }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .command {
            switch event.keyCode {
            case 8: copy(nil); return true // C
            case 7: cut(nil); return true // X
            case 9: paste(nil); return true // V
            case 0: selectAll(nil); return true // A
            case 6: undoManager?.undo(); return true // Z
            default: break
            }
        }
        if flags == [.command, .shift], event.keyCode == 6 { undoManager?.redo(); return true }
        return super.performKeyEquivalent(with: event)
    }
}
